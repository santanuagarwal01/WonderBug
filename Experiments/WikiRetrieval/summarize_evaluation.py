#!/usr/bin/env python3
"""Report measured retrieval coverage and separately reviewed answer quality.
A missing factuality review is unknown, never a correct answer.
"""
import argparse,collections,json,statistics,hashlib
from pathlib import Path

def summarize(paths,reviews):
 rows=[]
 for path in paths:rows.extend(json.loads(l)for l in Path(path).read_text().splitlines()if l)
 keys=[(r['id'],r['mode'])for r in rows]
 if len(keys)!=len(set(keys)):raise ValueError('Duplicate case/mode results; compare independent runs separately')
 labels={(r['id'],r['mode']):r for r in reviews}
 for row in rows:
  label=labels.get((row['id'],row['mode']))
  if label and label.get('answer_sha256'):
   if hashlib.sha256(row.get('generated_answer','').encode()).hexdigest()!=label['answer_sha256']:
    raise ValueError('Review belongs to a different answer: '+row['id']+' / '+row['mode'])
 result={}
 for mode in sorted({r['mode']for r in rows}):
  group=[r for r in rows if r['mode']==mode]
  metrics={'cases':len(group),'decisions':dict(collections.Counter(r['decision']for r in group))}
  times=[r['trace']['elapsedMS']for r in group if r.get('trace')]
  if times:metrics['retrieval_ms']={'median':round(statistics.median(times),1),'p95':round(sorted(times)[min(len(times)-1,int(.95*len(times)))],1)}
  for field in ['gold_source_in_fts48','gold_span_in_rerank20','gold_span_in_selected']:
   values=[r[field]for r in group if r.get(field)is not None]
   if values:metrics[field]={'hits':sum(values),'eligible':len(values),'fraction':round(sum(values)/len(values),4)}
  answerable=[r for r in group if r['expected_behavior']=='answer_from_evidence']
  metrics['supported_cases_without_displayed_answer']={'count':sum(r['decision']not in ['answered','retrieved_only']for r in answerable),'eligible':len(answerable)}
  reviewed=[labels[(r['id'],mode)]for r in group if(r['id'],mode)in labels]
  metrics['reviewed_answer_assessments']=dict(collections.Counter(r['assessment']for r in reviewed))
  metrics['reviewed_cases']=len(reviewed)
  displayed=[labels[(r['id'],mode)]for r in group if r['decision']=='answered'and(r['id'],mode)in labels]
  metrics['reviewed_displayed_assessments']=dict(collections.Counter(r['assessment']for r in displayed))
  metrics['unreviewed_generated_answers']=sum(bool(r.get('generated_answer'))and(r['id'],mode)not in labels for r in group)
  result[mode]=metrics
 return rows,result

def main(a):
 reviews=[json.loads(l)for l in Path(a.reviews).read_text().splitlines()]if a.reviews else[]
 rows,result=summarize(a.runs,reviews)
 out=Path(a.output);out.parent.mkdir(parents=True,exist_ok=True)
 out.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n')
 lines=['# Evaluation results','',
  'Exact source/span coverage is a conservative retrieval diagnostic. It can miss valid alternative evidence and is not factual answer accuracy.',
  'Answer correctness requires a separate review. Source support alone does not establish that Wikipedia itself is correct.','',
  '| Mode | Cases | Selected gold-span coverage | Supported cases without an answer | Median retrieval |',
  '|---|---:|---:|---:|---:|']
 for mode,m in result.items():
  cov=m.get('gold_span_in_selected',{});missing=m['supported_cases_without_displayed_answer']
  lines.append(f"| {mode} | {m['cases']} | {cov.get('hits','—')}/{cov.get('eligible','—')} | {missing['count']}/{missing['eligible']} | {m.get('retrieval_ms',{}).get('median','—')} ms |")
 lines+=['','## Answer review','',
  'Counts below include only explicitly reviewed cases. Unreviewed generated answers remain unclassified.','',
  '| Mode | Reviewed generated cases | Displayed-answer assessments | Unreviewed generated answers |','|---|---:|---|---:|']
 for mode,m in result.items():lines.append(f"| {mode} | {m['reviewed_cases']} | {json.dumps(m['reviewed_displayed_assessments'])} | {m['unreviewed_generated_answers']} |")
 out.write_text('\n'.join(lines)+'\n')
 queue=out.with_name(out.stem+'-review.jsonl')
 queue.write_text(''.join(json.dumps({'id':r['id'],'mode':r['mode'],'question':r['question'],
  'passage':r.get('passage'),'generated_answer':r.get('generated_answer'),'decision':r['decision'],
  'assessment':None,'notes':None},ensure_ascii=False)+'\n'for r in rows if r.get('generated_answer')))
 print(json.dumps(result,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('runs',nargs='+');p.add_argument('--reviews');p.add_argument('--output',required=True)
 main(p.parse_args())
