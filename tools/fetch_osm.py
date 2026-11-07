#!/usr/bin/env python3
"""OSM-Daten (Gebäude, Straßen, Ortsnamen) für ein Untersuchungsgebiet laden.

Beispiele:
  python3 tools/fetch_osm.py --name "Musterhausen" --radius 1500
  python3 tools/fetch_osm.py --name "Musterhausen" --lat 48.11 --lon 11.515 --radius 2000
  python3 tools/fetch_osm.py --bbox 11.49,48.09,11.54,48.13 --title "Musterhausen"

Ergebnis:
  web/data/buildings.js   window.BUILDINGS (GeoJSON FeatureCollection)
  web/data/roads.js       window.ROADS     [{t,p:[[lat,lon],...]}]
  web/data/places.js      window.PLACES    [{name,kind,lat,lon}]
  web/data/bbox.json      {w,s,e,n,center_lat,center_lon,radius}

Overpass: GET mit User-Agent (POST wird von einigen Endpunkten blockiert).
"""
import argparse
import json
import math
import os
import sys
import time
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "web", "data")
UA = "iso-village-map/1.0 (https://github.com/; contact: local)"
ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
DRIVABLE = {
    "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
    "residential", "living_street", "service", "track", "pedestrian",
    "motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link",
    "road", "path", "footway", "cycleway", "bridleway", "steps",
}


def clip_seg(p0, p1, bbox):
    """Liang-Barsky: Segment (lon,lat) auf die Bbox zuschneiden."""
    w, s, e, n = bbox
    x0, y0 = p0
    x1, y1 = p1
    dx, dy = x1 - x0, y1 - y0
    t0, t1 = 0.0, 1.0
    for p, q in ((-dx, x0 - w), (dx, e - x0), (-dy, y0 - s), (dy, n - y0)):
        if p == 0:
            if q < 0:
                return None
        else:
            r = q / p
            if p < 0:
                if r > t1:
                    return None
                if r > t0:
                    t0 = r
            else:
                if r < t0:
                    return None
                if r < t1:
                    t1 = r
    return (x0 + dx * t0, y0 + dy * t0), (x0 + dx * t1, y0 + dy * t1)


def clip_line(pts, bbox):
    """Polyline (lat,lon) auf die Bbox zuschneiden, ergibt 1..n Teilstücke."""
    runs, cur = [], []
    for i in range(len(pts) - 1):
        a = (pts[i][1], pts[i][0])
        b = (pts[i + 1][1], pts[i + 1][0])
        c = clip_seg(a, b, bbox)
        if c is None:
            if len(cur) >= 2:
                runs.append(cur)
            cur = []
            continue
        ca, cb = c
        if cur and abs(ca[0] - cur[-1][0]) < 1e-9 and abs(ca[1] - cur[-1][1]) < 1e-9:
            cur.append(cb)
        else:
            if len(cur) >= 2:
                runs.append(cur)
            cur = [ca, cb]
    if len(cur) >= 2:
        runs.append(cur)
    return runs


def http_json(url, params=None, tries=3):
    data = None
    if params:
        url = url + "?" + urllib.parse.urlencode(params)
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.loads(r.read())
        except Exception as e:
            if i == tries - 1:
                raise
            time.sleep(1.5 * (i + 1))
    return None


def overpass(query):
    last = None
    for ep in ENDPOINTS:
        try:
            return http_json(ep, {"data": query})
        except Exception as e:
            last = e
            print("Overpass-Endpunkt fehlgeschlagen:", ep, e, file=sys.stderr)
    raise SystemExit("Alle Overpass-Endpunkte fehlgeschlagen: %s" % last)


def geocode(name):
    hits = http_json("https://nominatim.openstreetmap.org/search",
                     {"q": name, "format": "json", "limit": 1})
    if not hits:
        raise SystemExit("Ort nicht gefunden: %r (bitte --lat/--lon angeben)" % name)
    return float(hits[0]["lat"]), float(hits[0]["lon"]), hits[0].get("display_name", "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="")
    ap.add_argument("--lat", type=float)
    ap.add_argument("--lon", type=float)
    ap.add_argument("--radius", type=float, default=1500, help="Halbbreite in Metern")
    ap.add_argument("--bbox", help="w,s,e,n (Lon/Lat) statt --name/--radius")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    if args.bbox:
        w, s, e, n = [float(x) for x in args.bbox.split(",")]
        clat, clon = (s + n) / 2, (w + e) / 2
    else:
        if args.lat is None or args.lon is None:
            if not args.name:
                raise SystemExit("--name oder --bbox oder --lat/--lon angeben")
            args.lat, args.lon, disp = geocode(args.name)
            print("Geokodiert:", disp)
        clat, clon = args.lat, args.lon
        dlat = args.radius / 110574.0
        dlon = args.radius / (111320.0 * math.cos(math.radians(clat)))
        w, s, e, n = clon - dlon, clat - dlat, clon + dlon, clat + dlat

    bbox = "%s,%s,%s,%s" % (s, w, n, e)
    print("bbox", bbox)

    q_build = ('[out:json][timeout:90];way["building"](%s);out tags geom;' % bbox)
    q_roads = ('[out:json][timeout:90];way["highway"](%s);out tags geom;' % bbox)
    q_places = ('[out:json][timeout:90];node["place"~"^(village|hamlet|isolated_dwelling)$"](%s);out;' % bbox)

    print("lade Gebäude ...")
    elems = overpass(q_build).get("elements", [])
    print("lade Straßen ...")
    roads_raw = overpass(q_roads).get("elements", [])
    print("lade Orte ...")
    places_raw = overpass(q_places).get("elements", [])

    K = math.cos(clat * math.pi / 180)
    MX = 111320.0 * K
    MY = 110574.0

    def xy(lat, lon):
        return ((lon - clon) * MX, (lat - clat) * MY)

    def seg_dist(p, a, b):
        dx, dy = b[0] - a[0], b[1] - a[1]
        if dx == 0 and dy == 0:
            return math.hypot(p[0] - a[0], p[1] - a[1])
        t = max(0, min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)))
        return math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy))

    places = []
    for el in places_raw:
        tags = el.get("tags", {})
        if tags.get("name"):
            places.append({"name": tags["name"], "kind": tags["place"],
                           "lat": round(el["lat"], 7), "lon": round(el["lon"], 7)})
    if not places:
        places = [{"name": args.name or "Karte", "kind": "village",
                   "lat": round(clat, 7), "lon": round(clon, 7)}]

    streets = []
    for el in roads_raw:
        tags = el.get("tags", {})
        hw = tags.get("highway")
        geom = el.get("geometry") or []
        if hw not in DRIVABLE or len(geom) < 2:
            continue
        pts = [[round(g["lat"], 6), round(g["lon"], 6)] for g in geom]
        for run in clip_line(pts, (w, s, e, n)):
            run_pts = [[round(lat, 6), round(lon, 6)] for lon, lat in run]
            streets.append({"type": hw, "name": tags.get("name"),
                            "pts": run_pts, "xy": [xy(la, lo) for la, lo in run_pts]})

    buildings = []
    centers = [(p["name"], p["lat"], p["lon"]) for p in places]
    for el in elems:
        tags = el.get("tags", {})
        geom = el.get("geometry") or []
        if len(geom) < 3:
            continue
        pts = [[round(g["lat"], 6), round(g["lon"], 6)] for g in geom]
        pxy = [xy(la, lo) for la, lo in pts]
        area = abs(sum(pxy[i][0] * pxy[(i + 1) % len(pxy)][1]
                       - pxy[(i + 1) % len(pxy)][0] * pxy[i][1]
                       for i in range(len(pxy)))) / 2.0
        xs = [p[0] for p in pxy]
        ys = [p[1] for p in pxy]
        la = sum(p[0] for p in pts) / len(pts)
        lo = sum(p[1] for p in pts) / len(pts)
        near_place = min(centers, key=lambda c: (c[1] - la) ** 2 + (c[2] - lo) ** 2)
        dist = math.hypot(xy(near_place[1], near_place[2])[0] - xy(la, lo)[0],
                          xy(near_place[1], near_place[2])[1] - xy(la, lo)[1])
        village = near_place[0] if dist < 900 else "Umland"

        best_name, best_d = None, 1e9
        for st in streets:
            for i in range(len(st["xy"]) - 1):
                for p in pxy:
                    d = seg_dist(p, st["xy"][i], st["xy"][i + 1])
                    if d < best_d:
                        best_d, best_name = d, st["name"]
        ring = pts + [pts[0]]

        buildings.append({
            "type": "Feature",
            "geometry": {"type": "Polygon", "coordinates": [ring]},
            "properties": {
                "osm_id": str(el["id"]),
                "village": village,
                "area_m2": round(area),
                "width_m": round(max(xs) - min(xs), 1),
                "depth_m": round(max(ys) - min(ys), 1),
                "street": best_name if best_d <= 80 else None,
                "street_m": round(best_d) if best_d <= 80 else None,
                "near_street": best_name if 80 < best_d <= 400 else None,
                "near_m": round(best_d) if 80 < best_d <= 400 else None,
                "building": tags.get("building"),
                "levels": tags.get("building:levels"),
                "roof": tags.get("roof:shape"),
                "addr": " ".join(x for x in (tags.get("addr:street"), tags.get("addr:housenumber")) if x) or None,
            },
        })

    roads = [{"t": st["type"],
              "p": [[la, lo] for la, lo in st["pts"]]} for st in streets]

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "buildings.js"), "w", encoding="utf-8") as f:
        f.write("window.BUILDINGS=" + json.dumps(
            {"type": "FeatureCollection", "features": buildings},
            ensure_ascii=False, separators=(",", ":")) + ";")
    with open(os.path.join(args.out, "roads.js"), "w", encoding="utf-8") as f:
        f.write("window.ROADS=" + json.dumps(roads, ensure_ascii=False, separators=(",", ":")) + ";")
    with open(os.path.join(args.out, "places.js"), "w", encoding="utf-8") as f:
        f.write("window.PLACES=" + json.dumps(places, ensure_ascii=False, separators=(",", ":")) + ";")
    with open(os.path.join(args.out, "bbox.json"), "w") as f:
        json.dump({"w": w, "s": s, "e": e, "n": n, "center_lat": clat, "center_lon": clon,
                   "radius": args.radius, "name": args.name}, f, indent=2)

    print("Gebäude: %d  Straßen: %d  Orte: %d" % (len(buildings), len(roads), len(places)))
    print("mit Straßenzuordnung:", sum(1 for b in buildings if b["properties"]["street"]))


if __name__ == "__main__":
    main()
