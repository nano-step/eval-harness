import * as THREE from 'three';

// Expected JSON: {worldBounds:{min:[x,y,z],max:[x,y,z],tolerance:number},
// nodes:[{path:string,parent?:string|null}], clips:[{name:string,duration?:number,
// tolerance?:number}], publicRigContract?:'rig-payload.alpha', rigUnit?:string,
// movement?:{node:string,clip:string,time:number,minDelta:number}}. Paths include
// the scene name and are separated by '/'. All fields are optional.
const LIMIT = 1000000;
const NODE_LIMIT = 10000;
const ISSUE_LIMIT = 200;
const finite = Number.isFinite;
const native = (value, cls) => value instanceof cls;
const vector = (attribute, index, size) => Array.from({length: size}, (_, i) => attribute.getComponent(index, i));
const imageAvailable = image => {
  if (Array.isArray(image)) return image.length > 0 && image.length <= 6 && image.every(item => !Array.isArray(item) && imageAvailable(item));
  if (!image || typeof image !== 'object') return false;
  const width = image.naturalWidth ?? image.videoWidth ?? image.width;
  const height = image.naturalHeight ?? image.videoHeight ?? image.height;
  return finite(width) && finite(height) && width > 0 && height > 0;
};
const dim = () => ({status: 'UNAVAILABLE', score: null, issues: [], measurements: {}});
const issue = (d, text) => { if (d.issues.length < ISSUE_LIMIT) d.issues.push(text); d.status = 'FAIL'; d.score = 0; };
const measured = d => { if (d.status === 'UNAVAILABLE') { d.status = 'PASS'; d.score = 1; } };
const error = (d, e) => { d.status = 'ERROR'; d.score = null; if (d.issues.length < ISSUE_LIMIT) d.issues.push(String(e)); };

export function evaluateStructure({scene, expected = {}}) {
  const dimensions = {geometry: dim(), sceneGraph: dim(), materials: dim(), animation: dim()};
  const {geometry: gd, sceneGraph: sd, materials: md, animation: ad} = dimensions;
  const result = {schema: 'atd.img2threejs-structure/v1', dimensions, rigPayloads: []};
  const nodes = [], paths = new Map(), seen = new Set(), uuids = new Set();
  let graphSafe = true, geometrySafe = true, work = 0;
  const consume = count => { work += count; if (!Number.isSafeInteger(count) || count < 0 || work > LIMIT) throw new Error('structural work limit exceeded'); };
  try {
    measured(sd);
    const stack = [{node: scene, parent: null, path: scene?.name || '', depth: 0}];
    while (stack.length) {
      if (nodes.length >= NODE_LIMIT) throw new Error('scene node limit exceeded');
      const {node, parent, path, depth} = stack.pop();
      if (depth > 256) throw new Error('scene depth limit exceeded');
      if (path.length > 16384) throw new Error('scene path limit exceeded');
      if (!native(node, THREE.Object3D)) { issue(sd, `invalid Object3D at ${path}`); graphSafe = false; continue; }
      if (seen.has(node)) { issue(sd, `duplicate object reference at ${path}`); graphSafe = false; continue; }
      seen.add(node); nodes.push(node);
      if (uuids.has(node.uuid)) { issue(sd, `duplicate UUID at ${path}`); graphSafe = false; }
      uuids.add(node.uuid);
      if (node.parent !== parent) { issue(sd, `invalid parent link at ${path}`); graphSafe = false; }
      if (paths.has(path)) { paths.set(path, null); } else paths.set(path, node);
      if (!Array.isArray(node.children)) { issue(sd, `invalid children at ${path}`); graphSafe = false; continue; }
      consume(node.children.length);
      for (let i = node.children.length - 1; i >= 0; i--) {
        const child = node.children[i];
        stack.push({node: child, parent: node, path: `${path}/${child?.name || ''}`, depth: depth + 1});
      }
    }
    sd.measurements.nodeCount = nodes.length;
    for (const requirement of expected.nodes || []) {
      const node = paths.get(requirement.path);
      if (!node) { issue(sd, `missing or ambiguous node path: ${requirement.path}`); continue; }
      if (Object.hasOwn(requirement, 'parent')) {
        const parent = requirement.parent === null ? null : paths.get(requirement.parent);
        if (parent === undefined || (requirement.parent !== null && parent === null) || node.parent !== parent) issue(sd, `parent mismatch: ${requirement.path}`);
      }
    }
  } catch (e) { graphSafe = false; error(sd, e); }

  try {
    let meshes = 0, triangles = 0, materialIncomplete = false;
    for (const node of nodes) {
      if (!(node.isMesh || node.isLine || node.isPoints)) continue;
      meshes++; measured(gd); measured(md);
      const materials = Array.isArray(node.material) ? node.material : [node.material];
      if (!materials.length || materials.some(m => !native(m, THREE.Material))) { issue(md, `missing or invalid material: ${node.name}`); issue(sd, `missing material: ${node.name}`); }
      for (const material of materials) {
        if (!native(material, THREE.Material)) continue;
        for (const [key, texture] of Object.entries(material)) {
          if (texture?.isTexture) {
            if (!native(texture, THREE.Texture) || !native(texture.source, THREE.Source) || !imageAvailable(texture.source.data)) issue(md, `missing texture image: ${node.name}.${key}`);
          } else if ((key === 'map' || key.endsWith('Map')) && texture != null) issue(md, `invalid texture: ${node.name}.${key}`);
        }
      }
      const geo = node.geometry;
      if (!native(geo, THREE.BufferGeometry)) { issue(gd, `missing or invalid geometry: ${node.name}`); issue(sd, `missing geometry: ${node.name}`); geometrySafe = false; materialIncomplete = true; continue; }
      const pos = geo.getAttribute('position');
      if (!pos || !(native(pos, THREE.BufferAttribute) || native(pos, THREE.InterleavedBufferAttribute)) || pos.itemSize !== 3 || !Number.isSafeInteger(pos.count) || pos.count <= 0) {
        issue(gd, `empty or invalid position attribute: ${node.name}`); geometrySafe = false; materialIncomplete = true; continue;
      }
      consume(pos.count * 3);
      let positionsOK = true;
      for (let i = 0; i < pos.count; i++) for (let k = 0; k < 3; k++) if (!finite(pos.getComponent(i, k))) positionsOK = false;
      if (!positionsOK) { issue(gd, `nonfinite position: ${node.name}`); geometrySafe = false; }
      const index = geo.index;
      const count = index ? index.count : pos.count;
      let indicesOK = true;
      if (index && (!index.isBufferAttribute || index.itemSize !== 1 || !Number.isSafeInteger(count))) indicesOK = false;
      if (indicesOK) {
        consume(count);
        for (let i = 0; i < count; i++) { const n = index ? index.getX(i) : i; if (!Number.isSafeInteger(n) || n < 0 || n >= pos.count) { indicesOK = false; break; } }
      }
      if (!indicesOK) { issue(gd, `invalid triangle index: ${node.name}`); geometrySafe = false; }
      if (node.isMesh) {
        if (!Number.isSafeInteger(count) || count === 0 || count % 3 !== 0) { issue(gd, `invalid triangle count: ${node.name}`); geometrySafe = false; }
        if (indicesOK && positionsOK) {
          const a = new THREE.Vector3(), b = new THREE.Vector3(), c = new THREE.Vector3();
          for (let i = 0; i + 2 < count; i += 3) {
            const at = j => index ? index.getX(i + j) : i + j;
            a.fromBufferAttribute(pos, at(0)); b.fromBufferAttribute(pos, at(1)); c.fromBufferAttribute(pos, at(2));
            const area = b.sub(a).cross(c.sub(a)).lengthSq();
            if (!finite(area) || area === 0) { issue(gd, `degenerate or nonfinite triangle area: ${node.name}`); break; }
          }
          triangles += Math.floor(count / 3);
        }
      }
      if (Array.isArray(node.material)) consume(geo.groups.length);
      for (const group of Array.isArray(node.material) ? geo.groups : []) {
        if (!Number.isSafeInteger(group.start) || !Number.isSafeInteger(group.count) || group.start < 0 || group.count < 0 || group.start + group.count > count || !Number.isSafeInteger(group.materialIndex) || group.materialIndex < 0 || group.materialIndex >= materials.length || !native(materials[group.materialIndex], THREE.Material)) issue(md, `invalid material group: ${node.name}`);
      }
      if (Array.isArray(node.material) && geo.groups.length === 0) issue(md, `material array has no groups: ${node.name}`);
      if (Array.isArray(node.material) && geo.groups.length) {
        const sorted = [...geo.groups].sort((a, b) => a.start - b.start);
        let end = 0;
        for (const group of sorted) { if (group.start !== end) issue(md, `material group gap or overlap: ${node.name}`); end = group.start + group.count; }
        if (end !== count) issue(md, `material groups do not cover geometry: ${node.name}`);
      }
    }
    gd.measurements.meshCount = meshes; gd.measurements.triangleCount = triangles;
    md.measurements.renderableCount = meshes;
    if (materialIncomplete && md.status === 'PASS') { md.status = 'UNAVAILABLE'; md.score = null; md.issues.push('material assignment unavailable for invalid geometry'); }
  } catch (e) { geometrySafe = false; error(gd, e); if (md.status !== 'FAIL') error(md, e); }

  if (expected.worldBounds) {
    if (graphSafe && geometrySafe && gd.status === 'PASS') {
      // Box3 updates world matrices; preserve every matrix and dirty flag exactly.
      const saved = nodes.map(n => [n, n.matrix.clone(), n.matrixWorld.clone(), n.matrixWorldNeedsUpdate, n.boundingBox]);
      const boxes = new Map(nodes.filter(n => native(n.geometry, THREE.BufferGeometry)).map(n => [n.geometry, n.geometry.boundingBox]));
      try {
        const box = new THREE.Box3().setFromObject(scene);
        const min = box.min.toArray(), max = box.max.toArray();
        gd.measurements.worldBounds = {min, max};
        const {min: wantMin, max: wantMax, tolerance = 0} = expected.worldBounds;
        if (![...min, ...max].every(finite) || !Array.isArray(wantMin) || !Array.isArray(wantMax) || wantMin.length !== 3 || wantMax.length !== 3 || !finite(tolerance) || tolerance < 0 || min.some((n, i) => !finite(wantMin[i]) || Math.abs(n - wantMin[i]) > tolerance) || max.some((n, i) => !finite(wantMax[i]) || Math.abs(n - wantMax[i]) > tolerance)) issue(gd, 'world bounds mismatch');
      } catch (e) { error(gd, e); }
      finally {
        for (const [n, matrix, world, dirty, box] of saved) { n.matrix.copy(matrix); n.matrixWorld.copy(world); n.matrixWorldNeedsUpdate = dirty; if ('boundingBox' in n) n.boundingBox = box; }
        for (const [geo, box] of boxes) geo.boundingBox = box;
      }
    } else if (gd.status === 'PASS' || gd.status === 'UNAVAILABLE') { gd.status = 'UNAVAILABLE'; gd.score = null; gd.issues.push('world bounds unavailable for invalid graph or geometry'); }
  }

  try {
    const clips = Array.isArray(scene?.animations) ? scene.animations : [];
    consume(clips.length);
    if (clips.length || (expected.clips || []).length) measured(ad);
    ad.measurements.clipCount = clips.length;
    for (const clip of clips) {
      if (!native(clip, THREE.AnimationClip)) { issue(ad, 'invalid animation clip'); continue; }
      if (!Array.isArray(clip.tracks)) { issue(ad, `invalid tracks: ${clip.name}`); continue; }
      consume(clip.tracks.length);
      for (const track of clip.tracks) consume((track?.times?.length || 0) + (track?.values?.length || 0));
      let validClip = false;
      try { validClip = clip.validate(); } catch { /* malformed track data */ }
      if (!finite(clip.duration) || clip.duration < 0 || !validClip) issue(ad, `invalid clip: ${clip.name}`);
      for (const track of clip.tracks) {
        if (!track || typeof track.name !== 'string') { issue(ad, `invalid track: ${clip.name}`); continue; }
        const times = track.times, values = track.values;
        if (!times || !values || !times.length || values.length % times.length !== 0 || values.length / times.length <= 0) { issue(ad, `invalid key dimensions: ${track.name}`); continue; }
        consume(times.length + values.length);
        const stride = values.length / times.length;
        if (!Number.isInteger(stride) || (track.ValueTypeName === 'quaternion' && stride !== 4) || (track.ValueTypeName === 'vector' && (stride < 2 || stride > 4))) issue(ad, `invalid key dimensions: ${track.name}`);
        let last = -Infinity;
        for (const t of times) { if (!finite(t) || t < 0 || t < last || t > clip.duration + 1e-6) issue(ad, `invalid key timing: ${track.name}`); last = t; }
        for (const v of values) if (typeof v === 'number' && !finite(v)) { issue(ad, `nonfinite key value: ${track.name}`); break; }
        if (graphSafe) {
          try {
            const parsed = THREE.PropertyBinding.parseTrackName(track.name);
            const binding = new THREE.PropertyBinding(scene, track.name, parsed);
            binding.bind();
            if (binding.getValue === binding._getValue_unavailable || binding.setValue === binding._setValue_unavailable || (parsed.propertyIndex !== undefined && binding.resolvedProperty?.[binding.propertyIndex] === undefined)) issue(ad, `unresolved animation binding: ${track.name}`);
            else {
              const value = [];
              binding.getValue(value, 0);
              if (value.length !== stride) issue(ad, `binding/key dimension mismatch: ${track.name}`);
            }
            binding.unbind();
          } catch { issue(ad, `unresolved animation binding: ${track.name}`); }
        } else { if (ad.status === 'PASS') { ad.status = 'UNAVAILABLE'; ad.score = null; ad.issues.push('bindings unavailable for invalid scene graph'); } }
      }
    }
    for (const requirement of expected.clips || []) {
      const matches = clips.filter(c => c?.name === requirement.name);
      if (matches.length !== 1) issue(ad, `missing or ambiguous clip: ${requirement.name}`);
      else if (requirement.duration !== undefined && (!finite(requirement.duration) || !finite(requirement.tolerance ?? 0) || Math.abs(matches[0].duration - requirement.duration) > (requirement.tolerance ?? 0))) issue(ad, `clip duration mismatch: ${requirement.name}`);
    }
    for (const node of nodes) {
      if (!node.isSkinnedMesh) continue;
      measured(ad);
      const skeleton = node.skeleton, geo = node.geometry;
      if (!native(skeleton, THREE.Skeleton) || !Array.isArray(skeleton.bones) || !skeleton.bones.length) { issue(ad, `missing skeleton: ${node.name}`); continue; }
      consume(skeleton.bones.length);
      const validBones = new Set(skeleton.bones).size === skeleton.bones.length && skeleton.bones.every(b => native(b, THREE.Bone) && seen.has(b));
      if (!validBones) issue(ad, `invalid skeleton bone references: ${node.name}`);
      if (!Array.isArray(skeleton.boneInverses) || skeleton.boneInverses.length !== skeleton.bones.length || skeleton.boneInverses.some(m => !native(m, THREE.Matrix4) || !m.elements.every(finite))) issue(ad, `invalid skeleton inverse matrices: ${node.name}`);
      const indices = geo?.getAttribute?.('skinIndex'), weights = geo?.getAttribute?.('skinWeight'), positions = geo?.getAttribute?.('position');
      if (!indices || !weights || !positions || indices.itemSize !== 4 || weights.itemSize !== 4 || indices.count !== positions.count || weights.count !== positions.count) { issue(ad, `invalid skin attributes: ${node.name}`); continue; }
      consume(indices.count * 8);
      const skinIndex = [], skinWeight = [];
      for (let i = 0; i < indices.count; i++) {
        const is = vector(indices, i, 4), ws = vector(weights, i, 4); skinIndex.push(is); skinWeight.push(ws);
        if (is.some(v => !Number.isSafeInteger(v) || v < 0 || v >= skeleton.bones.length) || ws.some(v => !finite(v) || v < 0) || Math.abs(ws.reduce((a, b) => a + b, 0) - 1) > 1e-4) issue(ad, `invalid skin indices or weights: ${node.name} vertex ${i}`);
      }
      if (expected.publicRigContract === 'rig-payload.alpha' && graphSafe && validBones) {
        const bones = skeleton.bones;
        const boneIndices = new Map(bones.map((bone, i) => [bone, i]));
        const localMatrix = b => b.matrixAutoUpdate ? new THREE.Matrix4().compose(b.position, b.quaternion, b.scale) : b.matrix.clone();
        const worldPosition = b => {
          const chain = [];
          for (let n = b; n; n = n.parent) chain.push(n);
          const world = new THREE.Matrix4();
          for (let i = chain.length - 1; i >= 0; i--) world.multiply(localMatrix(chain[i]));
          return new THREE.Vector3().setFromMatrixPosition(world).toArray();
        };
        result.rigPayloads.push({schemaVersion: 1, coordinateSystem: {up: 'Y', handedness: 'right', unit: expected.rigUnit ?? null}, joints: bones.map(worldPosition), parents: bones.map(b => boneIndices.get(b.parent) ?? null), names: bones.map(b => b.name), matrix_local: bones.map(b => localMatrix(b).toArray()), skinIndex, skinWeight});
      }
    }
    if (expected.movement) {
      const m = expected.movement, original = paths.get(m.node), clip = clips.find(c => c.name === m.clip);
      if (!graphSafe || !original || !clip || !finite(m.time) || m.time < 0 || !finite(m.minDelta) || m.minDelta < 0) issue(ad, 'invalid movement requirement or target');
      else if (ad.status !== 'FAIL' && ad.status !== 'ERROR') {
        const clone = scene.clone(true), cloneTarget = m.node.split('/').slice(1).reduce((parent, name) => parent?.children.find(c => c.name === name), clone);
        const clones = new Map(), pending = [[scene, clone]];
        while (pending.length) {
          const [source, copy] = pending.pop();
          clones.set(source, copy);
          if (copy.material) {
            const cloneMaterial = material => {
              if (!native(material, THREE.Material)) return material;
              const result = material.clone();
              for (const [key, value] of Object.entries(result)) if (native(value, THREE.Texture)) result[key] = value.clone();
              return result;
            };
            copy.material = Array.isArray(copy.material) ? copy.material.map(cloneMaterial) : cloneMaterial(copy.material);
          }
          for (let i = 0; i < source.children.length; i++) pending.push([source.children[i], copy.children[i]]);
        }
        for (const [source, copy] of clones) if (source.isSkinnedMesh && native(source.skeleton, THREE.Skeleton)) {
          copy.skeleton = source.skeleton.clone();
          copy.skeleton.bones = source.skeleton.bones.map(b => clones.get(b));
        }
        if (!cloneTarget) issue(ad, 'movement target unavailable');
        else { const before = cloneTarget.position.clone(); const mixer = new THREE.AnimationMixer(clone); mixer.clipAction(clip).play(); mixer.setTime(m.time); const delta = cloneTarget.position.distanceTo(before); mixer.stopAllAction(); ad.measurements.movementDelta = delta; if (!finite(delta) || delta < m.minDelta) issue(ad, 'movement delta below requirement'); }
      }
    }
  } catch (e) { error(ad, e); }
  return result;
}
