#!/usr/bin/env python3
"""Small local adaptation pilot of the EXISTING MiniLM. Qwen is never loaded.
Uses reviewed pair labels; missing gold spans are not automatically negatives.
"""
import argparse, hashlib, json, random
from pathlib import Path
import numpy as np
import torch
from transformers import AutoTokenizer, AutoModelForSequenceClassification

def digest(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def encode(tokenizer, q, text):
 q=tokenizer.encode(q,add_special_tokens=False)[:48]
 p=tokenizer.encode(text,add_special_tokens=False)[:256-len(q)-3]
 ids=[101]+q+[102]+p+[102]; pad=[0]*(256-len(ids))
 return dict(input_ids=ids+pad,attention_mask=[1]*len(ids)+pad,token_type_ids=[0]*(len(q)+2)+[1]*(len(p)+1)+pad)
def batch(tokenizer, rows, device):
 arrays=[encode(tokenizer,r['question'],r['text'])for r in rows]
 return {k:torch.tensor([a[k]for a in arrays],dtype=torch.long,device=device)for k in arrays[0]}
def score(model,tokenizer,rows,device,size=16):
 model.eval();scores=[]
 with torch.no_grad():
  for i in range(0,len(rows),size):scores.extend(model(**batch(tokenizer,rows[i:i+size],device)).logits[:,0].cpu().tolist())
 return scores

def main(a):
 torch.manual_seed(20261018);np.random.seed(20261018);random.seed(20261018);torch.set_num_threads(4)
 out=Path(a.output);out.mkdir(exist_ok=False,parents=True)
 data=[json.loads(l)for l in Path(a.data).read_text().splitlines()]
 splits=json.loads(Path(a.splits).read_text())
 # Four question topics are reserved for model selection; they never enter optimizer batches.
 fitting=[r for r in data if splits['topics'].get(r['topic'],splits['cases'].get(r['id']))=='train']
 validation=[r for r in data if splits['topics'].get(r['topic'])=='model-selection']
 assert fitting and validation and not {r['id']for r in fitting}&{r['id']for r in validation}
 device='mps'if torch.backends.mps.is_available()else'cpu'
 tokenizer=AutoTokenizer.from_pretrained(a.source,local_files_only=True)
 model=AutoModelForSequenceClassification.from_pretrained(a.source,local_files_only=True,attn_implementation='eager').to(device)
 opt=torch.optim.AdamW(model.parameters(),lr=1e-5,weight_decay=.01)
 counts={y:sum(r['label']==y for r in fitting)for y in [0,1]}
 weights={y:len(fitting)/(2*counts[y])for y in counts}
 manifest={'seed':20261018,'source':str(Path(a.source).resolve()),'source_weights_sha256':digest(Path(a.source)/'model.safetensors'),
  'training_sha256':digest(a.data),'splits_sha256':digest(a.splits),'fit_pairs':len(fitting),'model_selection_pairs':len(validation),
  'device':device,'lr':1e-5,'epochs':3,'batch_size':8,'sequence_length':256,'query_tokens':48,
  'objective':'class-balanced binary cross entropy on reviewed support labels','architecture':'unchanged MiniLM-L6; no Qwen work'}
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 history=[]
 for epoch in range(4):
  if epoch:
   model.train();order=list(range(len(fitting)));random.shuffle(order);losses=[]
   for start in range(0,len(order),8):
    rows=[fitting[i]for i in order[start:start+8]]
    logits=model(**batch(tokenizer,rows,device)).logits[:,0]
    labels=torch.tensor([r['label']for r in rows],dtype=torch.float32,device=device)
    w=torch.tensor([weights[r['label']]for r in rows],device=device)
    loss=(torch.nn.functional.binary_cross_entropy_with_logits(logits,labels,reduction='none')*w).mean()
    opt.zero_grad();loss.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),1.0);opt.step();losses.append(loss.item())
   model.save_pretrained(out/f'epoch-{epoch}');tokenizer.save_pretrained(out/f'epoch-{epoch}')
  values=score(model,tokenizer,validation,device)
  pos=[s for r,s in zip(validation,values)if r['label']];neg=[s for r,s in zip(validation,values)if not r['label']]
  auc=sum((p>n)+.5*(p==n)for p in pos for n in neg)/(len(pos)*len(neg))if pos and neg else None
  balanced_loss=sum(float(np.logaddexp(0,-s))for s in pos)/len(pos)/2+sum(float(np.logaddexp(0,s))for s in neg)/len(neg)/2
  record={'epoch':epoch,'model_selection_auc':auc,'model_selection_balanced_loss':balanced_loss,'pair_scores':values}
  history.append(record);(out/'history.json').write_text(json.dumps(history,indent=2)+'\n');print({k:v for k,v in record.items()if k!='pair_scores'},flush=True)
 # Rank discrimination is the primary selection criterion; loss breaks ties. Baseline can win.
 best=max(history,key=lambda r:(r['model_selection_auc'],-r['model_selection_balanced_loss'],-r['epoch']))
 (out/'selected.json').write_text(json.dumps({'epoch':best['epoch'],'selection':'maximum model-selection pair AUC, then balanced loss; no calibration/validation labels used'},indent=2)+'\n')
 print('SELECTED',best['epoch'],flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__)
 for n in ['source','data','splits','output']:p.add_argument('--'+n,required=True)
 main(p.parse_args())
