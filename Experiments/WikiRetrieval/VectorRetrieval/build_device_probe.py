#!/usr/bin/env python3
"""Build actual native retrieval on macOS for parity/failure-path tests, without editing app files."""
import argparse
from pathlib import Path
import subprocess

def build(repo, output):
    repo = Path(repo).resolve(); output = Path(output).resolve(); output.mkdir(parents=True, exist_ok=True)
    source = repo / 'WonderBug/Services'
    include = repo / 'Packages/SQLiteVec/Sources/CSQLiteVec/include'
    obj = output / 'sqlite-vec.o'
    subprocess.run(['clang', '-O2', '-DSQLITE_CORE', '-DSQLITE_VEC_STATIC', '-I', str(include),
                    '-c', str(include.parent / 'sqlite-vec.c'), '-o', str(obj)], check=True)
    copy = output / 'WikiSearchService.swift'
    copy.write_text((source / 'WikiSearchService.swift').read_text() + '''
extension WikiSearchService {
    func deviceTestAssets(_ assets: WikiVectorIndex.Assets?) {
        vectorIndex = nil
        vectorAssets = assets
    }
}
''')
    files = [copy, repo / 'Experiments/WikiRetrieval/VectorRetrieval/DeviceProbe.swift']
    files += [source / name for name in ['WikiVectorIndex.swift', 'WikiRankFusion.swift',
        'WikiSentenceEmbedder.swift', 'WikiPassageReranker.swift', 'WikiRetrievalTrace.swift',
        'SafetyService.swift', 'DebugLog.swift']]
    binary = output / 'device-probe'
    subprocess.run(['swiftc', '-O', '-default-isolation', 'MainActor', '-module-cache-path',
                    str(output / 'modules'), '-I', str(include), *map(str, files), str(obj), '-o', str(binary)], check=True)
    print(binary)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--repo', required=True); parser.add_argument('--output', required=True)
    args = parser.parse_args(); build(args.repo, args.output)
