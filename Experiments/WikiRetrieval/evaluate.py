#!/usr/bin/env python3
"""Run retrieval and optional Qwen baselines. No training; never infer factuality from overlap.
Answers use a LOCAL LM Studio completion endpoint and the app's own tokenizer/chat template.
"""
import argparse,hashlib,json,subprocess,time,urllib.request
from pathlib import Path

class Bridge:
 def __init__(self,args):
  self.p=subprocess.Popen([args.binary,args.database,args.reranker,args.resources],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,bufsize=1)
 def ask(self,**request):
  self.p.stdin.write(json.dumps(request)+'\n');self.p.stdin.flush()
  line=self.p.stdout.readline()
  if not line:raise RuntimeError('Swift evaluator exited; inspect its stderr')
  r=json.loads(line)
  if 'error'in r:raise RuntimeError(r['error'])
  return r
 def close(self):
  self.p.stdin.close();self.p.wait(timeout=30)

def sha(path):
 h=hashlib.sha256()
 with open(path,'rb')as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()

def asset_digest(path):
 path=Path(path)
 if path.is_file():return sha(path)
 h=hashlib.sha256()
 for f in sorted(p for p in path.rglob('*')if p.is_file()):
  h.update(str(f.relative_to(path)).encode());h.update(sha(f).encode())
 return h.hexdigest()

def main(a):
 if Path(a.output).exists():raise ValueError('Choose a new output file; existing runs are immutable')
 cases=[json.loads(l)for l in Path(a.suite).read_text().splitlines()if l]
 cases=[r for r in cases if r['split'] in a.splits.split(',')]
 if a.limit:cases=cases[:a.limit]
 if a.ids:cases=[r for r in cases if r['id']in a.ids.split(',')]
 modes=a.modes.split(',')
 if any(m not in ['legacy','passages','direct-passages','hybrid-passages','calibrated-passages','gold']for m in modes):raise ValueError('Invalid mode')
 if 'gold'in modes and not a.answers:raise ValueError('Gold evidence is an answer-generation control; pass --answers')
 output=Path(a.output);output.parent.mkdir(parents=True,exist_ok=True)
 manifest={'suite_sha256':sha(a.suite),'database_sha256':sha(a.database),'binary_sha256':sha(a.binary),
  'reranker_sha256':asset_digest(a.reranker),'vocabulary_sha256':sha(Path(a.resources)/'wiki-minilm-vocab.txt'),
  'modes':modes,'splits':a.splits,'cases':len(cases),'answers_enabled':a.answers,'runtime':'Mac CoreML + local LM Studio (not iPhone parity)',
  'generation':{'max_tokens':100,'temperature':0,'top_p':1,'repeat_penalty':1.0},
  'accuracy_warning':'Retrieval source/span coverage is not semantic answer accuracy. See independent review labels.',
  'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
 gate_path=Path(a.resources)/'wiki-relevance-gate.json'
 if gate_path.exists():manifest['gate_policy_sha256']=sha(gate_path)
 template=None
 if a.answers:
  from jinja2.sandbox import ImmutableSandboxedEnvironment
  import jinja2.ext
  if not a.model_dir or not a.model_id:raise ValueError('--model-dir and --model-id required for answers')
  config=json.loads((Path(a.model_dir)/'tokenizer_config.json').read_text())
  env=ImmutableSandboxedEnvironment(trim_blocks=True,lstrip_blocks=True,extensions=[jinja2.ext.loopcontrols])
  template=env.from_string(config['chat_template'])
  manifest['model_id']=a.model_id
  manifest['model_sha256']={p.name:sha(p)for p in Path(a.model_dir).glob('*.safetensors')}
 output.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 bridge=Bridge(a);contexts={m:[]for m in modes};pending={m:False for m in modes};episode=None
 system=bridge.ask(op='prompts')['system']
 manifest['system_prompt_sha256']=hashlib.sha256(system.encode()).hexdigest()
 output.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 try:
  with output.open('x')as f:
   for index,case in enumerate(cases):
    current=case.get('conversation_id',case['id'])
    if current!=episode:
     bridge.ask(op='reset');contexts={m:[]for m in modes};pending={m:False for m in modes};episode=current
    for mode in modes:
     if mode=='gold' and not case.get('gold'):continue
     start=time.monotonic()
     r={'id':case['id'],'question':case['question'],'mode':mode,'split':case['split'],'category':case['category'],
        'expected_behavior':case['expected_behavior'],'answer_review':None}
     gate=bridge.ask(op='question',text=case['question'])
     if gate['blocked'] or(pending[mode]and gate['bare_follow_up']):
      pending[mode]=True;r['decision']='question_blocked'
     else:
      pending[mode]=False
      if mode=='gold':
       result={'passage':case['gold_passage'],'title':case['gold']['title'],'source_ids':[case['gold']['source_id']],
        'reused_topic':case['gold']['title']if case.get('turn',0)>0 else None}
       result['passage_safe']=bridge.ask(op='passage',text=result['passage'])['safe']
      else:result=bridge.ask(op='lookup',mode=mode,question=case['question'])
      r.update(result)
      gold=case.get('gold')
      if gold and mode!='gold':
       trace=result.get('trace')or{}
       r['gold_source_in_fts48']=any(c.get('sourceID')==gold['source_id']for c in trace.get('retrievedSources',[]))if mode in ['direct-passages','hybrid-passages','calibrated-passages']else None
       # Exact span coverage is conservative: legitimate paraphrases/alternate evidence need review.
       norm=lambda s:' '.join(s.lower().split())
       span=norm(gold['support_span'])
       r['gold_span_in_rerank20']=any(span in norm(c['text'])for c in trace.get('candidates',[]))if mode!='legacy'else None
       r['gold_span_in_selected']=span in norm(result.get('passage',''))
      if not result.get('passage'):r['decision']='retrieval_rejected'
      elif not result.get('passage_safe',True):r['decision']='passage_blocked'
      elif not a.answers:r['decision']='retrieved_only'
      else:
       topic=result.get('reused_topic');context=[t for t in contexts[mode]if t['topic']==topic][-2:]if topic else[]
       messages=[{'role':'system','content':system}]
       for t in context:messages.extend([{'role':'user','content':t['question']},{'role':'assistant','content':t['answer']}])
       messages.append({'role':'user','content':f"Passage: {result['passage']}\n\nQuestion: {case['question']}"})
       prompt=template.render(messages=messages,add_generation_prompt=True,enable_thinking=False)
       body=dict(manifest['generation'],model=a.model_id,prompt=prompt,stop=['<|im_end|>','<|endoftext|>'],stream=False)
       req=urllib.request.Request(a.server+'/v1/completions',json.dumps(body).encode(),{'Content-Type':'application/json'})
       t=time.monotonic()
       with urllib.request.urlopen(req,timeout=180)as response:raw=json.load(response)['choices'][0]['text']
       r['generation_ms']=(time.monotonic()-t)*1000;r['raw_answer']=raw
       processed=bridge.ask(op='answer',raw=raw,passage=result['passage'])
       r['generated_answer']=processed['cleaned'];r['word_overlap_score']=processed['score']
       if not processed['cleaned']:r['decision']='empty_answer'
       elif processed['blocked']:r['decision']='answer_blocked';pending[mode]=True
       elif not processed['grounded']:r['decision']='word_overlap_rejected'
       else:
        r['decision']='answered';r['displayed_answer']=processed['cleaned']
        contexts[mode].append({'question':case['question'],'answer':processed['cleaned'],'topic':result['title']})
        contexts[mode]=contexts[mode][-5:]
     r['elapsed_ms']=(time.monotonic()-start)*1000
     f.write(json.dumps(r,ensure_ascii=False)+'\n');f.flush()
    if(index+1)%20==0:print(f'{index+1}/{len(cases)} cases',flush=True)
 finally:bridge.close()

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__)
 for name in ['binary','database','reranker','resources','suite','output']:p.add_argument('--'+name,required=True)
 p.add_argument('--modes',default='legacy,passages,direct-passages');p.add_argument('--splits',default='development,regression')
 p.add_argument('--limit',type=int);p.add_argument('--ids');p.add_argument('--answers',action='store_true')
 p.add_argument('--model-dir');p.add_argument('--model-id');p.add_argument('--server',default='http://127.0.0.1:1234')
 main(p.parse_args())
