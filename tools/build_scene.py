#!/usr/bin/env python3
"""Szenen-Assets bauen: Orthofoto, Höhenraster und meta.json.

Beispiele:
  # Orthofoto aus einem XYZ-/WMS-Kachelserver (Beispiel-Template!)
  python3 tools/build_scene.py --tiles "https://example.org/ortho/{z}/{x}/{y}.jpg" --z 16

  # Vorhandenes, bereits auf die Bbox zugeschnittenes Luftbild verwenden
  python3 tools/build_scene.py --ortho-file /pfad/luftbild.jpg

  # Höhenmodell: SRTM-Kacheln (RGB-kodiert, z13) oder GeoTIFF
  python3 tools/build_scene.py --srtm-dir /pfad/srtm13
  python3 tools/build_scene.py --dem-geotiff /pfad/dgm.tif

Ohne Höhenmodell wird ein flaches Gelände erzeugt (mit Warnung).
Die Bbox kommt aus web/data/bbox.json (von fetch_osm.py) oder --bbox w,s,e,n.
"""
import argparse
import io
import json
import math
import os
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENE = os.path.join(ROOT, "web", "data", "scene")
DATA = os.path.join(ROOT, "web", "data")
UA = "iso-village-map/1.0"


def lon_to_x(lon, z):
    return (lon + 180.0) / 360.0 * (2 ** z)


def lat_to_y(lat, z):
    s = math.sin(math.radians(lat))
    return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * (2 ** z)


def tile_bounds(bbox, z):
    w, s, e, n = bbox
    return (int(math.floor(lon_to_x(w, z))), int(math.floor(lon_to_x(e, z))),
            int(math.floor(lat_to_y(n, z))), int(math.floor(lat_to_y(s, z))))


def build_ortho(bbox, template, z, img_max):
    w, s, e, n = bbox
    x0, x1, y0, y1 = tile_bounds(bbox, z)
    nx, ny = x1 - x0 + 1, y1 - y0 + 1
    print("ortho tiles z%d: %d x %d = %d" % (z, nx, ny, nx * ny))

    def fetch(t):
        tx, ty = t
        url = template.replace("{z}", str(z)).replace("{x}", str(tx)).replace("{y}", str(ty))
        for _ in range(3):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=60) as r:
                    return Image.open(io.BytesIO(r.read())).convert("RGB")
            except Exception:
                pass
        return None

    tiles = [(x0 + i, y0 + j) for j in range(ny) for i in range(nx)]
    with ThreadPoolExecutor(max_workers=10) as ex:
        imgs = list(ex.map(fetch, tiles))
    miss = sum(1 for i in imgs if i is None)
    if miss:
        print("WARNUNG: %d Kacheln fehlen" % miss, file=sys.stderr)

    mosaic = Image.new("RGB", (nx * 256, ny * 256), (200, 205, 200))
    for t, im in zip(tiles, imgs):
        if im is not None:
            mosaic.paste(im, ((t[0] - x0) * 256, (t[1] - y0) * 256))

    mx0 = (lon_to_x(w, z) - x0) * 256
    mx1 = (lon_to_x(e, z) - x0) * 256
    my0 = (lat_to_y(n, z) - y0) * 256
    my1 = (lat_to_y(s, z) - y0) * 256
    crop = mosaic.crop((int(mx0), int(my0), int(mx1), int(my1)))
    scale = img_max / crop.width
    img = crop.resize((img_max, int(round(crop.height * scale))), Image.LANCZOS)
    img.save(os.path.join(SCENE, "ortho.jpg"), quality=86, optimize=True, progressive=True)
    print("ortho.jpg", img.size)
    return list(img.size)


def elev_from_srtm(bbox, srtm_dir):
    """SRTM-Mosaik aus RGB-kodierten 256px-Kacheln (z13)."""
    import numpy as np

    x0, x1, y0, y1 = tile_bounds(bbox, 13)
    mos = np.zeros(((y1 - y0 + 1) * 256, (x1 - x0 + 1) * 256), dtype=np.float32)
    got = 0
    for ty in range(y0, y1 + 1):
        for tx in range(x0, x1 + 1):
            p = os.path.join(srtm_dir, str(tx), "%d.png" % ty)
            if not os.path.exists(p):
                continue
            arr = np.asarray(Image.open(p).convert("RGB"), dtype=np.float32)
            h = arr[:, :, 0] * 256.0 + arr[:, :, 1] + arr[:, :, 2] / 256.0 - 32768.0
            mos[(ty - y0) * 256:(ty - y0 + 1) * 256,
                (tx - x0) * 256:(tx - x0 + 1) * 256] = h
            got += 1
    if not got:
        print("WARNUNG: keine SRTM-Kacheln gefunden", file=sys.stderr)
        return None

    def elev(lon, lat):
        px = (lon_to_x(lon, 13) - x0) * 256
        py = (lat_to_y(lat, 13) - y0) * 256
        ix, iy = int(px), int(py)
        fx, fy = px - ix, py - iy
        hgt, wid = mos.shape
        ix = min(max(ix, 0), wid - 2)
        iy = min(max(iy, 0), hgt - 2)
        a = mos[iy, ix] * (1 - fx) + mos[iy, ix + 1] * fx
        b = mos[iy + 1, ix] * (1 - fx) + mos[iy + 1, ix + 1] * fx
        return float(a * (1 - fy) + b * fy)

    return elev


def elev_from_geotiff(bbox, path):
    import numpy as np
    import rasterio
    from rasterio.windows import from_bounds

    w, s, e, n = bbox
    with rasterio.open(path) as ds:
        win = from_bounds(w, s, e, n, ds.transform)
        arr = ds.read(1, window=win)
        tr = ds.window_transform(win)

        def elev(lon, lat):
            col, row = ~tr * (lon, lat)
            ix, iy = int(row), int(col)
            fy, fx = row - iy, col - ix
            hgt, wid = arr.shape
            ix = min(max(ix, 0), wid - 2)
            iy = min(max(iy, 0), hgt - 2)
            a = float(arr[iy, ix]) * (1 - fx) + float(arr[iy, ix + 1]) * fx
            b = float(arr[iy + 1, ix]) * (1 - fx) + float(arr[iy + 1, ix + 1]) * fx
            v = a * (1 - fy) + b * fy
            return 0.0 if np.isnan(v) else v

    return elev


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bbox", help="w,s,e,n (Lon/Lat)")
    ap.add_argument("--tiles", help="XYZ-Template, z.B. https://host/path/{z}/{x}/{y}.jpg")
    ap.add_argument("--z", type=int, default=16)
    ap.add_argument("--ortho-file", help="bereits zugeschnittenes Luftbild")
    ap.add_argument("--srtm-dir")
    ap.add_argument("--dem-geotiff")
    ap.add_argument("--img-max", type=int, default=4096)
    ap.add_argument("--grid", type=int, default=192)
    ap.add_argument("--title", default="")
    ap.add_argument("--subtitle", default="")
    ap.add_argument("--eyebrow", default="Isometrische Karte")
    ap.add_argument("--attribution", default="© OpenStreetMap-Mitwirkende")
    ap.add_argument("--focus-radius", type=float)
    args = ap.parse_args()

    if args.bbox:
        bbox = tuple(float(x) for x in args.bbox.split(","))
    else:
        bp = os.path.join(DATA, "bbox.json")
        if not os.path.exists(bp):
            raise SystemExit("Keine bbox: --bbox angeben oder zuerst fetch_osm.py laufen lassen")
        b = json.load(open(bp))
        bbox = (b["w"], b["s"], b["e"], b["n"])

    w, s, e, n = bbox
    os.makedirs(SCENE, exist_ok=True)

    img_size = None
    if args.tiles:
        img_size = build_ortho(bbox, args.tiles, args.z, args.img_max)
    elif args.ortho_file:
        im = Image.open(args.ortho_file).convert("RGB")
        src_ratio = (e - w) * math.cos(math.radians((s + n) / 2)) / (n - s)
        width = min(args.img_max, im.width)
        im = im.resize((width, int(round(width / src_ratio))), Image.LANCZOS)
        im.save(os.path.join(SCENE, "ortho.jpg"), quality=86, optimize=True)
        img_size = list(im.size)
        print("ortho.jpg", im.size)
    else:
        print("Hinweis: kein --tiles/--ortho-file; ortho.jpg wird nicht erzeugt.", file=sys.stderr)

    if args.dem_geotiff:
        elev = elev_from_geotiff(bbox, args.dem_geotiff)
    elif args.srtm_dir:
        elev = elev_from_srtm(bbox, args.srtm_dir)
    else:
        elev = None
        print("Hinweis: kein Höhenmodell; Gelände wird flach.", file=sys.stderr)

    G = args.grid
    rows = []
    for j in range(G + 1):
        lat = s + (n - s) * j / G
        rows.append([round(elev(w + (e - w) * i / G, lat), 1) if elev else 0 for i in range(G + 1)])
    json.dump({"w": w, "s": s, "e": e, "n": n, "size": G, "h": rows},
              open(os.path.join(SCENE, "height.json"), "w"), separators=(",", ":"))

    if img_size is None and os.path.exists(os.path.join(SCENE, "ortho.jpg")):
        img_size = list(Image.open(os.path.join(SCENE, "ortho.jpg")).size)
    if img_size is None:
        img_size = [1600, int(round(1600 * (n - s) * math.cos(math.radians((s + n) / 2)) / (e - w)))]

    meta = {
        "w": w, "s": s, "e": e, "n": n, "img": img_size,
        "title": args.title or "Isometrische Karte",
        "subtitle": args.subtitle,
        "eyebrow": args.eyebrow,
        "attribution": args.attribution,
        "focus": {"lat": round((s + n) / 2, 7), "lon": round((w + e) / 2, 7),
                  "radius": args.focus_radius or round(min((n - s) * 110574,
                                                           (e - w) * 111320 * math.cos(math.radians((s + n) / 2))) / 2)},
    }
    json.dump(meta, open(os.path.join(SCENE, "meta.json"), "w"), ensure_ascii=False, indent=2)
    lod2 = os.path.join(DATA, "lod2.js")
    if not os.path.exists(lod2):
        with open(lod2, "w") as f:
            f.write("window.LOD2={src:'',off:0,n:0,b:[]};")
    print("height.json %dx%d  meta.json" % (G + 1, G + 1))
    print("Nächster Schritt: tools/stylize_ground.py (optional) und tools/build_lod2.py (optional)")


if __name__ == "__main__":
    main()
