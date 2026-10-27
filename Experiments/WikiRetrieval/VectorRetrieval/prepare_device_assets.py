#!/usr/bin/env python3
"""Install only the exact evaluated assets into a checkout; no model downloads or training."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        while block := f.read(1024 * 1024): h.update(block)
    return h.hexdigest()

def package_digest(path):
    path = Path(path); h = hashlib.sha256()
    for f in sorted(p for p in path.rglob('*') if p.is_file()):
        h.update(str(f.relative_to(path)).encode()); h.update(digest(f).encode())
    return h.hexdigest()

def prepare(a):
    resources = Path(a.repo).resolve() / 'WonderBug/Resources'
    manifest = json.loads((resources / 'wiki-vector-manifest.json').read_text())
    pairs = [(Path(a.corpus), resources / 'simplewiki-vector.db', manifest['corpusSHA256']),
             (Path(a.binary_index), resources / 'wiki-vectors-binary.db', manifest['indexSHA256'])]
    expected_model = 'df7aaa35ac9763341d7ac526c447897693475383a867d2a5c80f7be9dbe335d9'
    model = Path(a.encoder); destination = resources / 'WikiEmbedder.mlpackage'
    if package_digest(model) != expected_model: raise ValueError('Wrong Core ML encoder package')
    if digest(resources / 'wiki-minilm-vocab.txt') != manifest['vocabularySHA256']: raise ValueError('Wrong vocabulary')
    for source, target, expected in pairs:
        if digest(source) != expected: raise ValueError('Wrong asset: ' + str(source))
        if target.is_symlink() or (target.exists() and digest(target) != expected):
            raise ValueError('Preserving different destination: ' + str(target))
    if destination.is_symlink() or (destination.exists() and package_digest(destination) != expected_model):
        raise ValueError('Preserving different encoder destination')
    for source, target, _ in pairs:
        if not target.exists(): shutil.copyfile(source, target)
    if not destination.exists(): shutil.copytree(model, destination)
    print('Verified device assets in', resources)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['repo', 'corpus', 'binary-index', 'encoder']: parser.add_argument('--' + name, required=True)
    prepare(parser.parse_args())
