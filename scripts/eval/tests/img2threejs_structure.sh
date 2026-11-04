#!/usr/bin/env bash
# Run against the already provisioned pinned dependency snapshot, never install it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${IMG2THREEJS_NODE_MODULES:-}" ]]; then
  echo 'SKIP img2threejs structure: set IMG2THREEJS_NODE_MODULES to the trusted pinned snapshot'
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/integrations/img2threejs/structure.mjs" "$TMP/structure.mjs"
ln -s "$IMG2THREEJS_NODE_MODULES" "$TMP/node_modules"
cat > "$TMP/test.mjs" <<'NODE'
import assert from 'node:assert/strict';
import * as T from 'three';
import {evaluateStructure as evaluate} from './structure.mjs';

function fixture() {
  const scene = new T.Scene(); scene.name = 'scene';
  const geo = new T.BufferGeometry();
  geo.setAttribute('position', new T.Float32BufferAttribute([0,0,0, 1,0,0, 0,1,0], 3));
  const mesh = new T.Mesh(geo, new T.MeshBasicMaterial()); mesh.name = 'mesh'; scene.add(mesh);
  const track = new T.VectorKeyframeTrack('mesh.position', [0,1], [0,0,0, 1,0,0]);
  scene.animations = [new T.AnimationClip('move', 1, [track])];
  return {scene, mesh, geo, track};
}
const expected = {worldBounds:{min:[0,0,0],max:[1,1,0],tolerance:0}, nodes:[{path:'scene/mesh',parent:'scene'}], clips:[{name:'move',duration:1}]};
function result(f, extra = {}) { return evaluate({scene:f.scene, expected:{...expected,...extra}}); }
function fails(label, dimension, mutate, extra = {}) {
  const f = fixture(); mutate(f); const r = result(f, extra);
  assert.equal(r.dimensions[dimension].status, 'FAIL', `${label}: ${JSON.stringify(r)}`);
  assert.equal(r.dimensions[dimension].score, 0, label);
}
{
  const f = fixture(); const matrix = f.mesh.matrixWorld.clone(); const before = f.mesh.position.clone();
  const r = result(f, {movement:{node:'scene/mesh',clip:'move',time:0.5,minDelta:0.4}});
  for (const [name, d] of Object.entries(r.dimensions)) assert.equal(d.status, 'PASS', `${name}: ${JSON.stringify(d)}`);
  assert.deepEqual(f.mesh.position.toArray(), before.toArray()); assert.deepEqual(f.mesh.matrixWorld.toArray(), matrix.toArray());
  assert.equal(f.geo.boundingBox, null);
}
fails('nonfinite position', 'geometry', ({geo}) => geo.attributes.position.setX(0, NaN));
fails('empty geometry', 'geometry', ({geo}) => geo.setAttribute('position', new T.Float32BufferAttribute([],3)));
fails('out of range index', 'geometry', ({geo}) => geo.setIndex([0,1,3]));
fails('fractional index', 'geometry', ({geo}) => geo.setIndex(new T.BufferAttribute(new Float32Array([0,1,1.5]),1)));
fails('degenerate face', 'geometry', ({geo}) => geo.setIndex([0,0,1]));
fails('wrong world bounds', 'geometry', () => {}, {worldBounds:{min:[0,0,0],max:[2,1,0],tolerance:0}});
fails('duplicate object', 'sceneGraph', ({scene,mesh}) => scene.children.push(mesh));
fails('duplicate uuid', 'sceneGraph', ({scene,mesh}) => { const n = new T.Object3D(); n.uuid = mesh.uuid; scene.add(n); });
fails('broken parent', 'sceneGraph', ({mesh}) => { mesh.parent = null; });
fails('missing geometry', 'sceneGraph', ({mesh}) => { mesh.geometry = null; });
fails('hierarchy mismatch', 'sceneGraph', () => {}, {nodes:[{path:'scene/mesh',parent:null}]});
fails('missing material', 'materials', ({mesh}) => { mesh.material = null; });
fails('missing texture image', 'materials', ({mesh}) => { mesh.material.map = new T.Texture(); });
fails('invalid texture image object', 'materials', ({mesh}) => { mesh.material.map = new T.Texture({}); });
{ const f = fixture(); f.mesh.material.map = new T.DataTexture(new Uint8Array([255,255,255,255]),1,1); assert.equal(result(f).dimensions.materials.status,'PASS', 'valid texture'); }
fails('invalid group material index', 'materials', ({mesh,geo}) => { mesh.material = [mesh.material]; geo.addGroup(0,3,1); });
fails('group coverage gap', 'materials', ({mesh,geo}) => { mesh.material = [mesh.material]; geo.addGroup(1,2,0); });
{ const f = fixture(); f.mesh.geometry = new T.BoxGeometry(); assert.equal(result(f, {worldBounds: undefined}).dimensions.materials.status, 'PASS', 'single material ignores geometry group material indices'); }
fails('missing animation target', 'animation', ({scene}) => { scene.animations[0].tracks[0].name = 'absent.position'; });
fails('missing animation property', 'animation', ({scene}) => { scene.animations[0].tracks[0].name = 'mesh.missing'; });
fails('missing indexed target', 'animation', ({scene}) => { scene.animations[0].tracks[0].name = 'mesh.materials[4].opacity'; });
fails('binding dimension mismatch', 'animation', ({scene}) => { scene.animations[0].tracks[0] = new T.NumberKeyframeTrack('mesh.position',[0,1],[0,1]); });
fails('nonfinite animation values', 'animation', ({track}) => { track.values[0] = NaN; });
fails('unsorted animation keys', 'animation', ({track}) => { track.times[0] = 0.8; track.times[1] = 0.2; });
fails('key exceeds duration', 'animation', ({scene}) => { scene.animations[0].duration = 0.5; });
fails('required duration', 'animation', () => {}, {clips:[{name:'move',duration:2}]});
{ const f = fixture(); f.scene.animations = [new T.AnimationClip('pose',0,[new T.VectorKeyframeTrack('mesh.position',[0],[0,0,0])])]; assert.equal(result(f,{clips:[{name:'pose',duration:0}]}).dimensions.animation.status,'PASS','zero-duration pose'); }
fails('missing skeleton', 'animation', ({scene,geo,mesh}) => { scene.remove(mesh); const skin = new T.SkinnedMesh(geo,mesh.material); skin.name = 'mesh'; scene.add(skin); });
{
 const f = fixture(); const boneA = new T.Bone(), boneB = new T.Bone(); boneA.name = 'a'; boneB.name = 'b'; boneB.position.y = 1;
 f.geo.setAttribute('skinIndex', new T.Uint16BufferAttribute([0,0,0,0, 1,0,0,0, 0,0,0,0],4));
 f.geo.setAttribute('skinWeight', new T.Float32BufferAttribute([1,0,0,0, 1,0,0,0, 1,0,0,0],4));
 const skin = new T.SkinnedMesh(f.geo,f.mesh.material); skin.name = 'mesh'; f.scene.remove(f.mesh); f.scene.add(skin, boneA, boneB); skin.bind(new T.Skeleton([boneA,boneB]));
 assert.equal(result(f).dimensions.animation.status, 'PASS', 'multiple skeleton roots are legal');
 const payload = result(f,{publicRigContract:'rig-payload.alpha'}).rigPayloads[0]; assert.deepEqual(payload.parents,[null,null]);
 f.geo.attributes.skinWeight.setX(0,0); assert.equal(result(f).dimensions.animation.status, 'FAIL', 'invalid skin weight');
 f.geo.attributes.skinWeight.setX(0,1); f.geo.attributes.skinIndex.setX(0,2); assert.equal(result(f).dimensions.animation.status, 'FAIL', 'invalid skin index');
 f.geo.attributes.skinIndex.setX(0,0); f.scene.remove(boneB); assert.equal(result(f).dimensions.animation.status, 'FAIL', 'skeleton bone outside scene');
}
{
 const f = fixture(); f.scene.animations = []; const r = evaluate({scene:f.scene});
 assert.equal(r.dimensions.animation.status, 'UNAVAILABLE'); assert.equal(r.dimensions.animation.score, null);
}
console.log('img2threejs structure behavior regressions passed');
NODE
node "$TMP/test.mjs"
