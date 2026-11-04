// Writes disposable source variants only. It never imports or executes the target fixture.
import fs from 'node:fs';
import path from 'node:path';
const [variant, source, destination] = process.argv.slice(2);
if (!variant || !source || !destination) throw new Error('variant, input and output required');
if (variant === 'approval-drift') {
  const approval = JSON.parse(fs.readFileSync(source, 'utf8'));
  const original = fs.realpathSync(path.resolve(path.dirname(source), approval.image));
  const image = path.join(path.dirname(destination), 'original.png');
  fs.copyFileSync(original, image, fs.constants.COPYFILE_EXCL);
  approval.image = 'original.png';
  approval.provenance.browserVersion += '-drift';
  fs.writeFileSync(destination, JSON.stringify(approval), { flag: 'wx' });
} else {
  let code = fs.readFileSync(source, 'utf8');
  const mutations = {
    compile: 'const invalid: number = "invalid";',
    load: 'throw new Error("injected load failure");',
    webgl: 'HTMLCanvasElement.prototype.getContext = (() => null) as typeof HTMLCanvasElement.prototype.getContext;',
    render: 'mesh.onBeforeRender = () => { throw new Error("injected render failure"); };',
    export: "scene.animations = [new THREE.AnimationClip('Turn', 1, [new THREE.NumberKeyframeTrack('Box.rotation[y]', [0, 1], [0, 0.25])])];",
    visual: 'mesh.material.color.set(0xff0000);',
  };
  if (!Object.hasOwn(mutations, variant)) throw new Error('unknown variant');
  const marker = '  return scene;';
  if (!code.includes(marker)) throw new Error('fixture marker missing');
  code = code.replace(marker, `  ${mutations[variant]}\n${marker}`);
  fs.writeFileSync(destination, code);
}
