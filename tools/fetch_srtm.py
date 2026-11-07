#!/usr/bin/env python3
"""Höhenkacheln (Terrarium-Format, RGB-kodiert) für eine Bbox herunterladen.

Beispiele:
  # Bbox aus web/data/bbox.json (von fetch_osm.py) nehmen
  python3 tools/fetch_srtm.py

  # eigene Bbox und Verzeichnis
  python3 tools/fetch_srtm.py --bbox 11.49,48.09,11.54,48.13 --out /pfad/srtm13

Das Layout passt zu build_scene.py --srtm-dir: <out>/<x>/<y>.png (z13, 256 px).
Standard-Quelle ist der öffentliche AWS-Terrarium-Datensatz
(elevation = R*256 + G + B/256 - 32768, genau das Format, das
build_scene.py elev_from_srtm() erwartet).
"""
import argparse
import json
import math
import os
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BBOX_FILE = os.path.join(ROOT, "web", "data", "bbox.json")
UA = "iso-village-map/1.0 (https://github.com/; contact: local)"
DEFAULT_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"

R = 6378137


def lon_to_x(lon, z):
    return (lon + 180.0) / 360.0 * (2 ** z)


def lat_to_y(lat, z):
    s = math.sin(math.radians(lat))
    return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * (2 ** z)


def tile_bounds(bbox, z):
    w, s, e, n = bbox
    return (int(math.floor(lon_to_x(w, z))), int(math.floor(lon_to_x(e, z))),
            int(math.floor(lat_to_y(n, z))), int(math.floor(lat_to_y(s, z))))


def read_bbox(args):
    if args.bbox:
        return [float(v) for v in args.bbox.split(",")]
    if os.path.exists(BBOX_FILE):
        with open(BBOX_FILE) as f:
            b = json.load(f)
        return [b["w"], b["s"], b["e"], b["n"]]
    sys.exit("Keine Bbox: web/data/bbox.json fehlt (erst fetch_osm.py ausführen) "
             "oder --bbox w,s,e,n angeben.")


def fetch_tile(url, path, tries=4):
    """Eine Kachel laden; True bei Erfolg, False wenn nicht verfügbar."""
    for _ in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            if len(data) > 100:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as f:
                    f.write(data)
                return True
        except Exception:
            pass
    return False


def main():
    ap = argparse.ArgumentParser(description="Terrarium-Höhenkacheln laden (z13)")
    ap.add_argument("--bbox", help="w,s,e,n (Lon/Lat); Default: web/data/bbox.json")
    ap.add_argument("--z", type=int, default=13, help="Zoomstufe (Default: 13)")
    ap.add_argument("--out", default="srtm13", help="Zielverzeichnis (Default: srtm13)")
    ap.add_argument("--url", default=DEFAULT_URL,
                    help="XYZ-Template der Höhenkacheln ({z}/{x}/{y})")
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    bbox = read_bbox(args)
    x0, x1, y0, y1 = tile_bounds(bbox, args.z)
    jobs = []
    for ty in range(y0, y1 + 1):
        for tx in range(x0, x1 + 1):
            p = os.path.join(args.out, str(tx), "%d.png" % ty)
            if os.path.exists(p) and os.path.getsize(p) > 100:
                continue  # schon da (idempotent)
            url = (args.url.replace("{z}", str(args.z))
                          .replace("{x}", str(tx)).replace("{y}", str(ty)))
            jobs.append((url, p))

    print("Höhenkacheln z%d: %d x %d = %d (%d zu laden)"
          % (args.z, x1 - x0 + 1, y1 - y0 + 1, (x1 - x0 + 1) * (y1 - y0 + 1), len(jobs)))
    ok = 0
    if jobs:
        with ThreadPoolExecutor(max_workers=args.workers) as ex:
            ok = sum(1 for got in ex.map(lambda j: fetch_tile(*j), jobs) if got)
        print("geladen: %d/%d" % (ok, len(jobs)))
        if ok == 0:
            sys.exit("FEHLER: keine einzige Höhenkachel geladen – URL/Netz prüfen.")
        if ok < len(jobs):
            print("WARNUNG: %d Kacheln fehlen – Lücken werden im Höhenraster stehen bleiben"
                  % (len(jobs) - ok), file=sys.stderr)
    else:
        print("alles schon vorhanden")
    print("fertig:", os.path.abspath(args.out))


if __name__ == "__main__":
    main()
