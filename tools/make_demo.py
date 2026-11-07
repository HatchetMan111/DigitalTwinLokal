#!/usr/bin/env python3
"""Erzeugt einen vollstaendig frei erfundenen Demo-Ort.

Es werden keinerlei reale Geodaten verwendet: Gelände, Felder, Wälder,
Straßen, Gebäude, Dachformen und Ortsnamen sind synthetisch. Damit läuft
die Karte ohne externe Quellen und ohne Rückschlüsse auf einen echten Ort.

Ausgabe (identische Formate wie nach der echten Datenaufbereitung):
  web/data/buildings.js
  web/data/lod2.js
  web/data/roads.js
  web/data/places.js
  web/data/scene/meta.json
  web/data/scene/height.json
  web/data/scene/ground.jpg      (gemaltes Orthofoto-Äquivalent)
  web/data/scene/ortho.jpg       (Rohbild, nur zur Dokumentation)
"""
import json
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "web", "data")
SCENE = os.path.join(OUT, "scene")

W, S, E, N = 11.4980, 48.0980, 11.5320, 48.1220
R = 6378137.0
D2R = math.pi / 180
K = math.cos((S + N) / 2 * D2R)
CX = ((W + E) / 2) * D2R * R * K
CY = R * math.log(math.tan(math.pi / 4 + (S + N) / 2 * D2R / 2)) * K
WW = (E - W) * D2R * R * K
WD = abs(R * math.log(math.tan(math.pi / 4 + N * D2R / 2)) * K
         - R * math.log(math.tan(math.pi / 4 + S * D2R / 2)) * K)

rnd = random.Random(7)


def mx(lon):
    return lon * D2R * R * K


def my(lat):
    return R * math.log(math.tan(math.pi / 4 + lat * D2R / 2)) * K


def to_lonlat(x, z):
    lon = (x + CX) / (D2R * R * K)
    lat = (2 * math.atan(math.exp((CY - z) / (R * K))) - math.pi / 2) / D2R
    return lon, lat


def height(x, z):
    return (508.0
            + 17 * math.sin((x + 280) / 540)
            + 13 * math.cos((z - 120) / 420)
            + 6 * math.sin((x - z) / 240)
            + 3.5 * math.cos((x + 2 * z) / 300))


VILLAGES = [
    ("Musterhausen", "village", 0, 0),
    ("Beispielweiler", "hamlet", -820, 640),
    ("Waldhagen", "hamlet", 760, -700),
]

MAIN = (-1250, 1100), (-980, 900), (-720, 660), (-470, 400), (-230, 170), (30, -20), (330, -230), (620, -470), (900, -730), (1100, -930)

ROADS = [("Dorfstraße", "secondary", list(MAIN))]


def rotated_grid(theta, cx, cz, lines):
    c, s = math.cos(theta), math.sin(theta)
    out = []
    for name, kind, pts in lines:
        out.append((name, kind, [(cx + x * c - z * s, cz + x * s + z * c) for x, z in pts]))
    return out


ROADS += rotated_grid(0.35, 0, 0, [
    ("Schulstraße", "residential", [(-155, -100), (155, -100)]),
    ("Am Anger", "residential", [(-155, 25), (155, 25)]),
    ("Gartenweg", "residential", [(-150, 120), (115, 120)]),
    ("Bergstraße", "residential", [(-105, -150), (-105, 165)]),
    ("Ringstraße", "residential", [(95, -150), (95, 165)]),
])
ROADS += [
    ("Wiesenweg", "residential", [(-900, 600), (-735, 600)]),
    ("Talstraße", "residential", [(-820, 505), (-820, 725)]),
    ("Hangweg", "residential", [(685, -660), (845, -660)]),
    ("Lindenweg", "residential", [(755, -770), (755, -615)]),
    ("Mühlweg", "track", [(300, 260), (640, 520), (900, 620)]),
    ("Feldrain", "track", [(-380, -220), (-780, -460), (-980, -520)]),
    ("Am Wald", "track", [(-120, 380), (180, 700), (300, 980)]),
    ("Kirchsteig", "track", [(60, -100), (60, 140)]),
]


# ---------------------------------------------------------------- Gelände
def write_height():
    size = 160
    rows = []
    for j in range(size + 1):
        lat = S + (N - S) * j / size
        row = []
        for i in range(size + 1):
            lon = W + (E - W) * i / size
            x = mx(lon) - CX
            z = -(my(lat) - CY)
            row.append(round(height(x, z), 1))
        rows.append(row)
    doc = {"w": W, "s": S, "e": E, "n": N, "size": size, "h": rows}
    with open(os.path.join(SCENE, "height.json"), "w") as f:
        json.dump(doc, f, separators=(",", ":"))
    return doc


# ------------------------------------------------------------ Bodenbild
def draw_ground():
    iw = 1500
    ih = int(round(iw * WD / WW))
    img = Image.new("RGB", (iw, ih), (143, 158, 106))
    d = ImageDraw.Draw(img, "RGBA")

    def sx(x):
        return (x / WW + 0.5) * iw

    def sy(z):
        return (0.5 - z / WD) * ih

    palette = ["#b8b083", "#a8ab72", "#94a463", "#82965c", "#c3b98d",
               "#9da86b", "#8b9c60", "#b0a87e", "#a3a06c", "#97a768"]

    for _ in range(620):
        px, pz = rnd.uniform(-WW / 2, WW / 2), rnd.uniform(-WD / 2, WD / 2)
        w, h = rnd.uniform(28, 95), rnd.uniform(24, 78)
        ang = rnd.uniform(0, math.pi)
        c, s = math.cos(ang), math.sin(ang)
        pts = [(px + -w / 2 * c - -h / 2 * s, pz + -w / 2 * s + -h / 2 * c),
               (px + w / 2 * c - -h / 2 * s, pz + w / 2 * s + -h / 2 * c),
               (px + w / 2 * c - h / 2 * s, pz + w / 2 * s + h / 2 * c),
               (px + -w / 2 * c - h / 2 * s, pz + -w / 2 * s + h / 2 * c)]
        d.polygon([(sx(a), sy(b)) for a, b in pts], fill=rnd.choice(palette) + "e6")

    for name, kind, cx, cz in VILLAGES:
        rr = 150 if kind == "village" else 85
        for _ in range(6):
            ox, oz = rnd.uniform(-rr * 0.22, rr * 0.22), rnd.uniform(-rr * 0.22, rr * 0.22)
            rw = rr * rnd.uniform(0.72, 1.0)
            d.ellipse([sx(cx + ox - rw), sy(cz + oz + rw), sx(cx + ox + rw), sy(cz + oz - rw)],
                      fill=(188, 180, 150, 120))
        for _ in range(46 if kind == "village" else 16):
            gx, gz = cx + rnd.uniform(-rr, rr), cz + rnd.uniform(-rr, rr)
            if math.hypot(gx - cx, gz - cz) > rr * 0.95:
                continue
            rw, rh = rnd.uniform(7, 19), rnd.uniform(6, 16)
            d.ellipse([sx(gx - rw), sy(gz + rh), sx(gx + rw), sy(gz - rh)],
                      fill=rnd.choice([(148, 158, 106, 150), (131, 148, 96, 150), (170, 168, 126, 140)]))

    for _ in range(34):
        while True:
            px, pz = rnd.uniform(-WW / 2 + 70, WW / 2 - 70), rnd.uniform(-WD / 2 + 70, WD / 2 - 70)
            if all(math.hypot(px - vx, pz - vz) > 240 for _, _, vx, vz in VILLAGES):
                break
        for _ in range(rnd.randint(16, 30)):
            qx, qz = px + rnd.uniform(-105, 105), pz + rnd.uniform(-90, 90)
            rw, rh = rnd.uniform(24, 62), rnd.uniform(20, 52)
            d.ellipse([sx(qx - rw), sy(qz + rh), sx(qx + rw), sy(qz - rh)],
                      fill=rnd.choice([(44, 64, 38), (50, 73, 43), (40, 59, 35), (56, 79, 47)]))

    for _ in range(150):
        hx, hz = rnd.uniform(-WW / 2, WW / 2), rnd.uniform(-WD / 2, WD / 2)
        ang = rnd.uniform(0, math.pi)
        ln = rnd.uniform(14, 70)
        d.line([(sx(hx), sy(hz)), (sx(hx + math.cos(ang) * ln), sy(hz + math.sin(ang) * ln))],
               fill=(74, 92, 54, 110), width=2)

    for name, kind, pts in ROADS:
        wpx = 5 if kind == "secondary" else 3
        d.line([(sx(x), sy(z)) for x, z in pts], fill=(184, 170, 140, 255), width=wpx, joint="curve")

    img = img.filter(ImageFilter.MedianFilter(5))
    img = img.quantize(colors=48, method=Image.MEDIANCUT).convert("RGB")
    img = img.filter(ImageFilter.GaussianBlur(0.4))
    img.save(os.path.join(SCENE, "ground.jpg"), quality=88, optimize=True, progressive=True)
    img.save(os.path.join(SCENE, "ortho.jpg"), quality=86, optimize=True)
    print("ground.jpg", img.size)


# -------------------------------------------------------------- Gebäude
def polyline_points(pts, spacing, offset):
    """Punkte entlang einer Linie, alternierend links/rechts versetzt."""
    out = []
    for i in range(len(pts) - 1):
        x0, z0 = pts[i]
        x1, z1 = pts[i + 1]
        dx, dz = x1 - x0, z1 - z0
        ln = math.hypot(dx, dz) or 1
        tx, tz = dx / ln, dz / ln
        nx, nz = -tz, tx
        t = spacing * 0.5
        side = 1
        while t < ln:
            px, pz = x0 + tx * t, z0 + tz * t
            yield (px + nx * offset * side, pz + nz * offset * side), math.atan2(tz, tx)
            side = -side
            t += spacing


def seg_dist(px, pz, ax, az, bx, bz):
    dx, dz = bx - ax, bz - az
    if dx == 0 and dz == 0:
        return math.hypot(px - ax, pz - az)
    t = max(0, min(1, ((px - ax) * dx + (pz - az) * dz) / (dx * dx + dz * dz)))
    return math.hypot(px - (ax + t * dx), pz - (az + t * dz))


def nearest_road(x, z, kinds):
    best = (None, 1e9)
    for name, kind, pts in ROADS:
        if kind not in kinds:
            continue
        for i in range(len(pts) - 1):
            dd = seg_dist(x, z, *pts[i], *pts[i + 1])
            if dd < best[1]:
                best = (name, dd)
    return best


def write_buildings():
    placed = []
    buildings = []
    church = (46, -78)

    def free(x, z, r):
        if math.hypot(x - church[0], z - church[1]) < r + 22:
            return False
        for px, pz, pr in placed:
            if math.hypot(x - px, z - pz) < r + pr + 5:
                return False
        return True

    def add(x, z, w, d, rot, kind, street, street_m, near, near_m):
        if not (-WW / 2 + 40 < x < WW / 2 - 40 and -WD / 2 + 40 < z < WD / 2 - 40):
            return
        r = 0.5 * math.hypot(w, d)
        if not free(x, z, r):
            return
        placed.append((x, z, r))
        village = min(VILLAGES, key=lambda v: math.hypot(v[2] - x, v[3] - z))
        vname = village[0] if math.hypot(village[2] - x, village[3] - z) < 850 else "Umland"
        c, s = math.cos(rot), math.sin(rot)
        local = [(-w / 2, -d / 2), (w / 2, -d / 2), (w / 2, d / 2), (-w / 2, d / 2)]
        ring = []
        for lx, lz in local:
            lon, lat = to_lonlat(x + lx * c - lz * s, z + lx * s + lz * c)
            ring.append([round(lon, 7), round(lat, 7)])
        ring.append(ring[0])
        buildings.append({
            "type": "Feature",
            "geometry": {"type": "Polygon", "coordinates": [ring]},
            "properties": {
                "osm_id": str(900000 + len(buildings)),
                "village": vname,
                "area_m2": round(w * d),
                "width_m": round(w, 1),
                "depth_m": round(d, 1),
                "street": street,
                "street_m": int(round(street_m)) if street else None,
                "near_street": near,
                "near_m": int(round(near_m)) if near else None,
                "building": kind,
                "levels": "2" if kind in ("house", "residential") and rnd.random() < 0.45 else "1",
                "roof": "gable" if kind not in ("garage", "shed") else "flat",
                "addr": None,
                "_x": round(x, 1), "_z": round(z, 1), "_w": w, "_d": d, "_rot": rot,
            },
        })

    for name, kind, pts in ROADS:
        if kind == "track":
            continue
        spacing = 27 if kind == "secondary" else 23
        offset = 13.5 if kind == "secondary" else 10.5
        for (x, z), tangent in polyline_points(pts, spacing, offset):
            x += rnd.uniform(-3, 3)
            z += rnd.uniform(-3, 3)
            if kind == "secondary" and min(math.hypot(x - vx, z - vz) for _, _, vx, vz in VILLAGES) > 280:
                continue
            street, sd = nearest_road(x, z, ("secondary", "residential"))
            near, nd = nearest_road(x, z, ("secondary", "residential", "track"))
            w = rnd.uniform(7.0, 12.5)
            d = rnd.uniform(6.0, 9.5)
            if kind == "secondary" and rnd.random() < 0.18:
                w, d = rnd.uniform(11, 15), rnd.uniform(8, 11)
            roll = rnd.random()
            if roll < 0.58:
                b = "house"
            elif roll < 0.70:
                b = "farm"
            elif roll < 0.76:
                b = "barn"
            elif roll < 0.82:
                b = "shed"
            elif roll < 0.88:
                b = "garage"
            elif roll < 0.92:
                b = "stable"
            elif roll < 0.95:
                b = "farm_auxiliary"
            else:
                b = "yes"
            add(x, z, w, d, tangent + rnd.uniform(-0.12, 0.12), b,
                street if sd <= 70 else None, sd,
                near if nd <= 320 else None, nd)
            if rnd.random() < 0.42:
                bx = x + math.cos(tangent + math.pi / 2) * rnd.uniform(15, 21) * rnd.choice([-1, 1])
                bz = z + math.sin(tangent + math.pi / 2) * rnd.uniform(15, 21) * rnd.choice([-1, 1])
                add(bx, bz, rnd.uniform(7, 13), rnd.uniform(6, 9), tangent + rnd.uniform(-0.2, 0.2),
                    rnd.choice(["house", "barn", "shed", "stable", "garage"]), street if sd <= 90 else None, sd,
                    near if nd <= 320 else None, nd)

    for _ in range(18):
        ang = rnd.uniform(0, math.tau)
        rad = rnd.uniform(280, 1080)
        x, z = math.cos(ang) * rad, math.sin(ang) * rad * 0.8
        near, nd = nearest_road(x, z, ("secondary", "residential", "track"))
        add(x, z, rnd.uniform(8, 16), rnd.uniform(7, 12), rnd.uniform(0, math.pi),
            rnd.choice(["barn", "farm", "stable", "shed"]), None, 0,
            near if nd <= 320 else None, nd)

    add(church[0], church[1], 13.5, 24.0, 0.35, "church", "Kirchsteig", 42, "Kirchsteig", 42)

    public = [dict(f, properties={k: v for k, v in f["properties"].items() if not k.startswith("_")})
              for f in buildings]
    with open(os.path.join(OUT, "buildings.js"), "w", encoding="utf-8") as f:
        f.write("window.BUILDINGS=" + json.dumps(
            {"type": "FeatureCollection", "features": public},
            ensure_ascii=False, separators=(",", ":")) + ";")
    print("buildings.js", len(buildings))
    return buildings


# ------------------------------------------------------------- LoD2-Dächer
def tri_normal(t):
    ax = (t[1][0] - t[0][0], t[1][1] - t[0][1], t[1][2] - t[0][2])
    bx = (t[2][0] - t[0][0], t[2][1] - t[0][1], t[2][2] - t[0][2])
    return (ax[1] * bx[2] - ax[2] * bx[1],
            ax[2] * bx[0] - ax[0] * bx[2],
            ax[0] * bx[1] - ax[1] * bx[0])


def write_lod2(buildings):
    out = []
    for f in buildings:
        p = f["properties"]
        if math.hypot(p["_x"], p["_z"]) > 460:
            continue
        w, d, rot = p["_w"], p["_d"], p["_rot"]
        if d > w:
            w, d, rot = d, w, rot + math.pi / 2
        if w < 8:
            continue
        wh = 3.0 if p["building"] not in ("church", "barn", "farm") else 4.6
        rh = max(2.0, min(w, d) * 0.42)
        if p["building"] == "church":
            wh, rh = 7.5, 6.5
        a, b = w / 2, d / 2
        o = 0.38

        def wp(lx, ly, lz):
            c, s = math.cos(rot), math.sin(rot)
            return (lx * c - lz * s, ly, lx * s + lz * c)

        quads = []
        quads.append(("r", [(-a - o, wh, b + o), (a + o, wh, b + o),
                            (a + o, wh + rh, 0), (-a - o, wh + rh, 0)]))
        quads.append(("r", [(a + o, wh, -b - o), (-a - o, wh, -b - o),
                            (-a - o, wh + rh, 0), (a + o, wh + rh, 0)]))
        quads.append(("w", [(-a, 0, -b), (a, 0, -b), (a, wh, -b), (-a, wh, -b)]))
        quads.append(("w", [(a, 0, b), (-a, 0, b), (-a, wh, b), (a, wh, b)]))
        quads.append(("w", [(-a, 0, b), (-a, 0, -b), (-a, wh, -b), (-a, wh, b)]))
        quads.append(("w", [(a, 0, -b), (a, 0, b), (a, wh, b), (a, wh, -b)]))
        quads.append(("w", [(a, wh, -b), (a, wh, b), (a, wh + rh, 0)]))
        quads.append(("w", [(-a, wh, b), (-a, wh, -b), (-a, wh + rh, 0)]))

        verts, kinds = [], []
        allp = [wp(*q) for _, pts in quads for q in pts]
        bcx = sum(q[0] for q in allp) / len(allp)
        bcz = sum(q[2] for q in allp) / len(allp)
        for kind, pts in quads:
            p3 = [wp(*q) for q in pts]
            tris = [(p3[0], p3[1], p3[2])]
            if len(p3) == 4:
                tris.append((p3[0], p3[2], p3[3]))
            for tri in tris:
                n = tri_normal(tri)
                tx = sum(q[0] for q in tri) / 3
                tz = sum(q[2] for q in tri) / 3
                flip = (n[1] < 0) if kind == "r" else (n[0] * (tx - bcx) + n[2] * (tz - bcz) < 0)
                if flip:
                    tri = (tri[0], tri[2], tri[1])
                for q in tri:
                    verts.extend((int(round(q[0] * 100)), int(round(q[1] * 100)), int(round(q[2] * 100))))
                kinds.append(kind)

        out.append({"i": "demo-" + p["osm_id"], "o": p["osm_id"],
                    "x": round(p["_x"], 1), "y": 0.0, "z": round(p["_z"], 1),
                    "p": verts, "k": "".join(kinds)})

    doc = {"src": "Demo (synthetisch)", "off": 0, "n": len(out), "b": out}
    with open(os.path.join(OUT, "lod2.js"), "w", encoding="utf-8") as f:
        f.write("window.LOD2=" + json.dumps(doc, separators=(",", ":")) + ";")
    print("lod2.js", len(out))


# ------------------------------------------------------------------ Rest
def write_roads():
    roads = []
    for name, kind, pts in ROADS:
        roads.append({"t": kind, "p": [[round(to_lonlat(x, z)[1], 7), round(to_lonlat(x, z)[0], 7)]
                                       for x, z in pts]})
    with open(os.path.join(OUT, "roads.js"), "w", encoding="utf-8") as f:
        f.write("window.ROADS=" + json.dumps(roads, ensure_ascii=False, separators=(",", ":")) + ";")
    print("roads.js", len(roads))


def write_places():
    places = []
    for name, kind, x, z in VILLAGES:
        lon, lat = to_lonlat(x, z)
        places.append({"name": name, "kind": kind, "lat": round(lat, 7), "lon": round(lon, 7)})
    with open(os.path.join(OUT, "places.js"), "w", encoding="utf-8") as f:
        f.write("window.PLACES=" + json.dumps(places, ensure_ascii=False, separators=(",", ":")) + ";")
    print("places.js", len(places))


def write_meta():
    lon, lat = to_lonlat(0, 0)
    meta = {
        "w": W, "s": S, "e": E, "n": N,
        "img": [1500, int(round(1500 * WD / WW))],
        "title": "Musterhausen",
        "subtitle": "Beispielweiler · Waldhagen · frei erfundene Demo",
        "eyebrow": "Isometrische Karte",
        "attribution": "Demo · alle Geometrien und Namen frei erfunden · keine realen Daten",
        "focus": {"lat": round(lat, 7), "lon": round(lon, 7), "radius": 300},
    }
    with open(os.path.join(SCENE, "meta.json"), "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    print("meta.json")


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(SCENE, exist_ok=True)
    write_height()
    draw_ground()
    b = write_buildings()
    write_lod2(b)
    write_roads()
    write_places()
    write_meta()


if __name__ == "__main__":
    main()
