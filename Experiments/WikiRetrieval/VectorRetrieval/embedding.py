"""Pinned local sentence embedding; corpus and query use the same normalization."""
from pathlib import Path
import hashlib
import numpy as np
from download_model import MODEL,REVISION
DIMENSIONS=384
MAX_TOKENS=256

def digest(path):
 h=hashlib.sha256()
 with Path(path).open('rb')as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()

def model_identity(path):
 path=Path(path)
 return {'model':MODEL,'revision':REVISION,'weights_sha256':digest(path/'model.safetensors'),'tokenizer_sha256':digest(path/'tokenizer.json'),'dimensions':DIMENSIONS,'max_tokens':MAX_TOKENS,'pooling':'attention-masked mean followed by L2 normalization'}

class Embedder:
 def __init__(self,path,device='auto'):
  import torch
  from transformers import AutoModel,AutoTokenizer
  self.path=Path(path)
  self.device=('mps' if torch.backends.mps.is_available() else 'cpu') if device=='auto' else device
  torch.set_num_threads(4)
  self.tokenizer=AutoTokenizer.from_pretrained(path,local_files_only=True)
  self.model=AutoModel.from_pretrained(path,local_files_only=True,attn_implementation='sdpa').eval().to(self.device)
  self.identity=model_identity(self.path)
 def encode(self,texts):
  import torch
  values=self.tokenizer(texts,padding=True,truncation=True,max_length=MAX_TOKENS,return_tensors='pt').to(self.device)
  with torch.inference_mode():
   hidden=self.model(**values).last_hidden_state
   mask=values['attention_mask'].unsqueeze(-1)
   pooled=(hidden*mask).sum(1)/mask.sum(1).clamp(min=1)
   vectors=torch.nn.functional.normalize(pooled,p=2,dim=1).cpu().numpy().astype('<f4')
  if not np.isfinite(vectors).all():raise ValueError('Non-finite embedding')
  return vectors

def document_text(title,section,text):
 return title+(': '+section if section else '')+'\n'+text
