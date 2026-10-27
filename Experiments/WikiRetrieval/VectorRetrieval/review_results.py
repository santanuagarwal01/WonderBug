#!/usr/bin/env python3
"""Prepare exact-text manual review and summarize only a complete, hash-verified run."""
import argparse,hashlib,json,statistics
from collections import Counter,defaultdict
from pathlib import Path
from embedding import digest
from run_comparison import ARMS
MODES=['original','reviewed-complete']
LABELS={'sufficient','partial','absent','ambiguous'}
EXCLUDED={'new-astronomy-1':'Standalone Saturn does not specify mythology versus planet.'}

def rows(path):return [json.loads(l)for l in Path(path).read_text().splitlines()if l]
def text_hash(text):return hashlib.sha256(text.encode()).hexdigest()
def validated(suite,run,protocol):
 cases={r['id']:r for r in rows(suite)};data=rows(run);manifest=json.loads(Path(run).with_suffix('.manifest.json').read_text())
 if not manifest.get('complete')or manifest['output_sha256']!=digest(run)or manifest['suite_sha256']!=digest(suite)or manifest['protocol_sha256']!=digest(protocol):raise ValueError('Run/protocol/suite mismatch')
 expected={(i,m,a)for i in cases for m in MODES for a in ARMS}
 if len(data)!=len(expected)or {(r['id'],r['question_mode'],r['arm'])for r in data}!=expected:raise ValueError('Incomplete/duplicate matrix')
 for r in data:
  if len(r.get('candidates',[]))>20:raise ValueError('Candidate budget exceeded')
  if r.get('passage')and not any(c['text']==r['passage']for c in r['candidates']):raise ValueError('Selected text not in candidate set')
 return cases,data,manifest

def queue(a):
 cases,data,manifest=validated(a.suite,a.run,a.protocol);known={}
 for p in a.previous_reviews:
  for r in rows(p):
   k=(r['id'],r['passage_sha256'])
   if k in known and known[k]['support']!=r['support']:raise ValueError('Conflicting prior reviews')
   known[k]={'support':r['support'],'note':r['note']}
 out={}
 for r in data:
  if not r.get('passage'):continue
  h=text_hash(r['passage']);k=(r['id'],h)
  if k not in out:
   out[k]={'id':r['id'],'question':cases[r['id']]['question'],'intended_question':cases[r['id']]['resolved_question'],
      'passage_sha256':h,'passage':r['passage'],'occurrences':[],'review':known.get(k)}
  out[k]['occurrences'].append({'question_mode':r['question_mode'],'arm':r['arm']})
 with Path(a.output).open('x')as f:json.dump(list(out.values()),f,indent=2,ensure_ascii=False);f.write('\n')
 print('Unique admitted case/texts:',len(out),'Needing review:',sum(r['review']is None for r in out.values()))

def summarize(a):
 cases,data,manifest=validated(a.suite,a.run,a.protocol);review={}
 for r in json.loads(Path(a.reviews).read_text()):
  if text_hash(r['passage'])!=r['passage_sha256']:raise ValueError('Review text changed')
  label=r.get('review')
  if not label or label['support']not in LABELS or not label['note']:raise ValueError('Unreviewed passage')
  k=(r['id'],r['passage_sha256'])
  if k in review:raise ValueError('Duplicate review')
  review[k]=label
 groups=defaultdict(list)
 for r in data:
  c=cases[r['id']];label=review[(r['id'],text_hash(r['passage']))] if r.get('passage')else {'support':'not_admitted','note':''}
  r['support']=label['support'];r['review_note']=label['note']
  if c['expected_behavior']=='answer'and r['id']not in EXCLUDED:
   names=['answerable',c['split']+'_answerable']
   if c['category']=='context_dependent':names.append('device_followups')
   if c['split']=='unseen'and c['category']in {'pronoun','correction','answer_reference'}:names.append('new_followups')
  else:names=['controls']
  for name in names:groups[(r['question_mode'],r['arm'],name)].append(r)
 metrics=[]
 for (mode,arm,group),rs in groups.items():metrics.append({'question_mode':mode,'arm':arm,'group':group,'cases':len(rs),'support':dict(Counter(r['support']for r in rs)),'decisions':dict(Counter(r['decision']for r in rs))})
 performance=[]
 for mode in MODES:
  for arm in ARMS:
   rs=[r for r in data if r['question_mode']==mode and r['arm']==arm and 'rerank_ms'in r]
   timing={k:round(statistics.median(r[k]for r in rs if k in r),2) for k in ['lexical_ms','embedding_ms','vector_search_ms','prepare_union_ms','rerank_ms']if any(k in r for r in rs)}
   performance.append({'question_mode':mode,'arm':arm,'median_components_ms':timing})
 changes=[];bykey={(r['id'],r['question_mode'],r['arm']):r for r in data}
 for r in data:
  if r['arm']=='bm25-fusion':continue
  old=bykey[r['id'],r['question_mode'],'bm25-fusion']
  if r['support']!=old['support']:changes.append({'id':r['id'],'question_mode':r['question_mode'],'arm':r['arm'],'from':old['support'],'to':r['support'],'selected_title':r.get('title')})
 report={'manifest':manifest,'excluded_cases':EXCLUDED,'metrics':metrics,'performance':performance,'changes_from_bm25':changes,
   'review_method':'Single-assistant manual support review. Exact case/text matches reuse prior reviews. Every admitted output requires a text-bound label. Not an independent or blinded factuality evaluation.',
   'limitations':['Reviewed-complete questions are an oracle, not a learned resolver.','Original questions search without conversation topic reuse.','No Qwen answers generated.','Core support does not certify every source claim.','Previously used 75-case suite; not a new held-out benchmark.','Mac timings, no iPhone latency or battery measurement.','Union preparation is shared; component medians must not be summed as per-arm end-to-end latency.'],
   'reviewed_outputs':[{k:r.get(k)for k in ['id','question_mode','arm','decision','title','support','review_note']}for r in data]}
 with Path(a.output).open('x')as f:json.dump(report,f,indent=2,ensure_ascii=False);f.write('\n')
 for m in metrics:
  if m['group']in {'answerable','device_followups','new_followups'}:print(m)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('operation',choices=['queue','summarize'])
 for name in ['suite','run','protocol','output']:p.add_argument('--'+name,required=True)
 p.add_argument('--previous-reviews',nargs='*',default=[]);p.add_argument('--reviews');a=p.parse_args();queue(a)if a.operation=='queue'else summarize(a)
