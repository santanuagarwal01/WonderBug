#!/usr/bin/env python3
"""Replay frozen conversations through three controlled retrieval arms; no Qwen generation."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import time

ARMS=['baseline','unscoped-original','unscoped-resolved']

def digest(path):
    path=Path(path);h=hashlib.sha256()
    if path.is_dir():
        for f in sorted(x for x in path.rglob('*') if x.is_file()):
            h.update(str(f.relative_to(path)).encode());h.update(digest(f).encode())
    else:
        with path.open('rb') as f:
            for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()

def validate(rows):
    ids=set();closed=set();previous=None;last_turn=0
    for row in rows:
        if row['id'] in ids:raise ValueError('Duplicate case id')
        ids.add(row['id']);episode=row['conversation_id']
        if episode!=previous:
            if episode in closed:raise ValueError('Non-contiguous conversation')
            if previous is not None:closed.add(previous)
            last_turn=0;previous=episode
        if row['turn']!=last_turn+1:raise ValueError('Missing/out-of-order turn')
        last_turn=row['turn']
        if not row['question'].strip():raise ValueError('Empty question')
        if row['expected_behavior']=='answer' and not row['resolved_question']:raise ValueError('Missing oracle rewrite')

def run(a):
    output=Path(a.output)
    if output.exists():raise ValueError('Use a new output file; do not overwrite runs')
    rows=[json.loads(l) for l in Path(a.suite).read_text().splitlines() if l]
    validate(rows)
    if a.split:rows=[r for r in rows if r['split']==a.split]
    manifest={'suite_sha256':digest(a.suite),'database_sha256':digest(a.database),
        'binary_sha256':digest(a.binary),'reranker_sha256':digest(a.reranker),
        'vocabulary_sha256':digest(Path(a.resources)/'wiki-minilm-vocab.txt'),
        'cases':len(rows),'arms':ARMS,'retrieval_mode':'hybrid-passages','gate':4.0,
        'corpus_label':a.corpus_label,'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
        'generation_enabled':False,'resolver':'reviewed oracle, not a learned implementation',
        'runtime':'macOS Core ML; timings are not iPhone latency',
        'warning':'Retrieval admissions are not correctness. Baseline session routing replays actual Swift code, but generation/safety of generated answers are not run.'}
    output.parent.mkdir(parents=True,exist_ok=True)
    stderr=output.with_suffix('.stderr.log').open('x')
    proc=subprocess.Popen([a.binary,a.database,a.reranker,a.resources],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,text=True,bufsize=1)
    def ask(data):
        proc.stdin.write(json.dumps(data)+'\n');proc.stdin.flush()
        line=proc.stdout.readline()
        if not line:raise RuntimeError('Probe exited; inspect '+str(output.with_suffix('.stderr.log')))
        result=json.loads(line)
        if 'error' in result:raise RuntimeError(result['error'])
        return result
    started=time.monotonic()
    try:
        with output.open('x') as f:
            episode=None
            for index,row in enumerate(rows):
                if row['conversation_id']!=episode:
                    ask({'op':'reset'});episode=row['conversation_id']
                for arm in ARMS:
                    result=ask({'op':'lookup','arm':arm,'question':row['question'],'resolved_question':row['resolved_question']})
                    result.update({k:row[k] for k in ['id','split','conversation_id','turn','category','expected_behavior']})
                    result['corpus']=a.corpus_label
                    candidates=(result.get('trace') or {}).get('candidates',[])
                    if len(candidates)>20:raise AssertionError('Reranker budget exceeded')
                    f.write(json.dumps(result,ensure_ascii=False)+'\n');f.flush()
                if (index+1)%10==0:print(f'{index+1}/{len(rows)} cases',flush=True)
        proc.stdin.close();proc.wait(timeout=30)
        if proc.returncode:raise RuntimeError('Probe exited with error')
        manifest['complete']=True;manifest['output_sha256']=digest(output)
    finally:
        if proc.poll() is None:proc.terminate();proc.wait(timeout=15)
        stderr.close()
        manifest['seconds']=round(time.monotonic()-started,2)
        manifest['child_peak_rss_bytes']=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        output.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['binary','database','reranker','resources','suite','output','corpus-label']:p.add_argument('--'+name,required=True)
    p.add_argument('--split',choices=['regression','unseen']);run(p.parse_args())
