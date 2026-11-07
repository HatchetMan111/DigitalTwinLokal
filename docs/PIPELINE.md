# Technische Referenz

Diese Datei beschreibt, **wie** die Karte funktioniert: Koordinaten, Formate,
Geometrie, LoD2-Verarbeitung, Rendering und die wichtigsten Zahlen. Sie ist für
Agenten und Entwickler gedacht, die das Projekt anpassen oder debuggen.

---

## 1. Datenfluss

```
OSM (Overpass) ─┐
LoD2 (CityGML) ─┼─► tools/*.py ─► web/data/*.js ─┐
DGM (GeoTIFF)  ─┤                                ├─► iso.js ─► <canvas>
Orthofoto      ─┘                                │
                     web/data/scene/*.json/jpg ──┘
```

Zur Laufzeit gibt es genau zwei `fetch`-Aufrufe (`meta.json`, `height.json`).
Alles andere sind `<script>`-Globals. Es werden **keine** externen Hosts kontaktiert.

---

## 2. Koordinaten

### 2.1 Lokale Tangentialprojektion

Die App rechnet WGS84 in lokale Meter um, zentriert auf die Bbox-Mitte:

```
K   = cos((s+n)/2)                     // Maßstabsfaktor der Breite
mx(lon) = lon · π/180 · R · K          // R = 6378137
my(lat) = R · ln(tan(π/4 + lat·π/180/2)) · K
X = mx(lon) − (mx(w)+mx(e))/2          // Osten = +X
Z = −( my(lat) − (my(s)+my(n))/2 )     // Norden = −Z
Y = Höhe in Metern
```

`K` wird in `iso.js` beim Init aus `meta.json` gesetzt (nicht hart kodiert!). Dadurch
funktioniert das Projekt in jeder Breite. `mx`/`my` sind **sphärisches** Mercator,
kein Ellipsoid – für Karten in Dorfgröße ist der Unterschied < 0.1 %.

`toScene(lon, lat)` liefert `{x, z}`; `sampleH(x, z)` interpoliert das Höhenraster
bilinear.

### 2.2 Höhenraster

`height.json`:

```json
{"w":11.498,"s":48.098,"e":11.532,"n":48.122,"size":160,
 "h":[[508.1, ... 161 Werte ...], ... 161 Zeilen ...]}
```

- Zeile `j=0` = Südrand, Spalte `i=0` = Westrand
- `sampleH`: `u = x/W + 0.5`, `v = 1 − (z/D + 0.5)`, dann bilinear über `u·size`, `v·size`
- Einheiten: Meter; negative Werte sind zulässig

### 2.3 World-Box

`WORLD.w = mx(e) − mx(w)`, `WORLD.d = my(n) − my(s)`, Zentrum bei (0,0). Die Kamera
ist auf `WORLD/2 + MAP_PAD (420 m)` begrenzt.

---

## 3. Kamera und Darstellung

- `THREE.OrthographicCamera`, feste Blickrichtung `ISO = (0.6124, 0.5, 0.6124)`
  (≈ 30° Höhenwinkel, 45° Azimut)
- `BASE_H = 3000` = halbe Frustum-Höhe bei `zoom = 1`; `updateViewOffset()` setzt
  `left/right = ±BASE_H·aspect`, `top/bottom = ±BASE_H`
- Sichtbare Höhe ≈ `6000 / zoom` Meter (Boden wegen 30°-Neigung stärker)
- `OrbitControls`: `enableRotate = false`, `screenSpacePanning = true`,
  `zoomToCursor = true`, `minZoom 0.75`, `maxZoom 55`, links/rechts = PAN,
  Touch: 1 Finger = PAN, 2 Finger = DOLLY_PAN
- `reset()` rahmt `meta.focus` (Radius · 1.35); ohne `focus` die ganze Bbox
- `animateTo(target, zoom)` = 650 ms Cubic-Ease; `zoomBy(f)`; Doppelklick ×1.8

Labels:

- Canvas 1024×256, Serifenschrift, Letter-Spacing, heller Stroke als Halo
- `sizeAttenuation: true` (bei Ortho-Kameras ist `false` wirkungslos!)
- Weltgröße pro Frame: `ls = (2·BASE_H/zoom) · 0.14 · big`, `big` 1.15 (Dorf) /
  0.92 (Weiler) / 0.8 (sonst); mobil ×0.62
- `depthTest: false`, `y + 30 m`, keine Mipmaps (`LinearFilter`)

Licht:

- Hemisphere `0xeaf0f4 / 0x948b76`, Intensität 1.12
- Sonne `0xfff1d6`, Intensität 1.62, Position = Ziel + (−900, 1500, 700)
- Shadow-Camera folgt dem Ziel, Halbgröße `clamp(2100/zoom, 220, 1700)`
- ACES-Tonemapping, `background 0xeee7d7`, kein Nebel

Shader-Detail (Boden):

```js
mat.onBeforeCompile = (sh) => {
  sh.uniforms.uDetail = { value: tex };
  sh.fragmentShader = 'uniform sampler2D uDetail;\n' + sh.fragmentShader.replace(
    '#include <map_fragment>',
    '#include <map_fragment>\n#ifdef USE_MAP\n' +
    '  float dtl = texture2D(uDetail, vMapUv * 220.0).r;\n' +
    '  diffuseColor.rgb *= mix(1.0, 0.58 + dtl * 0.86, 0.30);\n#endif');
};
```

`vMapUv` ist der r186-Name. Ohne `#ifdef USE_MAP` schlägt der Shader fehl, solange
die Textur noch nicht geladen ist.

---

## 4. Dateiformate

### 4.1 `buildings.js`

```js
window.BUILDINGS = {type:'FeatureCollection', features:[{
  type:'Feature',
  geometry:{type:'Polygon', coordinates:[[[lon,lat], …, [lon,lat]]]},
  properties:{
    osm_id:'123', building:'house',      // building = OSM-Tag-Wert
    area_m2:96, width_m:11.2, depth_m:8.4,
    street:'Dorfstraße', street_m:12, near_street:null, near_m:null,
    village:'Musterhausen', levels:'1', roof:'gable', addr:null
  }
}]};
```

- Ring geschlossen (erster = letzter Punkt), `[lon, lat]`
- `width_m`/`depth_m` = achsenparallele Ausdehnung in Metern (nur für Dachhöhe)
- `building` steuert Palette, Höhe und Dachneigung (siehe `T` in `iso.js`)

### 4.2 `roads.js`

```js
window.ROADS = [{t:'residential', p:[[lat,lon], …]}, …];
```

Breiten/Farben aus `ROAD_W`/`ROAD_C` (`residential 6 m`, `track 3.2 m`, …). Gezeichnet
als zwei Bänder: Kaschte `#b3a17d` (Breite + 2.4 m, +0.20 m Höhe), Füllung (+0.32 m),
`polygonOffset: -2`, ein Mesh mit Vertexfarben, `DoubleSide`.

### 4.3 `places.js`

```js
window.PLACES = [{name:'Musterhausen', kind:'village', lat:48.11, lon:11.515}];
```

`kind` ∈ `village|hamlet|isolated_dwelling` → Labelgröße.

### 4.4 `lod2.js`

```js
window.LOD2 = {src:'…', off:−2.7, n:1, b:[{
  i:'DEN_ID', o:'osm_id', x:12.3, y:0, z:-45.6,
  p:[  /* pro Dreieck 9 Werte in Zentimetern, relativ zu (x,y,z) */ ],
  k:'rwwr'  /* ein Zeichen pro Dreieck: r=Dach, w=Wand */
}]};
```

- `o` = zugeordnete OSM-ID; nur dann wird das typisierte Gebäude unterdrückt
- `x/z` = Gebäudezentrum in Szenenmetern, `y` = Basis (wird von der App nicht
  verwendet – sie ankert am Gelände)
- `p` in **cm**, ganzzahlig, 3 Vertices × 3 Achsen je Dreieck
- `off` = abgezogener Datums-Offset (nur informativ, bereits in `p` verrechnet)

---

## 5. OSM-Aufbereitung (`fetch_osm.py`)

- Geokodierung über Nominatim (nur wenn `--lat/--lon` fehlen), mit User-Agent
- Overpass **GET** (`?data=…`), drei Endpunkte, 90 s Timeout, 3 Versuche
- Eine Query pro Ebene (`building`, `highway`, `place`), `out tags geom`
- Lokale Meter über `MX = 111320·K`, `MY = 110574` (ausreichend genau)
- Gebäude: Fläche (Shoelace), `width/depth` (Bbox), Zentroid, nächster Ort (< 900 m)
  → `village`, nächste benannte Straße (< 80 m → `street`, < 400 m → `near_street`)
- Filter: nur `DRIVABLE`-Highwaytypen, nur Wege mit ≥ 2 Punkten
- **Clipping**: Overpass liefert ganze Wege, auch über die Bbox hinaus. Jedes Segment
  wird per Liang-Barsky auf die Bbox geschnitten; eine Way kann dadurch in mehrere
  Teilstücke zerfallen. Ohne Clipping „wandern“ Straßen über den Kartenrand hinaus.

---

## 6. Orthofoto und Bodenbild

### 6.1 Kacheln

`build_scene.py` rechnet die Bbox in Web-Mercator-Pixel bei Zoom `z`:

```
x = (lon+180)/360 · 2^z
y = (0.5 − ln((1+sin φ)/(1−sin φ))/(4π)) · 2^z
```

Kacheln laden, mosaikieren, exakt auf die Bbox zuschneiden (Subpixel-Crop), auf
`--img-max` (Default 4096) skalieren, als `ortho.jpg` speichern. Fehlende Kacheln
werden grau gefüllt und geloggt.

Bei `--ortho-file` muss das Bild bereits die Bbox zeigen. Das Seitenverhältnis wird
auf `(e−w)·cos(lat)/(n−s)` gebracht – **nicht** auf das Grad-Verhältnis, sonst wird
das Bild um `1/cos(lat)` gestaucht.

### 6.2 Höhenmodell

- SRTM-Kacheln (`--srtm-dir`): 256-px-PNGs, Höhe = `R·256 + G + B/256 − 32768`,
  Kacheln bei z13 in `<x>/<y>.png`
- GeoTIFF (`--dem-geotiff`): Fenster über die Bbox lesen (rasterio), bilinear sampeln
- Ohne Quelle: alle Höhen 0 (flach), Warnung

### 6.3 Stil

`stylize_ground.py`: Median 9 → Sättigung 0.88 → Helligkeit 1.34 → Kontrast 1.07 →
Quantisierung auf 44 Farben → Blur 0.35 → JPEG q90. Ergebnis: ruhige, gemalte Flächen,
auf denen Gebäude und Straßen kontrastieren. `--keep-detail` überspringt die Abstraktion.

---

## 7. Typisierte Gebäude (`addBuilding`)

1. Ring → Szene, Duplikate entfernen, Zentroid
2. Wände: Quads vom Boden (`sampleH − 1.2 m`) bis Traufe (`+t.h`)
3. Hauptachse per PCA (`θ = 0.5·atan2(2·sxz, sxx−szz)`), OBB (Länge/Breite)
4. Deckungsgrad `area/(L·B) ≥ 0.82` → Satteldach:
   - First parallel zur längeren Achse, Neigung `t.pitch`
   - Firsthöhe `min(6.2, max(0.7, tan(pitch)·B/2))`
   - Überstand 0.45 m, zwei Dachflächen + zwei Giebel
5. sonst „Zeltdach“: Ring um `d = min(rh/tan, 0.42·min(L,B))` nach innen versetzen,
   Firstplateau triangulieren (funktioniert für L-, U- und verwinkelte Grundrisse)
6. flache Typen (`silo`, `water_tower`, `industrial` …) → Deckfläche per
   `ShapeUtils.triangulateShape`

Farben/Varianten: Palette `T` je `building`-Tag, Dachmischung `ROOF_MIX` mit
Hash-Variation, Wände leicht aufgehellt/abgedunkelt. Alles in **einem** Mesh
(Vertexfarben), `castShadow`.

---

## 8. LoD2-Verarbeitung (`build_lod2.py`)

1. **Lesen**: alle `data/lod2/*.gml`, `cityObjectMember` → `Building` (nur Top-Level;
   `BuildingPart` wird übersprungen, ist im Building enthalten)
2. **Flächen**: `RoofSurface`, `WallSurface`, `GroundSurface`; `posList` mit
   `srsDimension` (2 oder 3), Ring schließen, < 3 Punkte verwerfen
3. **Projektion**: UTM (Zone aus Bbox-Mitte) → WGS84 (Ellipsoid, K0 0.9996,
   Mittelmeridian `zone·6−183`) → lokale Szene (gleiche `mx/my` wie die App)
4. **Datum**: `z0 = min(y)` je Gebäude; Offset = **Median** von `z0 − sampleH(...)`;
   dieser Offset wird von allen Höhen abgezogen (DHHN2016 ≠ DGM)
5. **Triangulierung**: Ohrschneiden in der Ebene der kleinsten Normalkomponente
   (Projektion auf die zwei anderen Achsen), Flächen < 0.02 m² verwerfen
6. **Winding** (wichtig!):
   - Dach: `normal.y < 0` → Vertices 1/2 tauschen (Normale nach oben)
   - Wand: `dot(horizontale Normale, Flächenzentrum − Gebäudezentrum) < 0` → tauschen
     (Normale nach außen)
7. **Zuordnung**: nächster OSM-Zentroid ≤ 11 m → `o`; sonst `o = null` (bleibt
   zusätzlich zum typisierten Gebäude sichtbar)
8. **Ausgabe**: cm-Integer, `k`-String, `off`, `n`

In der App (`buildLod2`):

- `LOD2.suppress` = Menge der zugeordneten OSM-IDs → typisierte Gebäude entfallen
- Farbe: Dach steil (`|ny|/|n| ≤ 0.955`) → `ROOF_MIX`-Farbe des Gebäudetyps;
  flach → Grautöne; Wand → Wandfarbe des Typs
- `anchorY = sampleH(b.x, b.z) − 0.05`; Wandfuß (< 60 cm) wird zusätzlich auf
  `sampleH(vertex) − 0.15` gezogen → kein Schweben am Hang
- ein Mesh, `MeshLambertMaterial({vertexColors:true, side:DoubleSide})`,
  `castShadow`, `receiveShadow`, `name:'lod2'`

---

## 9. Bäume und Wald

- Bodenbild in ein Canvas zeichnen, Pixel lesen
- Waldkriterium: `g > r+5 && g > b+9 && (r+g+b)/3 < 100`
- Raster über die ganze Bbox, `step = clamp(sqrt(W·D/34000), 9, 42)` m, Jitter,
  Limit 34 000
- zusätzlich Gartenbäume: pro Gebäude ~60 %, 1–2 Stück, 7–19 m Abstand,
  Mindestabstand zum Haus (4 m)
- Geometrie: `ConeGeometry(3.1, 11, 7)`, um 5.5 m nach oben versetzt,
  per-Instanz Farbe (aus Bildpixel + Variation), Skalierung, Rotation
- **ein** `InstancedMesh`, `castShadow`, `frustumCulled = false`

---

## 10. UI

- Karte: Titel-Chip (Eyebrow, Serifentitel, Untertitel), Zoom-Buttons (`+`, `−`, `◻`),
  Hinweis, Attribution
- Scanlines/Textur: feines Rauschen im Boden-Shader, Vignette über `body::after`
- Mobil (≤ 720 px): kleinere Karte, 38-px-Buttons, Hinweis ausgeblendet,
  Attribution zentriert mit `safe-area-inset-bottom`
- `viewport-fit=cover`, `100svh`, `dvh`-Fallback

---

## 11. Performance und Grenzen

| Größe | Demo | Anmerkung |
|---|---|---|
| Draw Calls | ~10 | Gelände, Sockel, Gebäude, LoD2, Straßen, Bäume, 3 Labels |
| Dreiecke | ~270 k | inkl. ~6.9 k Bäume |
| Bäume | 1 Mesh | pro Instanz Farbe/Skalierung |
| Gebäude | 1 Mesh | Vertexfarben, keine Texturen |
| Boden | 190² Segmente | Höhen aus Raster |

- `setPixelRatio(min(dpr, mobil 1.5 / desktop 2))`
- Schatten nur für Gebäude/Bäume; Shadow-Map folgt dem Ziel
- Große Bboxen: Baumdichte sinkt automatisch, Dateigröße über Bodenbild steuern
- `maxZoom 55` ist bewusst großzügig; bei Bedarf auf ~34 senken (Boden wird sonst weich)

---

## 12. Fehlersuche

| Beobachtung | Prüfen |
|---|---|
| schwarze Flächen / Shader-Fehler | three-Version r186? `vMapUv`? `#ifdef USE_MAP`? |
| leere Karte | `meta.json`/`height.json` per HTTP erreichbar? `fetch`-Fehler in Konsole? |
| Gebäude schweben | `off` (LoD2) bzw. Höhenraster/Bbox falsch |
| Doppelte Dächer | `o` in `lod2.js` = `osm_id` in `buildings.js`? `LOD2.suppress` gefüllt? |
| Bäume auf Feldern | Waldmaske/Schwellen im Bodenbild; `step` zu klein |
| Labels falsch skaliert | `sizeAttenuation:true` + Scale-Update pro Frame |
| nichts ändert sich | Cache-Busting (`?v=`) und `setCacheEnabled(false)` |
| Schatten flackern | Shadow-Camera-Größe an Zoom koppeln, `normalBias 0.7` |
| 404 `favicon.ico` | Inline-SVG-Favicon ist gesetzt; sonst ignorierbar |
