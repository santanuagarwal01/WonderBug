#!/usr/bin/env python3
"""Compare the native binary-vector path with the frozen offline outputs, then test asset failures."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

def run(a):
    process = subprocess.Popen([a.binary, a.resources], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    def ask(value):
        process.stdin.write(json.dumps(value) + '\n'); process.stdin.flush()
        line = process.stdout.readline()
        if not line: raise RuntimeError('Native probe stopped')
        return json.loads(line)
    results = []
    try:
        cases = [json.loads(line) for line in Path(a.reference).read_text().splitlines()]
        for case in cases:
            if case['arm'] != 'vec-binary-fusion' or case['decision'] not in {'retrieved', 'retrieval_rejected'}:
                continue
            actual = ask({'question': case['retrieval_question']})
            trace = actual.get('trace', {})
            expected_candidates = [(c.get('sourceID'), c['text']) for c in case['candidates']]
            actual_candidates = [(c.get('sourceID'), c['text']) for c in trace.get('candidates', [])]
            checks = {
                'candidate_parity': actual_candidates == expected_candidates,
                'decision_parity': actual['decision'] == case['decision'],
                'selected_text_parity': actual.get('passage') == case.get('passage'),
                'bounded': len(actual_candidates) <= 20,
                'native_vectors_used_or_empty_query': len(trace.get('vectorSourceIDs', [])) == 48
                    or (actual.get('reason') == 'no content words' and not expected_candidates),
            }
            results.append({'id': case['id'], 'mode': case['question_mode'], **checks})
            if len(results) % 50 == 0: print('Compared', len(results), 'cases', flush=True)
        # App session handling must actually route a follow-up through vector retrieval.
        ask({'op': 'reset'})
        first = ask({'op': 'session', 'question': 'Who was Rosa Parks?'})
        followup = ask({'op': 'session', 'question': 'Who was her husband?'})
        assert first['decision'] == 'retrieved'
        assert followup['trace']['mode'] == 'sqlite-vec'
        assert 'Rosa Parks' in followup['trace']['retrievalQuestion']
        assert len(followup['trace']['vectorSourceIDs']) == 48
        assert len(followup['trace']['candidates']) <= 20
        missing = ask({'op': 'missing-assets', 'question': 'What is a planet?'})
        assert missing['decision'] == 'retrieval_rejected' and 'vectorError' in missing['trace']
        manifest = json.loads((Path(a.resources) / 'wiki-vector-manifest.json').read_text())
        failures = []
        with tempfile.TemporaryDirectory() as directory:
            for field in ['corpusSHA256', 'indexSHA256', 'vocabularySHA256', 'encoderWeightsSHA256']:
                bad = dict(manifest); bad[field] = '0' * 64
                path = Path(directory) / (field + '.json'); path.write_text(json.dumps(bad))
                result = ask({'question': 'What is a planet?', 'manifest': str(path)})
                assert result['decision'] == 'retrieval_rejected' and 'vectorError' in result['trace'], field
                failures.append(field)
        report = {'comparisons': len(results), 'all_passed': all(all(r[k] for k in [
            'candidate_parity', 'decision_parity', 'selected_text_parity', 'bounded', 'native_vectors_used_or_empty_query']) for r in results),
            'followup_vector_route': True, 'missing_assets_rejected': True,
            'mismatched_assets_rejected': failures, 'cases': results}
        Path(a.output).write_text(json.dumps(report, indent=2) + '\n')
        print({k: v for k, v in report.items() if k != 'cases'})
        if not report['all_passed']:
            print('Differences:', [r for r in results if not all(v for k, v in r.items() if k not in {'id', 'mode'})])
            raise SystemExit(1)
    finally:
        process.stdin.close(); process.wait(timeout=30)
        if process.returncode: raise RuntimeError('Probe failed')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['binary', 'resources', 'reference', 'output']: parser.add_argument('--' + name, required=True)
    run(parser.parse_args())
