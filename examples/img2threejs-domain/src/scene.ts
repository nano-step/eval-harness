import * as THREE from 'three';

export function createScene(): THREE.Scene {
  const scene = new THREE.Scene();
  scene.name = 'Scene';
  const geometry = new THREE.BoxGeometry(1, 1, 1);
  const count = geometry.getAttribute('position').count;
  const indices = new Uint16Array(count * 4);
  const weights = new Float32Array(count * 4);
  for (let i = 0; i < count; i++) weights[i * 4] = 1;
  geometry.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(indices, 4));
  geometry.setAttribute('skinWeight', new THREE.Float32BufferAttribute(weights, 4));
  const mesh = new THREE.SkinnedMesh(geometry, new THREE.MeshStandardMaterial({ color: 0x5599dd, roughness: 0.65 }));
  mesh.name = 'Box';
  const bone = new THREE.Bone();
  bone.name = 'RootBone';
  mesh.add(bone);
  mesh.bind(new THREE.Skeleton([bone]));
  scene.add(mesh);
  scene.animations = [new THREE.AnimationClip('Turn', 1, [
    new THREE.QuaternionKeyframeTrack('Box.quaternion', [0, 1], [0, 0, 0, 1, 0, Math.sin(0.125), 0, Math.cos(0.125)]),
  ])];
  return scene;
}
