#!/usr/bin/env python3
"""LoD2-CityGML (AdV) -> web/data/lod2.js

Liest CityGML-Kacheln (.gml) aus data/lod2/, projiziert UTM -> WGS84,
rechnet in die Three.js-Szenenkoordinaten um und schreibt je Gebaeude
triangulierte Flaechen (Dach/Wand) inkl. Zuordnung zu OSM-Gebaeuden.

Die UTM-Zone wird aus der Bbox-Mitte abgeleitet, der lokale Mercator-
Massstab aus der mittleren Breite (identisch zu iso.js).
"""
import json, math, os, re, subprocess, sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(ROOT, 'web')
LOD2_DIR = os.path.join(ROOT, 'data', 'lod2')
OUT = os.path.join(WEB, 'data', 'lod2.js')

R = 6378137.0
D2R = math.pi / 180
K = 1.0          # cos(Breite), wird aus meta.json gesetzt
mx = lambda lon: lon * D2R * R * K
my = lambda lat: R * math.log(math.tan(math.pi / 4 + lat * D2R / 2)) * K

A = 6378137.0
F = 1 / 298.257223563
E2 = F * (2 - F)
EP2 = E2 / (1 - E2)
K0 = 0.9996
FE = 500000.0
LON0 = 0.0       # Mittelmeridian der UTM-Zone, wird aus meta.json gesetzt

def utm_to_lonlat(e, n):
    x = e - FE
    y = n
    m = y / K0
    mu = m / (A * (1 - E2 / 4 - 3 * E2 ** 2 / 64 - 5 * E2 ** 3 / 256))
    e1 = (1 - math.sqrt(1 - E2)) / (1 + math.sqrt(1 - E2))
    p1 = (mu + (3 * e1 / 2 - 27 * e1 ** 3 / 32) * math.sin(2 * mu)
          + (21 * e1 ** 2 / 16 - 55 * e1 ** 4 / 32) * math.sin(4 * mu)
          + (151 * e1 ** 3 / 96) * math.sin(6 * mu)
          + (1097 * e1 ** 4 / 512) * math.sin(8 * mu))
    sp, cp = math.sin(p1), math.cos(p1)
    t1 = math.tan(p1) ** 2
    c1 = EP2 * cp ** 2
    n1 = A / math.sqrt(1 - E2 * sp ** 2)
    r1 = A * (1 - E2) / (1 - E2 * sp ** 2) ** 1.5
    d = x / (n1 * K0)
    lat = p1 - (n1 * math.tan(p1) / r1) * (
        d ** 2 / 2
        - (5 + 3 * t1 + 10 * c1 - 4 * c1 ** 2 - 9 * EP2) * d ** 4 / 24
        + (61 + 90 * t1 + 298 * c1 + 45 * t1 ** 2 - 252 * EP2 - 3 * c1 ** 2) * d ** 6 / 720)
    lon = LON0 + (d - (1 + 2 * t1 + c1) * d ** 3 / 6
                  + (5 - 2 * c1 + 28 * t1 - 3 * c1 ** 2 + 8 * EP2 + 24 * t1 ** 2) * d ** 5 / 120) / cp
    return lon / D2R, lat / D2R

def load_osm():
    p = os.path.join(WEB, 'data', 'buildings.js')
    txt = open(p, encoding='utf-8').read().strip()
    txt = txt[txt.index('=') + 1:].strip().rstrip(';').strip()
    try:
        obj = json.loads(txt)
    except json.JSONDecodeError:
        # Toleranz fuer aeltere Dateien mit JS-Literal-Syntax
        txt = re.sub(r"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:", r'\1"\2":', txt)
        obj = json.loads(txt.replace("'", '"'))
    return obj['features']

def main():
    meta = json.load(open(os.path.join(WEB, 'data', 'scene', 'meta.json')))
    grid = json.load(open(os.path.join(WEB, 'data', 'scene', 'height.json')))
    w, s, e, n = meta['w'], meta['s'], meta['e'], meta['n']

    global K, LON0
    clat, clon = (s + n) / 2, (w + e) / 2
    K = math.cos(clat * D2R)
    zone = int((clon + 180) / 6) + 1
    LON0 = (zone * 6 - 183) * D2R
    print('UTM-Zone %d  Mittelmeridian %.0f  cos(lat) %.4f' % (zone, zone * 6 - 183, K))
    WW = mx(e) - mx(w)
    WD = my(n) - my(s)
    CX = (mx(w) + mx(e)) / 2
    CY = (my(s) + my(n)) / 2

    def sample(lat, lon):
        x = mx(lon) - CX
        z = -(my(lat) - CY)
        u = min(max(x / WW + 0.5, 0), 1)
        v = min(max(1 - (z / WD + 0.5), 0), 1)
        gs = grid['size']
        gi, gj = u * gs, v * gs
        i = min(int(gi), gs - 1); j = min(int(gj), gs - 1)
        fx, fj = gi - i, gj - j
        h = grid['h']
        a = h[j][i] * (1 - fx) + h[j][i + 1] * fx
        b = h[j + 1][i] * (1 - fx) + h[j + 1][i + 1] * fx
        return a * (1 - fj) + b * fj

    NS = '{http://www.opengis.net/citygml/building/1.0}'
    GML = '{http://www.opengis.net/gml}'

    def polys_of(el, kind):
        res = []
        for surf in el.iter(NS + kind):
            for pl in surf.iter(GML + 'posList'):
                dim = int(pl.get('srsDimension') or 3)
                v = [float(t) for t in pl.text.split()]
                pts = [tuple(v[i:i + dim]) for i in range(0, len(v) - dim + 1, dim)]
                if len(pts) >= 4 and pts[0][:2] == pts[-1][:2]:
                    pts = pts[:-1]
                if len(pts) >= 3:
                    res.append(pts)
        return res

    def area3(t):
        ax = (t[1][0] - t[0][0], t[1][1] - t[0][1], t[1][2] - t[0][2])
        bx = (t[2][0] - t[0][0], t[2][1] - t[0][1], t[2][2] - t[0][2])
        cx = ax[1] * bx[2] - ax[2] * bx[1]
        cy = ax[2] * bx[0] - ax[0] * bx[2]
        cz = ax[0] * bx[1] - ax[1] * bx[0]
        return 0.5 * math.sqrt(cx * cx + cy * cy + cz * cz)

    def normal(pts):
        nx = ny = nz = 0.0
        for i in range(len(pts)):
            p, q = pts[i], pts[(i + 1) % len(pts)]
            nx += (p[1] - q[1]) * (p[2] + q[2])
            ny += (p[2] - q[2]) * (p[0] + q[0])
            nz += (p[0] - q[0]) * (p[1] + q[1])
        return nx, ny, nz

    def earclip(pts):
        '''Ohrschneiden in der Ebene mit der kleinsten Normalenkomponente.'''
        nx, ny, nz = normal(pts)
        ax = max(range(3), key=lambda i: abs((nx, ny, nz)[i]))
        u, v = [(1, 2), (2, 0), (0, 1)][ax]
        poly = [(p[u], p[v]) for p in pts]
        idx = list(range(len(poly)))
        if sum(poly[i][0] * poly[(i + 1) % len(poly)][1]
               - poly[(i + 1) % len(poly)][0] * poly[i][1] for i in range(len(poly))) < 0:
            idx.reverse()

        def inside(t, p):
            (a, b, c) = t
            d1 = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
            d2 = (c[0] - b[0]) * (p[1] - b[1]) - (c[1] - b[1]) * (p[0] - b[0])
            d3 = (a[0] - c[0]) * (p[1] - c[1]) - (a[1] - c[1]) * (p[0] - c[0])
            neg = d1 < -1e-9 or d2 < -1e-9 or d3 < -1e-9
            pos = d1 > 1e-9 or d2 > 1e-9 or d3 > 1e-9
            return not (neg and pos)

        tris = []
        guard = 0
        while len(idx) > 3 and guard < 500:
            guard += 1
            cut = False
            for k in range(len(idx)):
                i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
                a, b, c = poly[i0], poly[i1], poly[i2]
                cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
                if cross <= 1e-9:
                    continue
                if any(inside((a, b, c), poly[j]) for j in idx
                       if j not in (i0, i1, i2)):
                    continue
                tris.append((i0, i1, i2))
                idx.pop(k)
                cut = True
                break
            if not cut:
                break
        if len(idx) == 3:
            tris.append(tuple(idx))
        return tris

    buildings = []
    seen = set()
    for fn in sorted(os.listdir(LOD2_DIR)):
        if not fn.endswith('.gml'):
            continue
        path = os.path.join(LOD2_DIR, fn)
        root = ET.parse(path).getroot()
        for mem in root.iter('{http://www.opengis.net/citygml/1.0}cityObjectMember'):
            for b in list(mem):
                tag = b.tag.split('}')[-1]
                if tag not in ('Building', 'BuildingPart'):
                    continue
                gid = b.get('{http://www.opengis.net/gml}id') or ''
                if not gid or gid in seen:
                    continue
                # nur Top-Level; Parts sind in ihrem Building enthalten
                if tag == 'BuildingPart':
                    continue
                seen.add(gid)
                roof = polys_of(b, 'RoofSurface')
                wall = polys_of(b, 'WallSurface')
                ground = polys_of(b, 'GroundSurface')
                if not roof and not wall:
                    continue
                allpts = [p for poly in (roof + wall + ground) for p in poly]
                if not allpts:
                    continue
                # Grundriss-Zentrum aus Ground/Wall-Fußpunkten
                base = [p for poly in (ground or wall) for p in poly]
                if not base:
                    base = allpts
                ce = sum(p[0] for p in base) / len(base)
                cn = sum(p[1] for p in base) / len(base)
                cz = min(p[2] for p in base)
                lon, lat = utm_to_lonlat(ce, cn)
                buildings.append(dict(id=gid, lon=lon, lat=lat, ce=ce, cn=cn,
                                      z0=cz, roof=roof, wall=wall,
                                      rt=len(roof), wt=len(wall)))

    # Datums-Offset DHHN2016 vs. DEM: Median der Bodenhoehen-Differenzen
    diffs = []
    for b in buildings:
        if b['z0']:
            diffs.append(b['z0'] - sample(b['lat'], b['lon']))
    diffs.sort()
    off = diffs[len(diffs) // 2] if diffs else 0.0
    diffs_abs = sorted(abs(d) for d in diffs)
    print(f'Gebaeude: {len(buildings)}  Offset-Median: {off:.2f} m  '
          f'|Diff| Median: {diffs_abs[len(diffs_abs)//2]:.2f} m  max: {diffs_abs[-1]:.2f} m')

    osm = load_osm()
    ocent = []
    for f in osm:
        ring = f['geometry']['coordinates'][0]
        ocent.append((f['properties'], sum(p[0] for p in ring) / len(ring), sum(p[1] for p in ring) / len(ring)))

    # naechstes OSM-Gebaeude (Grad-Abstand, ~0.9 m pro 1e-5)
    out = []
    matched = 0
    for b in buildings:
        best = None; bd = 1e9
        for props, olon, olat in ocent:
            dy = (olat - b['lat']) * 111320
            dx = (olon - b['lon']) * 111320 * math.cos(b['lat'] * D2R)
            d = math.hypot(dx, dy)
            if d < bd:
                bd = d; best = props
        oid = best['osm_id'] if (best and bd <= 11) else None
        if oid:
            matched += 1
        # Dreiecke in Szenenkoordinaten, relativ zum Gebaeude-Origin (cm, int)
        sx = mx(b['lon']) - CX
        sz = -(my(b['lat']) - CY)
        ox, oz = round(sx, 1), round(sz, 1)
        oy = round(b['z0'] - off, 1)
        verts = []
        kinds = []
        quads = []
        for kind, polys in (('r', b['roof']), ('w', b['wall'])):
            for poly in polys:
                pts = []
                for e_, n_, h_ in poly:
                    lo, la = utm_to_lonlat(e_, n_)
                    pts.append((mx(lo) - CX - ox, h_ - off - oy, -(my(la) - CY) - oz))
                quads.append((kind, pts))
        allp = [p for _, pts in quads for p in pts]
        if not allp:
            continue
        bcx = sum(p[0] for p in allp) / len(allp)
        bcz = sum(p[2] for p in allp) / len(allp)
        for kind, pts in quads:
            if True:
                for i0, i1, i2 in earclip(pts):
                    tri = (pts[i0], pts[i1], pts[i2])
                    if area3(tri) < 0.02:
                        continue
                    tn = normal(list(tri))
                    tx = (tri[0][0] + tri[1][0] + tri[2][0]) / 3
                    tz = (tri[0][2] + tri[1][2] + tri[2][2]) / 3
                    if kind == 'r':
                        flip = tn[1] < 0
                    else:
                        flip = tn[0] * (tx - bcx) + tn[2] * (tz - bcz) < 0
                    if flip:
                        tri = (tri[0], tri[2], tri[1])
                    for p in tri:
                        verts.extend((int(round(p[0] * 100)), int(round(p[1] * 100)), int(round(p[2] * 100))))
                    kinds.append(kind)
        if not kinds:
            continue
        out.append({'i': b['id'], 'o': oid, 'x': ox, 'y': oy, 'z': oz,
                    'p': verts, 'k': ''.join(kinds)})

    js = ('window.LOD2={src:"LoD2 (AdV CityGML, Open Data)",'
          'off:%s,n:%d,b:[' % (round(off, 2), len(out)))
    js += ','.join(json.dumps(o, separators=(',', ':')) for o in out)
    js += ']};'
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(js)
    print(f'OSM-Zuordnung: {matched}/{len(out)}  ->  {OUT} ({os.path.getsize(OUT)/1024:.0f} kB)')

if __name__ == '__main__':
    main()
