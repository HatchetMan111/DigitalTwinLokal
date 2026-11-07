/* 3D-Ansicht: Three.js-Szene mit Gelände, Luftbild und Gebäuden mit Dachschrägen. */
import * as THREE from 'three';
import { OrbitControls } from './vendor/three/OrbitControls.js';

/* Isometrische Grundparameter: feste Blickrichtung, orthografische Kamera */
const ISO = { az: 0.6124, el: 0.5, dz: 0.6124 };
const BASE_H = 3000;          /* halbe sichtbare Höhe bei zoom = 1 (Weltmeter) */
const MAP_PAD = 420;          /* Pan-Spielraum über den Kartenrand hinaus */

const R = 6378137;
const D2R = Math.PI / 180;
/* lokale Merkator-Projektion, auf Bodenmeter am Bezugsbreitengrad skaliert */
let K = 1; /* cos(Breitengrad), wird aus meta.json gesetzt */
const mx = (lon) => lon * D2R * R * K;
const my = (lat) => R * Math.log(Math.tan(Math.PI / 4 + lat * D2R / 2)) * K;

/* ------------------------- Gebäudetypen ------------------------- */
/* h = Traufhöhe (m), pitch = Dachneigung (Grad) */
const T = {
  church:            { h: 6.6, pitch: 47, wall: '#efe8d8', roof: '#4b5058' },
  chapel:            { h: 4.2, pitch: 42, wall: '#efe8d8', roof: '#5a5350' },
  school:            { h: 5.4, pitch: 30, wall: '#e9e2d2', roof: '#7a4633' },
  kindergarten:      { h: 3.6, pitch: 30, wall: '#e9e2d2', roof: '#7a4633' },
  public:            { h: 4.4, pitch: 30, wall: '#e7e0d1', roof: '#6b4535' },
  civic:             { h: 4.4, pitch: 30, wall: '#e7e0d1', roof: '#6b4535' },
  hotel:             { h: 6.2, pitch: 32, wall: '#efe6d4', roof: '#7d4a36' },
  apartments:        { h: 5.8, pitch: 30, wall: '#efe6d4', roof: '#7d4a36' },
  residential:       { h: 5.2, pitch: 34, wall: '#efe6d4', roof: '#8a4a34' },
  house:             { h: 3.3, pitch: 39, wall: '#f0e6d2', roof: '#8d4a34' },
  yes:               { h: 3.5, pitch: 33, wall: '#ece3d1', roof: '#84492f' },
  farm:              { h: 3.4, pitch: 34, wall: '#e8dcc4', roof: '#7a4a34' },
  farm_auxiliary:    { h: 3.0, pitch: 30, wall: '#ded2b8', roof: '#6d4a35' },
  barn:              { h: 4.3, pitch: 31, wall: '#cdbfa2', roof: '#6a4a3a' },
  stable:            { h: 3.4, pitch: 28, wall: '#dccfb4', roof: '#6d4a35' },
  warehouse:         { h: 5.0, pitch: 16, wall: '#ddd8cd', roof: '#5d5a55' },
  industrial:        { h: 5.6, pitch: 14, wall: '#d6d3ca', roof: '#55524e' },
  commercial:        { h: 4.2, pitch: 18, wall: '#e2ddd2', roof: '#5d5a55' },
  retail:            { h: 4.0, pitch: 16, wall: '#e2ddd2', roof: '#5d5a55' },
  service:           { h: 3.8, pitch: 20, wall: '#ded9ce', roof: '#605c56' },
  fire_station:      { h: 4.4, pitch: 20, wall: '#e6ded0', roof: '#8a4a34' },
  garage:            { h: 2.4, pitch: 14, wall: '#e3dccc', roof: '#5c5a56' },
  garages:           { h: 2.5, pitch: 14, wall: '#e3dccc', roof: '#5c5a56' },
  shed:              { h: 2.3, pitch: 18, wall: '#d8cdb4', roof: '#5f4c3d' },
  hut:               { h: 2.3, pitch: 22, wall: '#d8cdb4', roof: '#5f4c3d' },
  roof:              { h: 2.6, pitch: 12, wall: '#d8cdb4', roof: '#5f4c3d' },
  carport:           { h: 2.4, pitch: 10, wall: '#d8cdb4', roof: '#5f4c3d' },
  greenhouse:        { h: 2.6, pitch: 26, wall: '#cfe0d8', roof: '#bcd3c9' },
  silo:              { h: 9.0, pitch: 0, flat: 1, wall: '#c9c4b8', roof: '#8f8a7d' },
  water_tower:       { h: 14, pitch: 0, flat: 1, wall: '#cfc9bc', roof: '#8f8a7d' },
  transformer_tower: { h: 3.0, pitch: 8, wall: '#cfc9bc', roof: '#5c5a56' }
};

function typeOf(p) {
  const t = T[p.building];
  if (t) return t;
  const a = p.area_m2 || 0;
  if (a > 500) return T.barn;
  if (a > 200) return T.house;
  return T.shed;
}

const ROOF_MIX = [
  ['#8b4a33', 34], ['#7d4230', 16], ['#8f8a82', 14], ['#7b776f', 12],
  ['#6b4b3a', 12], ['#8f5138', 8], ['#6e7176', 4]
];
function mixRoofColor(base, p, vars) {
  const keep = { church: 1, chapel: 1, industrial: 1, warehouse: 1, commercial: 1, retail: 1, service: 1, silo: 1, water_tower: 1, greenhouse: 1 };
  if (keep[p.building]) return new THREE.Color(base);
  let h = (hashStr(String(p.osm_id)) % 100);
  let pick = ROOF_MIX[0][0];
  for (const [c, w] of ROOF_MIX) { if (h < w) { pick = c; break; } h -= w; }
  return new THREE.Color(pick);
}

function hashStr(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = (h * 16777619) >>> 0; }
  return h;
}

function heightOf(p) {
  const t = typeOf(p);
  if (t.flat) return t.h;
  const wid = Math.min(p.width_m || 8, p.depth_m || 8);
  return t.h + Math.min(6.2, Math.max(0.7, Math.tan(t.pitch * D2R) * wid / 2));
}

/* ------------------------------ Zustand ------------------------------ */
const S = {
  ready: false, failed: false, visibleOn: false,
  container: null, renderer: null, scene: null, camera: null, controls: null,
  ground: null, bld: null,
  grid: null, bbox: null,
  owners: [], ranges: {}, colorAttr: null,
  features: [], visible: [], count: 0,
  light: null, anim: null
};

const WORLD = { w: 0, d: 0, cx: 0, cy: 0 };
const PLACES = {};

function toScene(lon, lat) {
  return { x: mx(lon) - WORLD.cx, z: -(my(lat) - WORLD.cy) };
}

function sampleH(x, z) {
  const g = S.grid;
  const u = Math.min(Math.max(x / WORLD.w + 0.5, 0), 1);
  const v = Math.min(Math.max(1 - (z / WORLD.d + 0.5), 0), 1);
  const gi = u * g.size, gj = v * g.size;
  const i = Math.min(Math.floor(gi), g.size - 1);
  const j = Math.min(Math.floor(gj), g.size - 1);
  const fx = gi - i, fj = gj - j;
  const a = g.h[j][i] * (1 - fx) + g.h[j][i + 1] * fx;
  const b = g.h[j + 1][i] * (1 - fx) + g.h[j + 1][i + 1] * fx;
  return a * (1 - fj) + b * fj;
}

/* ------------------------------ Gelände ------------------------------ */
function addGroundDetail(mat) {
  const N = 256;
  const cv = document.createElement('canvas');
  cv.width = cv.height = N;
  const g = cv.getContext('2d');
  const small = document.createElement('canvas');
  small.width = small.height = 48;
  const sg = small.getContext('2d');
  const id = sg.createImageData(48, 48);
  for (let i = 0; i < id.data.length; i += 4) {
    const v = 150 + Math.random() * 90;
    id.data[i] = id.data[i + 1] = id.data[i + 2] = v;
    id.data[i + 3] = 255;
  }
  sg.putImageData(id, 0, 0);
  g.imageSmoothingEnabled = true;
  g.drawImage(small, 0, 0, N, N);
  const tex = new THREE.CanvasTexture(cv);
  tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
  tex.colorSpace = THREE.NoColorSpace;
  mat.onBeforeCompile = (sh) => {
    sh.uniforms.uDetail = { value: tex };
    sh.fragmentShader = 'uniform sampler2D uDetail;\n' + sh.fragmentShader.replace(
      '#include <map_fragment>',
      '#include <map_fragment>\n' +
      '#ifdef USE_MAP\n' +
      '  float dtl = texture2D(uDetail, vMapUv * 220.0).r;\n' +
      '  diffuseColor.rgb *= mix(1.0, 0.58 + dtl * 0.86, 0.30);\n' +
      '#endif'
    );
  };
  mat.needsUpdate = true;
}



/* ------------------------------- Straßen ------------------------------ */
const ROAD_W = {
  motorway: 10, trunk: 9, primary: 9, secondary: 8, tertiary: 7, unclassified: 6,
  residential: 6, living_street: 5, service: 4, track: 3.2, path: 1.6, footway: 1.6,
  cycleway: 1.8, bridleway: 2, steps: 2.4, road: 4
};
const ROAD_C = {
  motorway: '#e7dbbd', trunk: '#e7dbbd', primary: '#e9dfc4', secondary: '#ece2c9',
  tertiary: '#eee5cf', unclassified: '#efe6d2', residential: '#f1e8d5', living_street: '#f1e8d6',
  service: '#e9dfc9', track: '#d8c9a6', path: '#cdbf9c', footway: '#cdbf9c', cycleway: '#d2c5a3',
  bridleway: '#d2c5a3', steps: '#d8ccb0', road: '#eee5cf'
};

function buildRoads() {
  const roads = window.ROADS || [];
  if (!roads.length) return;
  const P = [], C = [];
  const casing = new THREE.Color('#b3a17d');
  const tmp = new THREE.Color();

  const quad = (ax, az, bx, bz, w, off, color) => {
    const dx = bx - ax, dz = bz - az;
    const len = Math.hypot(dx, dz);
    if (len < 0.3) return;
    const nx = -dz / len * w / 2, nz = dx / len * w / 2;
    const y1 = sampleH(ax, az) + off, y2 = sampleH(bx, bz) + off;
    const v = [
      [ax + nx, y1, az + nz], [ax - nx, y1, az - nz], [bx + nx, y2, bz + nz],
      [ax - nx, y1, az - nz], [bx - nx, y2, bz - nz], [bx + nx, y2, bz + nz]
    ];
    for (const [x, y, z] of v) {
      P.push(x, y, z);
      C.push(color.r, color.g, color.b);
    }
  };

  for (const rd of roads) {
    const w = ROAD_W[rd.t] || 3;
    tmp.set(ROAD_C[rd.t] || ROAD_C.road);
    for (let i = 1; i < rd.p.length; i++) {
      const a = rd.p[i - 1], b = rd.p[i];
      const pa = toScene(a[1], a[0]), pb = toScene(b[1], b[0]);
      quad(pa.x, pa.z, pb.x, pb.z, w + 2.4, 0.20, casing);
      quad(pa.x, pa.z, pb.x, pb.z, w, 0.32, tmp);
    }
  }
  if (!P.length) return;
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(P, 3));
  g.setAttribute('color', new THREE.Float32BufferAttribute(C, 3));
  g.computeVertexNormals();
  const m = new THREE.MeshLambertMaterial({
    vertexColors: true, side: THREE.DoubleSide,
    polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -2
  });
  const mesh = new THREE.Mesh(g, m);
  mesh.receiveShadow = true;
  mesh.frustumCulled = false;
  S.scene.add(mesh);
  S.roads = mesh;
}

/* ------------------------------- Bäume ------------------------------- */
let treesBuilt = false;
function buildTrees() {
  if (treesBuilt) return;
  treesBuilt = true;
  const meta = window.__SCENE_META;
  const img = new Image();
  img.onload = () => {
    const cv = document.createElement('canvas');
    cv.width = img.width; cv.height = img.height;
    const ctx = cv.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(img, 0, 0);
    let px;
    try { px = ctx.getImageData(0, 0, cv.width, cv.height).data; } catch (e) { return; }

    const hash = new Map();
    const cell = 60;
    const key = (x, z) => Math.floor(x / cell) + ':' + Math.floor(z / cell);
    for (const f of S.features) {
      const ring = f.geometry.coordinates[0];
      let mnx = Infinity, mxx = -Infinity, mnz = Infinity, mxz = -Infinity;
      for (const c of ring) {
        const p = toScene(c[0], c[1]);
        mnx = Math.min(mnx, p.x); mxx = Math.max(mxx, p.x);
        mnz = Math.min(mnz, p.z); mxz = Math.max(mxz, p.z);
      }
      for (let gx = Math.floor((mnx - 8) / cell); gx <= Math.floor((mxx + 8) / cell); gx++)
        for (let gz = Math.floor((mnz - 8) / cell); gz <= Math.floor((mxz + 8) / cell); gz++) {
          const k = gx + ':' + gz;
          if (!hash.has(k)) hash.set(k, []);
          hash.get(k).push([mnx - 8, mxx + 8, mnz - 8, mxz + 8]);
        }
    }
    const nearBuilding = (x, z) => {
      const arr = hash.get(key(x, z));
      if (!arr) return false;
      for (const b of arr) if (x >= b[0] && x <= b[1] && z >= b[2] && z <= b[3]) return true;
      return false;
    };

    const pos = [], col = [], scl = [];
    const base = [new THREE.Color('#4c6a3f'), new THREE.Color('#587549'), new THREE.Color('#435e37')];
    const step = Math.min(42, Math.max(9, Math.sqrt((WORLD.w * WORLD.d) / 34000)));
    let n = 0;
    for (let x = -WORLD.w / 2 + 12; x < WORLD.w / 2 - 12; x += step) {
      for (let z = -WORLD.d / 2 + 12; z < WORLD.d / 2 - 12; z += step) {
        if (n >= 34000) break;
        const jx = x + (Math.random() - 0.5) * step * 0.9;
        const jz = z + (Math.random() - 0.5) * step * 0.9;
        const u = jx / WORLD.w + 0.5, v = 1 - (jz / WORLD.d + 0.5);
        if (u < 0 || u > 1 || v < 0 || v > 1) continue;
        const o = ((Math.min(cv.height - 1, Math.floor(v * cv.height)) * cv.width) + Math.min(cv.width - 1, Math.floor(u * cv.width))) * 4;
        const r = px[o], g = px[o + 1], b = px[o + 2];
        const lum = 0.3 * r + 0.59 * g + 0.11 * b;
        if (!(g > r + 5 && g > b + 9 && lum < 100)) continue;
        if (nearBuilding(jx, jz)) continue;
        const s = 0.62 + Math.random() * 0.85;
        pos.push(jx, sampleH(jx, jz) - 0.4, jz);
        const c = base[(Math.random() * base.length) | 0];
        const f = 0.86 + Math.random() * 0.3;
        col.push(c.r * f, c.g * f, c.b * f);
        scl.push(s);
        n++;
      }
    }
    /* Gartengehölze an den Häusern */
    const small = new Map();
    const mcell = 40;
    const nk = (x, z) => Math.floor(x / mcell) + ':' + Math.floor(z / mcell);
    for (const f of S.features) {
      const ring = f.geometry.coordinates[0];
      let mnx = Infinity, mxx = -Infinity, mnz = Infinity, mxz = -Infinity;
      for (const c of ring) {
        const p = toScene(c[0], c[1]);
        mnx = Math.min(mnx, p.x); mxx = Math.max(mxx, p.x);
        mnz = Math.min(mnz, p.z); mxz = Math.max(mxz, p.z);
      }
      for (let gx = Math.floor((mnx - 4) / mcell); gx <= Math.floor((mxx + 4) / mcell); gx++)
        for (let gz = Math.floor((mnz - 4) / mcell); gz <= Math.floor((mxz + 4) / mcell); gz++) {
          const k = gx + ':' + gz;
          if (!small.has(k)) small.set(k, []);
          small.get(k).push([mnx - 4, mxx + 4, mnz - 4, mxz + 4]);
        }
    }
    const hitsHouse = (x, z) => {
      const arr = small.get(nk(x, z));
      if (!arr) return false;
      for (const b of arr) if (x >= b[0] && x <= b[1] && z >= b[2] && z <= b[3]) return true;
      return false;
    };
    const gc = [new THREE.Color('#56743f'), new THREE.Color('#617f47'), new THREE.Color('#4a6738')];
    for (const f of S.features) {
      if (Math.random() > 0.6) continue;
      const ring = f.geometry.coordinates[0];
      const c0 = ring[0];
      const ctr = toScene(c0[0], c0[1]);
      const cnt = 1 + (Math.random() < 0.35 ? 1 : 0);
      for (let i = 0; i < cnt; i++) {
        const ang = Math.random() * Math.PI * 2;
        const rad = 7 + Math.random() * 12;
        const x = ctr.x + Math.cos(ang) * rad, z = ctr.z + Math.sin(ang) * rad;
        if (hitsHouse(x, z)) continue;
        const s2 = 0.42 + Math.random() * 0.35;
        pos.push(x, sampleH(x, z) - 0.3, z);
        const col2 = gc[(Math.random() * gc.length) | 0];
        const f2 = 0.9 + Math.random() * 0.25;
        col.push(col2.r * f2, col2.g * f2, col2.b * f2);
        scl.push(s2);
        n++;
      }
    }
    if (!n) return;
    const geo = new THREE.ConeGeometry(3.1, 11, 7, 1);
    geo.translate(0, 5.5, 0);
    const mat = new THREE.MeshLambertMaterial({ color: 0xffffff });
    const mesh = new THREE.InstancedMesh(geo, mat, n);
    const m4 = new THREE.Matrix4(), q = new THREE.Quaternion(), sc = new THREE.Vector3(), pv = new THREE.Vector3();
    for (let i = 0; i < n; i++) {
      q.setFromAxisAngle(new THREE.Vector3(0, 1, 0), Math.random() * Math.PI * 2);
      pv.set(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]);
      sc.set(scl[i], scl[i] * (0.85 + Math.random() * 0.5), scl[i]);
      m4.compose(pv, q, sc);
      mesh.setMatrixAt(i, m4);
      mesh.setColorAt(i, new THREE.Color(col[i * 3], col[i * 3 + 1], col[i * 3 + 2]));
    }
    mesh.instanceMatrix.needsUpdate = true;
    if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true;
    mesh.castShadow = true;
    mesh.receiveShadow = false;
    mesh.frustumCulled = false;
    S.scene.add(mesh);
    S.trees = mesh;
  };
  img.src = 'data/scene/ground.jpg';
}

function buildGround() {
  const seg = 190;
  const geo = new THREE.PlaneGeometry(WORLD.w, WORLD.d, seg, seg);
  geo.rotateX(-Math.PI / 2);
  const pos = geo.attributes.position;
  for (let i = 0; i < pos.count; i++) pos.setY(i, sampleH(pos.getX(i), pos.getZ(i)));
  geo.computeVertexNormals();
  const mat = new THREE.MeshLambertMaterial({ color: 0xfffaf0 });
  addGroundDetail(mat);
  const mesh = new THREE.Mesh(geo, mat);
  mesh.receiveShadow = true;
  S.scene.add(mesh);
  S.ground = mesh;

  let minY = Infinity;
  for (let i = 0; i < pos.count; i++) if (pos.getY(i) < minY) minY = pos.getY(i);
  const base = new THREE.Mesh(
    new THREE.BoxGeometry(WORLD.w + 60, 140, WORLD.d + 60),
    new THREE.MeshLambertMaterial({ color: 0xcfc2a6 })
  );
  base.position.set(0, minY - 70, 0);
  base.receiveShadow = true;
  S.scene.add(base);

  new THREE.TextureLoader().load('data/scene/ground.jpg', (tex) => {
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.anisotropy = S.renderer.capabilities.getMaxAnisotropy();
    mat.map = tex;
    mat.needsUpdate = true;
  }, undefined, () => { mat.color.set(0x8f9a74); });
}

function polyArea(pts) {
  let a = 0;
  for (let i = 0; i < pts.length; i++) {
    const j = (i + 1) % pts.length;
    a += pts[i][0] * pts[j][1] - pts[j][0] * pts[i][1];
  }
  return a / 2;
}

/* Polygon um d nach innen versetzen (Miter), null wenn es kollabiert. */
function offsetInward(pts, d) {
  const A = polyArea(pts), n = pts.length;
  if (Math.abs(A) < 1) return null;
  for (const s of [Math.sign(A), -Math.sign(A)]) {
    const out = [];
    for (let i = 0; i < n; i++) {
      const p0 = pts[(i + n - 1) % n], p1 = pts[i], p2 = pts[(i + 1) % n];
      const e1x = p1[0] - p0[0], e1z = p1[1] - p0[1];
      const e2x = p2[0] - p1[0], e2z = p2[1] - p1[1];
      const l1 = Math.hypot(e1x, e1z) || 1e-6, l2 = Math.hypot(e2x, e2z) || 1e-6;
      const n1x = -e1z / l1 * s, n1z = e1x / l1 * s;
      const n2x = -e2z / l2 * s, n2z = e2x / l2 * s;
      let mx = n1x + n2x, mz = n1z + n2z;
      const ml = Math.hypot(mx, mz);
      if (ml < 1e-6) { mx = n1x; mz = n1z; } else { mx /= ml; mz /= ml; }
      const c = Math.max(0.4, mx * n1x + mz * n1z);
      out.push([p1[0] + mx * d / c, p1[1] + mz * d / c]);
    }
    if (Math.abs(polyArea(out)) < Math.abs(A)) return out;
  }
  return null;
}

/* --------------------------- Geometrie ----------------------------- */
function pushTri(P, C, a, b, c, col, up, ox, oz) {
  let ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2];
  let vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
  const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
  let flip = false;
  if (up === 1) flip = ny < 0;
  else if (up === -1) flip = ny > 0;
  else if (ox != null) flip = nx * ox + nz * oz < 0;
  if (flip) { const t = b; b = c; c = t; }
  P.push(a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2]);
  for (let k = 0; k < 3; k++) C.push(col.r, col.g, col.b);
}

function pushWall(P, C, a, b, col, h, ox, oz) {
  let ax = a[0], az = a[1], bx = b[0], bz = b[1];
  const ay = a[2], by = b[2];
  if (-(bz - az) * ox + (bx - ax) * oz < 0) {
    let t = ax; ax = bx; bx = t;
    t = az; az = bz; bz = t;
  }
  P.push(ax, ay, az, bx, ay, bz, bx, ay + h, bz);
  P.push(ax, ay, az, bx, ay + h, bz, ax, ay + h, az);
  for (let k = 0; k < 6; k++) C.push(col.r, col.g, col.b);
}

function addBuilding(f, P, C) {
  const p = f.properties;
  const t = typeOf(p);
  const vars = (hashStr(String(p.osm_id)) % 1000) / 1000;
  const wallC = new THREE.Color(t.wall).offsetHSL(0, 0, (vars - 0.5) * 0.05);
  const rc = mixRoofColor(t.roof, p, vars);
  const roofC = rc.offsetHSL(0, 0, (vars - 0.5) * 0.06);

  const ring = f.geometry.coordinates[0];
  const pts = [];
  for (let i = 0; i < ring.length; i++) {
    const sc = toScene(ring[i][0], ring[i][1]);
    const last = pts[pts.length - 1];
    if (last && Math.abs(last[0] - sc.x) < 0.05 && Math.abs(last[1] - sc.z) < 0.05) continue;
    pts.push([sc.x, sc.z]);
  }
  if (pts.length > 2) {
    const f0 = pts[0], fl = pts[pts.length - 1];
    if (Math.abs(f0[0] - fl[0]) < 0.05 && Math.abs(f0[1] - fl[1]) < 0.05) pts.pop();
  }
  if (pts.length < 3) return 0;

  const base = (p.e0 != null ? p.e0 : sampleH(pts[0][0], pts[0][1])) - 1.2;
  const eave = base + 1.2 + t.h;
  let cx = 0, cz = 0;
  for (let i = 0; i < pts.length; i++) { cx += pts[i][0]; cz += pts[i][1]; }
  cx /= pts.length; cz /= pts.length;

  /* Wände */
  for (let i = 0; i < pts.length; i++) {
    const a = pts[i], b = pts[(i + 1) % pts.length];
    if (Math.abs(a[0] - b[0]) < 0.02 && Math.abs(a[1] - b[1]) < 0.02) continue;
    const ex = (a[0] + b[0]) / 2 - cx, ez = (a[1] + b[1]) / 2 - cz;
    pushWall(P, C, [a[0], a[1], base], [b[0], b[1], base], wallC, eave - base, ex, ez);
  }

  /* Hauptachse über PCA */
  let sxx = 0, szz = 0, sxz = 0;
  for (let i = 0; i < pts.length; i++) {
    const dx = pts[i][0] - cx, dz = pts[i][1] - cz;
    sxx += dx * dx; szz += dz * dz; sxz += dx * dz;
  }
  const th = 0.5 * Math.atan2(2 * sxz, sxx - szz);
  const ux = Math.cos(th), uz = Math.sin(th);
  let u0 = 1e9, u1 = -1e9, v0 = 1e9, v1 = -1e9;
  for (let i = 0; i < pts.length; i++) {
    const du = (pts[i][0] - cx) * ux + (pts[i][1] - cz) * uz;
    const dv = -(pts[i][0] - cx) * uz + (pts[i][1] - cz) * ux;
    if (du < u0) u0 = du; if (du > u1) u1 = du;
    if (dv < v0) v0 = dv; if (dv > v1) v1 = dv;
  }
  const len = Math.max(u1 - u0, 1.2);
  const wid = Math.max(v1 - v0, 1.2);
  const at = (u, v, y) => [cx + ux * u - uz * v, y, cz + uz * u + ux * v];

  if (t.flat) {
    const pts2 = pts.map((q) => new THREE.Vector2(q[0], q[1]));
    const faces = THREE.ShapeUtils.triangulateShape(pts2, []);
    for (const q of faces) {
      pushTri(P, C, [pts[q[0]][0], eave, pts[q[0]][1]],
                    [pts[q[1]][0], eave, pts[q[1]][1]],
                    [pts[q[2]][0], eave, pts[q[2]][1]], roofC, 1);
    }
    return P.length / 3;
  }

  /* Dach */
  const tanP = Math.tan(t.pitch * D2R);
  let rh = Math.min(6.2, Math.max(0.7, tanP * (wid / 2)));
  const ridge = eave + rh;
  const ov = 0.45;

  /* Passt die Grundfläche gut auf die OBB? Sonst geneigtes Zeltdach über Innenversatz. */
  const cov = Math.abs(polyArea(pts)) / (len * wid || 1);
  if (cov < 0.82) {
    const d = Math.min(rh / tanP, 0.42 * Math.min(len, wid));
    const Q = offsetInward(pts, d);
    if (Q) {
      const top = eave + d * tanP;
      for (let i = 0; i < pts.length; i++) {
        const j = (i + 1) % pts.length;
        pushTri(P, C, [pts[i][0], eave, pts[i][1]], [pts[j][0], eave, pts[j][1]],
                      [Q[j][0], top, Q[j][1]], roofC, 1);
        pushTri(P, C, [pts[i][0], eave, pts[i][1]], [Q[j][0], top, Q[j][1]],
                      [Q[i][0], top, Q[i][1]], roofC, 1);
      }
      const q2 = Q.map((q) => new THREE.Vector2(q[0], q[1]));
      for (const f of THREE.ShapeUtils.triangulateShape(q2, [])) {
        pushTri(P, C, [Q[f[0]][0], top, Q[f[0]][1]], [Q[f[1]][0], top, Q[f[1]][1]],
                      [Q[f[2]][0], top, Q[f[2]][1]], roofC, 1);
      }
      return P.length / 3;
    }
  }

  const hip = wid > 3.4 && len / wid < 1.45;
  let L = len - (hip ? wid : 0);
  if (L < 0.9) L = hip ? Math.min(len, Math.max(1, len * 0.4)) : len;

  const pA = at(u0, v0 - ov, eave), pB = at(u1, v0 - ov, eave);
  const pC = at(u1, v1 + ov, eave), pD = at(u0, v1 + ov, eave);
  const r1 = at(-L / 2, 0, ridge), r2 = at(L / 2, 0, ridge);

  pushTri(P, C, pA, pB, r2, roofC, 1);
  pushTri(P, C, pA, r2, r1, roofC, 1);
  pushTri(P, C, pC, pD, r1, roofC, 1);
  pushTri(P, C, pC, r1, r2, roofC, 1);

  if (hip) {
    pushTri(P, C, pB, pC, r2, roofC, 1);
    pushTri(P, C, pD, pA, r1, roofC, 1);
  } else {
    const gA = at(u0, v0, eave), gB = at(u0, v1, eave), gr = at(-len / 2, 0, ridge);
    pushTri(P, C, gA, gB, gr, wallC, 0, -ux, -uz);
    const hA = at(u1, v0, eave), hB = at(u1, v1, eave), hr = at(len / 2, 0, ridge);
    pushTri(P, C, hA, hB, hr, wallC, 0, ux, uz);
  }
  return P.length / 3;
}

/* ---------------------------- LoD2-Gebäude ---------------------------- */
const LOD2 = { mesh: null, owners: [], ranges: {}, suppress: new Set(), ok: false };

function buildLod2(visibleSet) {
  const L = window.LOD2;
  if (!L || !L.b || !L.b.length) return;
  const props = new Map();
  for (const f of S.features || []) props.set(String(f.properties.osm_id), f.properties);
  const P = [], C = [];
  const ranges = {};
  LOD2.owners = [];
  for (const b of L.b) {
    const oid = b.o ? String(b.o) : '';
    const p = oid ? props.get(oid) : null;
    if (oid && visibleSet && !visibleSet.has(oid)) continue;
    const t = p ? typeOf(p) : null;
    const vars = (hashStr(String(b.i)) % 1000) / 1000;
    const steep = mixRoofColor(t ? t.roof : '#8a4a37', p || { osm_id: b.i }, vars)
      .offsetHSL(0, 0, (vars - 0.5) * 0.06);
    const flat = new THREE.Color(['#8b8b85', '#7c7c76', '#96938b'][hashStr(String(b.i)) % 3])
      .offsetHSL(0, 0, (vars - 0.5) * 0.04);
    const wc = new THREE.Color(t ? t.wall : '#e7dfcd').offsetHSL(0, 0, (vars - 0.5) * 0.05);
    const start = P.length / 3;
    const q = b.p;
    /* Auf das Gelände setzen: die SRTM-Kachel ist Bezug, nicht die DHHN-Höhe */
    const anchorY = sampleH(b.x, b.z) - 0.05;
    let ti = 0;
    for (let i = 0; i < q.length; i += 9) {
      const isWall = b.k[ti++] !== 'r';
      let col = wc;
      if (!isWall) {
        const ax0 = q[i + 3] - q[i], ay0 = q[i + 4] - q[i + 1], az0 = q[i + 5] - q[i + 2];
        const bx0 = q[i + 6] - q[i], by0 = q[i + 7] - q[i + 1], bz0 = q[i + 8] - q[i + 2];
        const nx0 = ay0 * bz0 - az0 * by0, ny0 = az0 * bx0 - ax0 * bz0, nz0 = ax0 * by0 - ay0 * bx0;
        const nl = Math.hypot(nx0, ny0, nz0) || 1;
        col = Math.abs(ny0) / nl > 0.955 ? flat : steep;
      }
      for (let k = 0; k < 9; k += 3) {
        const ax = b.x + q[i + k] / 100;
        let ay = anchorY + q[i + k + 1] / 100;
        const az = b.z + q[i + k + 2] / 100;
        /* Wandfuß bis auf das Gelände ziehen, damit nichts schwebt */
        if (isWall && q[i + k + 1] < 60) ay = Math.min(ay, sampleH(ax, az) - 0.15);
        P.push(ax, ay, az);
        C.push(col.r, col.g, col.b);
      }
      LOD2.owners.push(oid || null);
    }
    const n = P.length / 3 - start;
    if (!n) continue;
    if (oid) ranges[oid] = [start, n, new Float32Array(C.slice(start * 3, (start + n) * 3))];
  }
  LOD2.ranges = ranges;

  if (LOD2.mesh) {
    LOD2.mesh.geometry.dispose();
    S.scene.remove(LOD2.mesh);
  }
  if (!LOD2.owners.length) { LOD2.mesh = null; LOD2.ok = false; return; }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(P, 3));
  g.setAttribute('color', new THREE.Float32BufferAttribute(new Float32Array(C), 3));
  g.computeVertexNormals();
  g.computeBoundingSphere();
  LOD2.mesh = new THREE.Mesh(g, new THREE.MeshLambertMaterial({ vertexColors: true, side: THREE.DoubleSide }));
  LOD2.mesh.castShadow = true;
  LOD2.mesh.receiveShadow = true;
  LOD2.mesh.frustumCulled = false;
  LOD2.mesh.name = 'lod2';
  S.scene.add(LOD2.mesh);
  LOD2.ok = true;
}

/* --------------------------- Aufbau Mesh --------------------------- */
function rebuild() {
  if (!S.ready) return;
  const P = [], C = [];
  S.owners = [];
  S.ranges = {};

  const vis = new Set(S.visible.map((f) => String(f.properties.osm_id)));
  buildLod2(vis);
  const suppress = LOD2.ok ? LOD2.suppress : null;

  for (const f of S.visible) {
    if (suppress && suppress.has(String(f.properties.osm_id))) continue;
    const start = P.length / 3;
    addBuilding(f, P, C);
    const n = P.length / 3 - start;
    if (!n) continue;
    const key = String(f.properties.osm_id);
    S.ranges[key] = [start, n, new Float32Array(C.slice(start * 3, (start + n) * 3))];
    for (let t = 0; t < n / 3; t++) S.owners.push(key);
  }
  S.count = S.visible.length;

  if (S.bld) {
    S.bld.geometry.dispose();
    S.scene.remove(S.bld);
    S.bld = null;
  }
  S.colorAttr = null;
  if (!P.length) { S.count = S.visible.length; return; }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(P, 3));
  g.setAttribute('color', new THREE.Float32BufferAttribute(new Float32Array(C), 3));
  g.computeVertexNormals();
  g.computeBoundingSphere();
  S.bld = new THREE.Mesh(g, new THREE.MeshLambertMaterial({ vertexColors: true }));
  S.bld.castShadow = true;
  S.bld.receiveShadow = true;
  S.bld.frustumCulled = false;
  S.scene.add(S.bld);
  S.colorAttr = g.attributes.color;

}

/* ------------------------------ Kamera ------------------------------ */
const clampZoom = (z) => Math.max(S.controls.minZoom, Math.min(S.controls.maxZoom, z));

function zoomBy(f) {
  if (!S.ready) return;
  S.camera.zoom = clampZoom(S.camera.zoom * f);
  S.camera.updateProjectionMatrix();
}

function animateTo(target, zoom) {
  const ctl = S.controls, cam = S.camera;
  const t0 = performance.now(), dur = 650;
  const fromT = ctl.target.clone(), fromZ = cam.zoom;
  const toT = target.clone(), toZ = clampZoom(zoom);
  if (S.anim) cancelAnimationFrame(S.anim);
  const step = () => {
    const k = Math.min(1, (performance.now() - t0) / dur);
    const e = k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2;
    const tt = fromT.clone().lerp(toT, e);
    const dx = tt.x - ctl.target.x, dz = tt.z - ctl.target.z;
    ctl.target.copy(tt);
    cam.position.x += dx; cam.position.z += dz;
    cam.zoom = fromZ + (toZ - fromZ) * e;
    cam.updateProjectionMatrix();
    ctl.update();
    if (k < 1) S.anim = requestAnimationFrame(step); else S.anim = null;
  };
  step();
}

function reset() {
  updateViewOffset();
  const meta = window.__SCENE_META || {};
  let cx, cz, hw, hd;
  if (meta.focus && meta.focus.lat != null) {
    const c = toScene(meta.focus.lon, meta.focus.lat);
    cx = c.x; cz = c.z;
    hw = hd = meta.focus.radius || 700;
  } else {
    cx = 0; cz = 0;
    hw = WORLD.w / 2; hd = WORLD.d / 2;
  }
  const asp = S.effAsp || 1;
  const zoom = Math.min(BASE_H * asp / (hw * 1.35), BASE_H / (hd * 1.35));
  animateTo(new THREE.Vector3(cx, sampleH(cx, cz), cz), zoom);
}

function updateViewOffset() {
  const w = S.container.clientWidth, h = S.container.clientHeight;
  if (!w || !h) return;
  const asp = w / h;
  const cam = S.camera;
  cam.left = -BASE_H * asp;
  cam.right = BASE_H * asp;
  cam.top = BASE_H;
  cam.bottom = -BASE_H;
  cam.updateProjectionMatrix();
  S.effAsp = asp;
}

/* ------------------------------ Labels ------------------------------ */
function makeLabels(places) {
  (places || []).forEach((pl) => {
    if (!pl || !pl.lat || !pl.lon) return;
    const cv = document.createElement('canvas');
    cv.width = 1024; cv.height = 256;
    const g = cv.getContext('2d');
    g.font = '600 124px "Iowan Old Style", Georgia, serif';
    try { g.letterSpacing = '5px'; } catch (e) {}
    g.textAlign = 'center'; g.textBaseline = 'middle';
    g.lineWidth = 14; g.strokeStyle = 'rgba(255,252,244,0.78)'; g.lineJoin = 'round';
    g.strokeText(pl.name, 512, 132);
    g.fillStyle = '#241f18';
    g.fillText(pl.name, 512, 132);
    const tex = new THREE.CanvasTexture(cv);
    tex.colorSpace = THREE.SRGBColorSpace;
    tex.anisotropy = 4;
    tex.generateMipmaps = false;
    tex.minFilter = THREE.LinearFilter;
    const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, depthTest: false, transparent: true, sizeAttenuation: true }));
    const c = toScene(pl.lon, pl.lat);
    sp.position.set(c.x, sampleH(c.x, c.z) + 30, c.z);
    sp.renderOrder = 10;
    sp.userData.big = pl.kind === 'village' ? 1.15 : (pl.kind === 'hamlet' ? 0.92 : 0.8);
    (S.labels = S.labels || []).push(sp);
    S.scene.add(sp);
  });
}

/* ------------------------------- Init ------------------------------- */
function init(container) {
  if (S.ready || S.failed) return S.ready;
  try {
    const meta = window.__SCENE_META, grid = window.__SCENE_HEIGHT, data = window.BUILDINGS.features;
    K = Math.cos(((meta.s + meta.n) / 2) * D2R);
    S.features = data;

    WORLD.w = mx(meta.e) - mx(meta.w);
    WORLD.d = my(meta.n) - my(meta.s);
    WORLD.cx = (mx(meta.w) + mx(meta.e)) / 2;
    WORLD.cy = (my(meta.s) + my(meta.n)) / 2;
    S.bbox = meta;
    S.grid = grid;

    const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
    const small = window.innerWidth < 880;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, small ? 1.5 : 2));
    renderer.setSize(container.clientWidth || 800, container.clientHeight || 600);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.0;
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    container.appendChild(renderer.domElement);
    S.renderer = renderer;

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0xeee7d7);
    S.scene = scene;

    const cam = new THREE.OrthographicCamera(-1, 1, 1, -1, 1, 60000);
    S.camera = cam;

    const c0 = toScene((meta.w + meta.e) / 2, (meta.s + meta.n) / 2);
    const ctl = new OrbitControls(cam, renderer.domElement);
    ctl.enableDamping = true;
    ctl.dampingFactor = 0.10;
    ctl.enableRotate = false;
    ctl.minZoom = 0.75;
    ctl.maxZoom = 55;
    ctl.zoomSpeed = 1.15;
    ctl.zoomToCursor = true;
    ctl.panSpeed = 1.0;
    ctl.screenSpacePanning = true;
    ctl.mouseButtons = { LEFT: THREE.MOUSE.PAN, MIDDLE: THREE.MOUSE.DOLLY, RIGHT: THREE.MOUSE.PAN };
    ctl.touches = { ONE: THREE.TOUCH.PAN, TWO: THREE.TOUCH.DOLLY_PAN };
    ctl.keyPanSpeed = 40;
    ctl.target.set(c0.x, sampleH(c0.x, c0.z), c0.z);
    cam.position.copy(ctl.target).addScaledVector(new THREE.Vector3(ISO.az, ISO.el, ISO.dz), 12000);
    cam.zoom = 1;
    S.controls = ctl;

    scene.add(new THREE.HemisphereLight(0xeaf0f4, 0x948b76, 1.12));
    const sun = new THREE.DirectionalLight(0xfff1d6, 1.62);
    sun.castShadow = true;
    sun.shadow.mapSize.set(small ? 1024 : 2048, small ? 1024 : 2048);
    const sb = small ? 420 : 850;
    Object.assign(sun.shadow.camera, { left: -sb, right: sb, top: sb, bottom: -sb, near: 100, far: 4200 });
    sun.shadow.camera.updateProjectionMatrix();
    sun.shadow.bias = -0.0005;
    sun.shadow.normalBias = 0.7;
    scene.add(sun, sun.target);
    S.light = sun;

    buildGround();
    buildRoads();
    buildTrees();
    makeLabels(window.PLACES);

    S.visible = data.slice();
    S.ready = true;
    rebuild();

    new ResizeObserver(() => resize()).observe(container);
    bindInput(renderer.domElement);

    let last = 0;
    const loop = (t) => {
      requestAnimationFrame(loop);
      if (!S.visibleOn) return;
      ctl.update();
      const tg = ctl.target;
      const limx = WORLD.w / 2 + MAP_PAD, limz = WORLD.d / 2 + MAP_PAD;
      const cx = Math.max(-limx, Math.min(limx, tg.x));
      const cz = Math.max(-limz, Math.min(limz, tg.z));
      if (cx !== tg.x || cz !== tg.z) {
        const dx = cx - tg.x, dz = cz - tg.z;
        tg.x = cx; tg.z = cz;
        cam.position.x += dx; cam.position.z += dz;
      }
      if (t - last > 40) {
        last = t;
        sun.target.position.copy(tg);
        sun.position.set(tg.x - 900, tg.y + 1500, tg.z + 700);
        const sb = Math.max(220, Math.min(1700, 2100 / cam.zoom));
        if (Math.abs(sb - sun.shadow.camera.right) > 20) {
          Object.assign(sun.shadow.camera, { left: -sb, right: sb, top: sb, bottom: -sb });
          sun.shadow.camera.updateProjectionMatrix();
        }
      }
      const ls = (2 * BASE_H / cam.zoom) * 0.14;
      if (S.labels) for (const sp of S.labels) {
        const k = (sp.userData.big || 1) * (window.innerWidth < 720 ? 0.62 : 1);
        sp.scale.set(ls * k, ls * 0.25 * k, 1);
      }
      renderer.render(scene, cam);
    };
    requestAnimationFrame(loop);

    reset();
    return true;
  } catch (e) {
    S.failed = true;
    console.warn('3D-Ansicht nicht verfügbar:', e);
    return false;
  }
}

function resize() {
  if (!S.ready || !S.container) return;
  const w = S.container.clientWidth, h = S.container.clientHeight;
  if (!w || !h) return;
  S.renderer.setSize(w, h);
  updateViewOffset();
}

/* ------------------------------ Eingabe ------------------------------ */
function bindInput(el) {
  el.addEventListener('dblclick', () => zoomBy(1.8));
  el.addEventListener('contextmenu', (e) => e.preventDefault());
}

/* --------------------------- Schnittstelle --------------------------- */
let assets = null;
function loadAssets() {
  if (!assets) {
    assets = Promise.all([
      fetch('data/scene/meta.json').then((r) => r.json()),
      fetch('data/scene/height.json').then((r) => r.json())
    ]).then(([m, h]) => { window.__SCENE_META = m; window.__SCENE_HEIGHT = h; return true; })
      .catch((e) => { console.warn('3D-Daten fehlen', e); return false; });
  }
  return assets;
}

if (window.LOD2 && window.LOD2.b) {
  for (const b of window.LOD2.b) if (b.o) LOD2.suppress.add(String(b.o));
}

window.__S = S;
window.__LOD2 = LOD2;
window.SCENE = {
  init(container) {
    S.container = container;
    return loadAssets().then(() => init(container));
  },
  show() { S.visibleOn = true; resize(); },
  hide() { S.visibleOn = false; },
  resize,
  focusBounds(b) {
    if (!S.ready) { setTimeout(() => { if (S.ready) this.focusBounds(b); }, 300); return; }
    const c = centerOf(b), r = radiusOf(b) * 1.25;
    animateTo(c, Math.min(40, BASE_H * (S.effAsp || 1) / Math.max(60, r)));
  },
  focusPoint(lat, lon) {
    if (!S.ready) { setTimeout(() => { if (S.ready) this.focusPoint(lat, lon); }, 300); return; }
    const c = toScene(lon, lat);
    animateTo(new THREE.Vector3(c.x, sampleH(c.x, c.z) + 4, c.z), 20);
  },
  zoom(f) { zoomBy(f); },
  reset() { if (S.ready) reset(); },
  at(lat, lon) { return toScene(lon, lat); },
  recenter() { if (S.ready) updateViewOffset(); },
  count() { return S.count; },
  heightOf(p) { return heightOf(p); },
  heightOfLod2(id) {
    if (!LOD2.heightMap) {
      LOD2.heightMap = {};
      for (const b of (window.LOD2 && window.LOD2.b) || []) {
        if (!b.o) continue;
        let mn = Infinity, mx = -Infinity;
        for (let i = 1; i < b.p.length; i += 3) {
          const y = b.p[i];
          if (y < mn) mn = y;
          if (y > mx) mx = y;
        }
        if (mx > mn) LOD2.heightMap[String(b.o)] = (mx - mn) / 100;
      }
    }
    return LOD2.heightMap[String(id)] || null;
  }
};


/* ------------------------------ Start ------------------------------ */
function applyMeta() {
  const m = window.__SCENE_META || {};
  const set = (id, txt) => { const e = document.getElementById(id); if (e && txt) e.textContent = txt; };
  if (m.title) document.title = m.title + ' · Isometrische Karte';
  set('mapTitle', m.title);
  set('mapSub', m.subtitle);
  set('mapEyebrow', m.eyebrow || 'Isometrische Karte');
  set('mapAttr', m.attribution);
}

const el = document.getElementById('map3d');
if (el) {
  SCENE.init(el).then((ok) => {
    if (!ok) return;
    applyMeta();
    SCENE.show();
    const on = (id, fn) => { const b = document.getElementById(id); if (b) b.addEventListener('click', fn); };
    on('zin', () => zoomBy(1.35));
    on('zout', () => zoomBy(1 / 1.35));
    on('zfit', () => reset());
  });
}
