#!/usr/bin/env python3
"""Summarize reviewed evidence support, never equate retrieval admissions with accuracy."""
import argparse
from collections import Counter,defaultdict
import hashlib
import json
from pathlib import Path
import statistics
from run_comparison import ARMS,digest

RUBRIC={
 'sufficient':'Selected text contains enough information for a correct core answer. Ancillary source claims are not all certified.',
 'partial':'Related evidence, but a requested fact, list member, definition, or qualifier is missing.',
 'absent':'Wrong referent, irrelevant evidence, or no support for the requested fact.',
 'ambiguous':'The evaluation question itself permits multiple senses; excluded from binary support metrics.',
}
EXCLUDED={'new-astronomy-1':'The standalone question “What is Saturn?” does not specify planet versus mythology.'}

def summarize(suite,run_paths,review_paths):
    cases={r['id']:r for r in [json.loads(l)for l in Path(suite).read_text().splitlines()]}
    reviews={}
    for path in review_paths:
        for line in Path(path).read_text().splitlines():
            r=json.loads(line);key=(r['corpus'],r['id'],r['arm'])
            if key in reviews:raise ValueError('Duplicate review: '+str(key))
            if r['support'] not in RUBRIC:raise ValueError('Invalid support label')
            reviews[key]=r
    runs=[];manifests=[]
    for path in run_paths:
        path=Path(path);m=json.loads(path.with_suffix('.manifest.json').read_text())
        if not m.get('complete') or m['suite_sha256']!=digest(suite) or m['output_sha256']!=digest(path):
            raise ValueError('Incomplete or mismatched run '+str(path))
        rows=[json.loads(l)for l in path.read_text().splitlines()]
        if len(rows)!=len(cases)*len(ARMS):raise ValueError('Incomplete matrix')
        expected={(i,arm) for i in cases for arm in ARMS}
        if {(r['id'],r['arm'])for r in rows}!=expected:raise ValueError('Case/arm mismatch')
        for r in rows:
            if len((r.get('trace')or{}).get('candidates',[]))>20:raise ValueError('Budget exceeded')
            if r.get('passage'):
                review=reviews[(r['corpus'],r['id'],r['arm'])]
                if review['passage_sha256']!=hashlib.sha256(r['passage'].encode()).hexdigest():
                    raise ValueError('Review does not match actual evidence')
                r['support']=review['support'];r['review_note']=review['note']
            else:r['support']='not_admitted'
        runs.extend(rows);manifests.append(m)
    groups=defaultdict(list)
    for r in runs:
        c=cases[r['id']]
        if c['expected_behavior']=='answer' and r['id'] not in EXCLUDED:
            groups[(r['corpus'],r['arm'],'all_answerable')].append(r)
            groups[(r['corpus'],r['arm'],c['split']+'_answerable')].append(r)
            if c['category']=='context_dependent':groups[(r['corpus'],r['arm'],'device_10_followups')].append(r)
            if c['split']=='unseen' and c['category'] in {'pronoun','correction','answer_reference'}:
                groups[(r['corpus'],r['arm'],'new_followups')].append(r)
        else:groups[(r['corpus'],r['arm'],'controls')].append(r)
    metrics=[]
    for (corpus,arm,group),rows in groups.items():
        metrics.append({'corpus':corpus,'arm':arm,'group':group,'cases':len(rows),
            'support_counts':dict(Counter(r['support']for r in rows)),
            'decision_counts':dict(Counter(r['decision']for r in rows)),
            'median_lookup_ms':round(statistics.median(r['elapsed_ms'] for r in rows if 'elapsed_ms' in r),2) if any('elapsed_ms'in r for r in rows) else None})
    return {'suite_sha256':digest(suite),'rubric':RUBRIC,'excluded_cases':EXCLUDED,'metrics':metrics,'runs':manifests,
        'review_method':'Single-assistant manual review of admitted passages against question/context; not blinded. Duplicate texts can share assessment, but every admitted output is hash-bound to a review.',
        'limitations':['No learned resolver or Qwen generation in this experiment.','Oracle rewrites use intended history, sometimes expected prior answers.','Source support does not certify all source claims.','New suite is assistant-authored and small.','Mac timing includes uncontrolled background work; no device performance claim.','One underspecified Saturn standalone question is excluded from support counts.'],
        'reviewed_outputs':[{k:r.get(k) for k in ['corpus','id','arm','decision','title','support','review_note']}for r in runs]}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--suite',required=True);p.add_argument('--runs',nargs='+',required=True)
    p.add_argument('--reviews',nargs='+',required=True);p.add_argument('--output',required=True);a=p.parse_args()
    report=summarize(a.suite,a.runs,a.reviews)
    with Path(a.output).open('x') as f:json.dump(report,f,indent=2);f.write('\n')
    for m in report['metrics']:
        if m['group']in ['all_answerable','device_10_followups','new_followups']:
            print(m['corpus'],m['arm'],m['group'],m['cases'],m['support_counts'])
