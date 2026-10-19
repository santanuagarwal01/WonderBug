#!/usr/bin/env python3
"""Replay fixed candidates through a checkpoint; does not change retrieval or Qwen."""
import argparse,json
from pathlib import Path
import torch
from transformers import AutoTokenizer,AutoModelForSequenceClassification
from train_reranker import score,digest
p=argparse.ArgumentParser()
for n in ['source','input','output']:p.add_argument('--'+n,required=True)
a=p.parse_args();out=Path(a.output)
if out.exists():raise ValueError('Use a new output')
torch.set_num_threads(4);device='mps'if torch.backends.mps.is_available()else'cpu'
tok=AutoTokenizer.from_pretrained(a.source,local_files_only=True)
model=AutoModelForSequenceClassification.from_pretrained(a.source,local_files_only=True,attn_implementation='eager').to(device)
rows=[json.loads(l)for l in Path(a.input).read_text().splitlines()]
pairs=[dict(question=r['question'],text=c['text'])for r in rows for c in r.get('trace',{}).get('candidates',[])]
scores=iter(score(model,tok,pairs,device));results=[]
for r in rows:
 for c in r.get('trace',{}).get('candidates',[]):c['relevance']=next(scores)
 r['scoring_checkpoint']=str(Path(a.source).resolve());results.append(r)
out.write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n'for r in results))
out.with_suffix('.manifest.json').write_text(json.dumps({'input_sha256':digest(a.input),'weights_sha256':digest(Path(a.source)/'model.safetensors'),'runtime':'PyTorch float32; CoreML parity must be checked before deployment'},indent=2)+'\n')
print('Scored',len(pairs),'pairs')
