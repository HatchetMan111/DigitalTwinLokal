# AGENTS.md – Anleitung für KI-Agenten

Diese Datei ist die verbindliche Arbeitsanweisung, wenn ein Agent das Projekt
übernimmt, um **für ein neues Dorf** eine Karte zu bauen. Lies zuerst diese Datei,
dann bei Bedarf `docs/PIPELINE.md`.

## Auftrag

Ziel ist eine lokal laufende, statische isometrische Karte eines Dorfes/Stadtteils:

- Eingabe: Ortsname (oder Bbox) und optional Datenquellen für Orthofoto, DGM, LoD2
- Ausgabe: `web/` mit `index.html`, `iso.js`, `iso.css` und `web/data/**`, startbar mit
  einem beliebigen Static-Server (Python `http.server` genügt)
- Keine externen Anfragen zur Laufzeit, kein Backend, keine Build-Tools, kein Node

**Nicht** Teil des Auftrags: Rotation/Perspektive, Suche, POIs, Routing, Export,
Personenbezug, Datenbanken, CDN-Abhängigkeiten.

## Pflichtlektüre vor dem ersten Befehl

1. `README.md` – Überblick, Datenquellen, Lizenzen
2. diese Datei – Ablauf, Invarianten, Fallstricke
3. `docs/PIPELINE.md` – Mathematik und Implementierungsdetails, wenn etwas nicht passt

## Harte Invarianten (nicht verhandelbar)

- **HTTP-Auslieferung**: Die App lädt `data/scene/meta.json` und `height.json` per
  `fetch`. `file://` funktioniert nicht.
- **three.js r186** liegt in `web/vendor/three/`. Kein CDN, keine andere Version ohne
  Anpassung der Shader-Injektion (r186 nutzt `vMapUv`).
- **Koordinaten**: `buildings.js`-Ringe sind GeoJSON `[lon, lat]`; `roads.js`/`places.js`
  nutzen `[lat, lon]`. Intern rechnet die App in lokale Meter (Web-Mercator-Tangente,
  `K = cos(mittlere Breite)`), y ist Höhe, `z = -(my(lat) - cy)` (Norden = −z).
- **Höhenraster**: `height.json` ist `{w,s,e,n,size,h}` mit `size+1` Zeilen von Süd
  nach Nord und `size+1` Spalten von West nach Ost; Werte in Metern. Die App interpoliert
  bilinear (`sampleH`).
- **Bodenbild**: `web/data/scene/ground.jpg`, Norden oben, exakt die Bbox, Seiten-
  verhältnis ≈ `(e-w)*cos(lat)/(n-s)`; wird als Textur auf das Gelände gelegt.
- **`meta.json`** bestimmt Titel und Startansicht (`focus.radius` in Metern). Ohne
  `focus` wird die ganze Bbox gezeigt.
- **Dateinamen** sind fix: `buildings.js`, `roads.js`, `places.js`, `lod2.js`,
  `scene/{meta.json,height.json,ground.jpg}`. `lod2.js` darf fehlen; dann Stub anlegen:
  `window.LOD2={b:[]};` (index.html hat zusätzlich einen `onerror`-Fallback).
- **Keine echten Ortsdaten committen**, wenn das Repository öffentlich ist. Die
  mitgelieferte Demo ist synthetisch. Echte Daten bleiben lokal.
- **Attribution** der Quellen in `meta.attribution` (und ggf. sichtbar im HUD) ist
  Pflicht, sobald echte Daten verwendet werden.

## Ablauf für ein neues Dorf

### 0. Vorbereiten

```bash
cp -r iso-village-map mein-dorf && cd mein-dorf
python3 -c "import PIL" || pip install pillow
```

Frage den Nutzer nur, was du wirklich nicht ableiten kannst:

- Ortsname **oder** Bbox (`w,s,e,n` in Lon/Lat)
- gewünschter Radius (Default 1500 m)
- vorhandene Quellen: Orthofoto (XYZ-Template oder Datei), DGM (GeoTIFF oder
  SRTM-Kacheln), LoD2-GML-Verzeichnis
- Titel/Untertitel/Attribution

### 1. OSM laden (Pflicht)

```bash
python3 tools/fetch_osm.py --name "Ortsname" --radius 1600
# oder: --bbox 11.49,48.09,11.54,48.13
```

Erzeugt `web/data/{buildings,roads,places}.js` und `web/data/bbox.json`.
Prüfe die Ausgabe: Gebäude > 0, Straßen > 0, plausibler Radius.

### 2. Gelände + Meta (Pflicht für eine sinnvolle Karte)

```bash
python3 tools/build_scene.py \
  --tiles "https://…/{z}/{x}/{y}.jpg" --z 16 \
  [--srtm-dir /pfad/srtm13 | --dem-geotiff /pfad/dgm.tif] \
  --title "Ortsname" --subtitle "Gemeinde …" --attribution "© …"
```

Ohne `--tiles`/`--ortho-file`: es entsteht kein Bodenbild (einfarbiger Boden).
Ohne Höhenquelle: flaches Gelände. Beides ist zulässig, aber im Ergebnis vermerken.

### 3. Bodenbild malen (optional)

```bash
python3 tools/stylize_ground.py
```

Nur wenn `ortho.jpg` existiert. Parameter (Median/Helligkeit/Farbanzahl) sind Geschmack;
starke Abstraktion ist gewollt (ruhiger Untergrund, lesbare Gebäude).

### 4. LoD2 (optional, großer Qualitätssprung)

```bash
mkdir -p data/lod2 && cp /pfad/*.gml data/lod2/
python3 tools/build_lod2.py
```

Das Skript liest `meta.json` für Bbox und UTM-Zone, projiziert nach WGS84, verankert
Dächer am Höhenraster und schreibt `web/data/lod2.js` (Zuordnung zu OSM-Gebäuden
per Zentroid-Abstand ≤ 11 m). Ausgabe prüfen: `OSM-Zuordnung: n/m`.

Wenn keine LoD2-Daten vorliegen: `echo 'window.LOD2={b:[]};' > web/data/lod2.js`.

### 5. Starten und prüfen

```bash
cd web && python3 -m http.server 8000
```

## Verifikation (Pflicht vor „fertig“)

Ohne Browser-Automation:

- Server liefert `index.html`, `data/scene/meta.json`, `data/buildings.js` mit HTTP 200
- `meta.json` passt zur Bbox; `height.json.size` = 160 oder 192 (wie erzeugt)
- `ground.jpg`-Seitenverhältnis ≈ Bbox-Verhältnis (±2 %)
- `lod2.js` vorhanden (echt oder Stub), `window.LOD2.b` ist ein Array

Mit Headless-Browser (empfohlen, falls verfügbar). Die App exponiert `window.__S`
und `window.SCENE`:

```js
await page.evaluate(() => ({
  ready: __S.ready, zoom: __S.camera.zoom, buildings: __S.count,
  lod2: !!__S.scene.getObjectByName('lod2'), trees: __S.trees && __S.trees.count,
  roads: !!__S.roads, draws: __S.renderer.info.render.calls,
  tris: __S.renderer.info.render.triangles
}));
```

Erwartung: `ready === true`, `buildings > 0`, `trees > 0` (wenn Wald im Bild),
`draws` < 20, keine `pageerror`/`console.error`. Screenshot bei 1440×900 und
390×844 (Touch) ansehen: Gebäude stehen auf dem Boden, Dächer zeigen nach oben,
Labels lesbar, keine schwarzen/flackernden Flächen.

## Fallstricke (aus der Praxis)

- **Overpass**: POST liefert 406/502; **GET mit User-Agent** funktioniert. Mehrere
  Endpunkte durchprobieren (`fetch_osm.py` macht das).
- **Kein Cache**: Beim Testen `page.setCacheEnabled(false)` und `?v=N` an
  `iso.css`/`iso.js` erhöhen; sonst siehst du alte Builds.
- **Ortho-Kamera + Sprites**: `SpriteMaterial({sizeAttenuation:false})` skaliert im
  orthografischen Modus nicht mit der Tiefe. Labels daher mit `sizeAttenuation:true`
  und pro Frame gesetzter Weltgröße (`ls = (2*BASE_H/zoom) * 0.14`).
- **Shader-Injektion**: In r186 heißt das Map-UV-Varying `vMapUv`; Injektionen in
  `map_fragment` mit `#ifdef USE_MAP` absichern, sonst bricht der Shader ohne Textur.
- **Dreiecks-Winding**: Dachflächen müssen `normal.y > 0` haben, Wände nach außen
  zeigen (`dot(horizontale Normale, Flächenzentrum − Gebäudezentrum) > 0`), sonst
  sind Flächen mit `FrontSide` unsichtbar bzw. falsch beleuchtet. Das LoD2-Skript
  korrigiert das je Dreieck.
- **Verankerung**: LoD2-Höhen (DHHN) ≠ DEM-Höhe. Erst den Median der Differenzen
  bestimmen und abziehen (`off`), dann je Vertex `sampleH(x,z)` als Anker nutzen und
  Wandfüße unter 60 cm auf das Gelände ziehen. Sonst schweben/sinken Gebäude.
- **Unterdrückung**: Ein LoD2-Gebäude ersetzt das typisierte OSM-Gebäude über
  `LOD2.suppress` (Menge der OSM-IDs). Ohne das entstehen Doppeldächer.
- **Bäume**: Klassifikation über Bodenbild-Pixel (`g > r+5 && g > b+9 && lum < 100`),
  Dichte adaptiv über die Fläche, ein `InstancedMesh`, `frustumCulled=false`. Keine
  Bäume auf Gebäuden (Gartenbäume mit Mindestabstand).
- **Schatten**: Shadow-Kamera folgt dem Ziel und wird mit dem Zoom verkleinert
  (`clamp(2100/zoom, 220, 1700)`), sonst flackern oder fehlen Schatten.
- **Mobile**: `devicePixelRatio` auf 1.5 begrenzen, HUD-Karte verkleinern, Buttons
  ≥ 38 px, `100svh`/`safe-area-inset-bottom` beachten.
- **Datenmenge**: Große Gebiete nicht in ein Bodenbild > 2000 px pressen; Label- und
  Baumdichte adaptiv halten; Dateien nach dem Build auf Größe prüfen.

## Definition of Done

- [ ] `web/` startet über HTTP, keine 404 für benötigte Dateien
- [ ] `ready:true`, Gebäude/Straßen/Bäume vorhanden, keine Konsolenfehler
- [ ] Desktop- **und** Mobil-Screenshot geprüft
- [ ] Titel/Untertitel/Attribution korrekt in `meta.json`
- [ ] `focus` rahmt den Ort sinnvoll (Ort füllt ca. 1/2 bis 2/3 der Höhe)
- [ ] keine echten Daten/Adressen im öffentlichen Repo; Demo bleibt synthetisch
- [ ] `README.md`-Schnellstart stimmt mit den tatsächlichen Befehlen überein

## Wenn etwas fehlt

| Symptom | Ursache / Fix |
|---|---|
| schwarze Fläche | Shader-Injektion ohne `#ifdef USE_MAP`, three-Version ≠ r186 |
| Karte leer, Konsole ruhig | `meta.json`/`height.json` nicht geladen (file:// oder falscher Pfad) |
| Gebäude schweben | DEM/LoD2-Offset nicht abgezogen oder falsche Bbox |
| Doppelte Dächer | LoD2-Unterdrückung fehlt (`o`-Feld ≠ OSM-ID) |
| Bäume überall | Waldmaske im Bodenbild zu dunkel/zu grün; Schwellen prüfen |
| Labels riesig/winzig | `sizeAttenuation` oder Label-Skalierung pro Frame fehlt |
| nichts sichtbar nach Änderung | Cache: `?v=` erhöhen, `setCacheEnabled(false)` |
