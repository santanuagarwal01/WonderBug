#!/usr/bin/env python3
"""Diagnostic probes only; never imported by retrieval or corpus/index construction."""
import argparse,json
from pathlib import Path

def inspect(run):
 records=[json.loads(l)for l in Path(run).read_text().splitlines()]
 out=[]
 # These strings locate evidence for already-audited failures; they do not grade the whole suite.
 targets={'device-41':'Raymond Parks','device-29':'waning crescent','new-curie-2':'Pierre','device-38':'Jupiter'}
 for r in records:
  if r['id']not in targets:continue
  needle=targets[r['id']]
  candidates=r.get('candidates',[])
  item={'id':r['id'],'question_mode':r['question_mode'],'arm':r['arm'],'decision':r['decision'],'selected_title':r.get('title'),
    'selected_passage':r.get('passage'),'matching_candidates':[c for c in candidates if needle.casefold()in c['text'].casefold()],
    'note':'String presence is a diagnostic locator, not proof of answer support.'}
  if r['id']=='device-41':
   source='a:35750:p:0'
   item['spouse_source_rank']={name:(values.index(source)+1 if source in values else None)for name,values in r.get('raw_source_ranks',{}).items()}
   item['spouse_source_prepared']=source in r.get('prepared_source_ids',[])
   item['spouse_source_reranked']=any(c.get('sourceID')==source for c in candidates)
  out.append(item)
 return out
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--run',required=True);p.add_argument('--output',required=True);a=p.parse_args()
 with Path(a.output).open('x')as f:json.dump(inspect(a.run),f,indent=2,ensure_ascii=False);f.write('\n')
