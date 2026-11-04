#!/usr/bin/env python3
"""Run product-owned public validators on already verified, bounded evidence data.

The operator supplies the trusted product root; no module from the evaluated revision is imported.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def load_module(path: Path):
    spec = importlib.util.spec_from_file_location('atd_product_validator', path)
    if spec is None or spec.loader is None:
        raise RuntimeError('cannot load product validator')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path: Path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--product-root', type=Path, required=True)
    parser.add_argument('--structure', type=Path, required=True)
    parser.add_argument('--glb', type=Path)
    args = parser.parse_args()
    root = args.product_root.resolve(strict=True)
    rig_file = root / 'forge/stage5_rig/validate_rig_payload.py'
    glb_file = root / 'forge/_shared/glb_container.py'
    for file in (rig_file, glb_file):
        if not file.resolve(strict=True).is_relative_to(root):
            raise ValueError('validator escapes trusted product root')
    structure_bytes = args.structure.read_bytes()
    if len(structure_bytes) > 4 * 1024 * 1024 or (args.glb and args.glb.stat().st_size > 4 * 1024 * 1024):
        raise ValueError('evidence exceeds artifact limit')
    structure = json.loads(structure_bytes)
    payloads = structure['rigPayloads']
    if not isinstance(payloads, list):
        raise ValueError('rigPayloads must be an array')
    rig = load_module(rig_file)
    glb = load_module(glb_file)
    container = None
    if args.glb:
        try:
            _, _, info = glb.parse_glb(args.glb)
            container = {'status': 'PASS', 'container': info}
        except ValueError as exc:
            container = {'status': 'FAIL', 'error': str(exc)}
    result = {
        'schema': 'atd.img2threejs-public-validation/v1',
        'helpers': {'rigSha256': digest(rig_file), 'glbSha256': digest(glb_file)},
        'glb': container,
        'rig': [rig.validate(payload) for payload in payloads],
    }
    print(json.dumps(result, allow_nan=False, separators=(',', ':')))


if __name__ == '__main__':
    main()
