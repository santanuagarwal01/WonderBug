#!/usr/bin/env python3
"""Choose a scalar relevance cutoff from reviewed SUPPORT labels, not word overlap.
A relevance cutoff cannot establish entailment; output is an experimental operating point.
"""
import argparse,hashlib,json,math
from pathlib import Path

def metrics(rows,threshold):
 accepted=[r for r in rows if r.get('score') is not None and r['score']>=threshold]
 tp=sum(r['supported']for r in accepted);fp=len(accepted)-tp
 positives=sum(r['supported']for r in rows)
 return dict(threshold=threshold,accepted=len(accepted),supported_accepted=tp,unsupported_accepted=fp,
             supported_rejected=positives-tp,precision=tp/len(accepted)if accepted else None,
             recall=tp/positives if positives else None,cases=len(rows))

def calibrate(rows,minimum_precision=.90,baseline=4.0):
 if not rows or any(r['partition']!='calibration'for r in rows):raise ValueError('Only calibration labels may select a threshold')
 if len({r['id']for r in rows})!=len(rows):raise ValueError('Duplicate case labels')
 if any(r.get('score')is not None and not math.isfinite(r['score'])for r in rows):raise ValueError('Nonfinite score')
 original=metrics(rows,baseline)
 scores=sorted({r['score']for r in rows if r.get('score')is not None}|{baseline})
 curve=[metrics(rows,t)for t in scores]
 # Preserve the baseline false-acceptance budget while recovering supported answers.
 eligible=[m for m in curve if m['precision']is not None and m['precision']>=minimum_precision
           and m['unsupported_accepted']<=original['unsupported_accepted']]
 best=max(eligible,key=lambda m:(m['supported_accepted'],-m['unsupported_accepted'],m['threshold']))if eligible else original
 return dict(selected=best,baseline=original,curve=curve,minimum_precision=minimum_precision,
             objective='Maximize supported acceptance at >=90% observed precision without increasing baseline unsupported acceptance; highest cutoff breaks exact ties.',
             warning='Small development calibration, not a probability, correctness guarantee, or answer-level accuracy.')

def main(a):
 p=Path(a.reviews);rows=[json.loads(l)for l in p.read_text().splitlines()]
 report=calibrate([r for r in rows if r['partition']=='calibration'])
 report['validation']={name:metrics([r for r in rows if r['partition']=='validation'],t)for name,t in [('baseline',4.0),('selected',report['selected']['threshold'])]}
 report['labels_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
 out=Path(a.output)
 if out.exists():raise ValueError('Choose a new output')
 out.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items()if k!='curve'},indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reviews',required=True);p.add_argument('--output',required=True);main(p.parse_args())
