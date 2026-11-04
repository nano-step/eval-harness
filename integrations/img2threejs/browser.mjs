import * as THREE from 'three';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { evaluateStructure } from './structure.mjs';

const finiteBounds = (box) => ({ min: box.min.toArray(), max: box.max.toArray() });
function describe(scene, clips) {
  let meshes = 0, triangles = 0;
  scene.traverse((object) => {
    if (!object.isMesh) return;
    meshes++;
    const geometry = object.geometry;
    triangles += (geometry.index ? geometry.index.count : geometry.getAttribute('position').count) / 3;
  });
  return { meshes, triangles, bounds: finiteBounds(new THREE.Box3().setFromObject(scene)), clips: clips.map(({ name, duration }) => ({ name, duration })).sort((a, b) => a.name.localeCompare(b.name)) };
}
function equivalent(a, b) {
  const near = (x, y) => Math.abs(x - y) <= 1e-4;
  return a.meshes === b.meshes && a.triangles === b.triangles &&
    a.bounds.min.every((n, i) => near(n, b.bounds.min[i])) && a.bounds.max.every((n, i) => near(n, b.bounds.max[i])) &&
    a.clips.length === b.clips.length && a.clips.every((clip, i) => clip.name === b.clips[i].name && near(clip.duration, b.clips[i].duration));
}
export async function evaluate(createScene, expected) {
  const runtime = { schema: 'atd.img2threejs-runtime/v1', load: null, render: null, export: null };
  let scene;
  try { scene = await createScene(); if (!scene?.isScene) throw new Error('createScene did not return a Three.js Scene'); runtime.load = { status: 'PASS' }; }
  catch (error) { runtime.load = { status: 'FAIL', error: String(error?.stack || error) }; return { runtime }; }
  let structure;
  try { structure = evaluateStructure({ scene, expected }); }
  catch (error) { runtime.structureError = String(error?.stack || error); return { runtime }; }
  if (structure.dimensions.sceneGraph.status !== 'PASS') return { runtime, structure };
  const config = { width: 512, height: 512, dpr: 1, camera: { fov: 40, position: [3, 2, 4], target: [0, 0, 0], near: 0.1, far: 100 }, background: 0x202830, ambient: 1.2, directional: { intensity: 2, position: [3, 5, 4] }, time: 0, antialias: false };
  try {
    const renderer = new THREE.WebGLRenderer({ antialias: config.antialias, preserveDrawingBuffer: true });
    renderer.setPixelRatio(config.dpr); renderer.setSize(config.width, config.height);
    renderer.setClearColor(config.background); renderer.outputColorSpace = THREE.SRGBColorSpace;
    document.body.style.margin = '0'; document.body.append(renderer.domElement);
    const camera = new THREE.PerspectiveCamera(config.camera.fov, config.width / config.height, config.camera.near, config.camera.far);
    camera.position.set(...config.camera.position); camera.lookAt(...config.camera.target);
    const ambient = new THREE.AmbientLight(0xffffff, config.ambient);
    const directional = new THREE.DirectionalLight(0xffffff, config.directional.intensity); directional.position.set(...config.directional.position);
    // Lights are placed in a separate render scene so target graph/export remain unchanged.
    const renderScene = new THREE.Scene(); renderScene.add(ambient, directional);
    const originalParent = scene.parent; renderScene.add(scene); renderer.render(renderScene, camera); renderScene.remove(scene); if (originalParent) originalParent.add(scene);
    const gl = renderer.getContext();
    runtime.render = { status: renderer.info.render.calls > 0 && renderer.info.render.triangles > 0 && !gl.isContextLost() && gl.getError() === gl.NO_ERROR ? 'PASS' : 'FAIL', calls: renderer.info.render.calls, triangles: renderer.info.render.triangles, webglVersion: gl.getParameter(gl.VERSION), renderer: gl.getParameter(gl.RENDERER), config };
  } catch (error) { runtime.render = { status: 'FAIL', error: String(error?.stack || error), config }; }
  try {
    const clips = scene.animations || [];
    const before = describe(scene, clips);
    const bytes = await new GLTFExporter().parseAsync(scene, { binary: true, animations: clips });
    if (!(bytes instanceof ArrayBuffer)) throw new Error('GLTFExporter did not return binary data');
    const loaded = await new GLTFLoader().parseAsync(bytes, '');
    const after = describe(loaded.scene, loaded.animations);
    const binary = new Uint8Array(bytes);
    let encoded = ''; for (let i = 0; i < binary.length; i += 32768) encoded += String.fromCharCode(...binary.subarray(i, i + 32768));
    runtime.export = { status: equivalent(before, after) ? 'PASS' : 'FAIL', before, after, bytes: binary.length };
    return { runtime, structure, glb: btoa(encoded) };
  } catch (error) { runtime.export = { status: 'FAIL', error: String(error?.stack || error) }; return { runtime, structure }; }
}
