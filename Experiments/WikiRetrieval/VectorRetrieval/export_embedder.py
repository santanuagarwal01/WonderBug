#!/usr/bin/env python3
"""Convert the pinned encoder to Core ML with compressed int8 weights and verify parity."""
import argparse,json,shutil
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
from coremltools.optimize.coreml import OptimizationConfig,OpLinearQuantizerConfig,linear_quantize_weights
from transformers import AutoModel,AutoTokenizer
from download_model import MODEL,REVISION
from embedding import digest
SAMPLES=['A sample question about a waterfall.','Which material is the bridge made from?',
 'Café cats—why? 水','An unknown word: qwertyuiopasdfghjkl.','This is '+ 'very '*300+'long.']

def export(a):
 source=Path(a.model);out=Path(a.output)
 if out.exists():raise ValueError('New output directory required')
 out.mkdir(parents=True)
 torch.set_num_threads(4)
 tokenizer=AutoTokenizer.from_pretrained(source,local_files_only=True)
 base=AutoModel.from_pretrained(source,local_files_only=True,attn_implementation='eager').eval()
 class Wrapper(torch.nn.Module):
  def __init__(self):super().__init__();self.model=base
  def forward(self,input_ids,attention_mask,token_type_ids):
   hidden=self.model(input_ids=input_ids,attention_mask=attention_mask,token_type_ids=token_type_ids).last_hidden_state
   mask=attention_mask.unsqueeze(-1).to(hidden.dtype)
   mean=(hidden*mask).sum(1)/mask.sum(1).clamp(min=1)
   return torch.nn.functional.normalize(mean,p=2,dim=1)
 def encode(text):return {k:v.astype(np.int32)for k,v in tokenizer(text,padding='max_length',truncation=True,max_length=256,return_tensors='np').items()}
 sample=encode(SAMPLES[0]);wrapper=Wrapper().eval()
 with torch.no_grad():traced=torch.jit.trace(wrapper,tuple(torch.from_numpy(sample[k]).long()for k in ['input_ids','attention_mask','token_type_ids']))
 model=ct.convert(traced,convert_to='mlprogram',minimum_deployment_target=ct.target.iOS17,
  inputs=[ct.TensorType(name=k,shape=(1,256),dtype=np.int32)for k in ['input_ids','attention_mask','token_type_ids']],
  outputs=[ct.TensorType(name='embedding',dtype=np.float32)],compute_precision=ct.precision.FLOAT16)
 model=linear_quantize_weights(model,config=OptimizationConfig(global_config=OpLinearQuantizerConfig(mode='linear_symmetric',dtype='int8',granularity='per_channel')))
 model.author='Sentence Transformers; Core ML conversion for WonderBug';model.license='Apache-2.0'
 model.short_description='384-dimensional sentence embedding; masked mean pooling and L2 normalization.'
 model.user_defined_metadata.update({'source':MODEL,'revision':REVISION,'sequence_length':'256','dimensions':'384','source_weights_sha256':digest(source/'model.safetensors')})
 package=out/'WikiEmbedder.mlpackage';model.save(str(package));shutil.copyfile(source/'vocab.txt',out/'wiki-embedder-vocab.txt')
 fixtures=[]
 for text in SAMPLES:
  values=encode(text)
  with torch.no_grad():reference=wrapper(*[torch.from_numpy(values[k]).long()for k in ['input_ids','attention_mask','token_type_ids']]).numpy().reshape(-1)
  actual=model.predict(values)['embedding'].reshape(-1)
  cosine=float(np.dot(reference,actual)/(np.linalg.norm(reference)*np.linalg.norm(actual)))
  error=float(np.max(np.abs(reference-actual)))
  if not np.isfinite(actual).all()or cosine<.99:raise ValueError('Embedding conversion parity failed')
  fixtures.append({'text':text,'inputs':{k:v[0].tolist()for k,v in values.items()},'reference_embedding':reference.tolist(),'coreml_embedding':actual.tolist(),'cosine':cosine,'max_absolute_error':error})
  print('parity',cosine,error,flush=True)
 report={'model':MODEL,'revision':REVISION,'source_weights_sha256':digest(source/'model.safetensors'),'model_package_bytes':sum(p.stat().st_size for p in package.rglob('*')if p.is_file()),'weight_compression':'int8 per-channel; compute float16','fixtures':fixtures}
 (out/'embedding-parity.json').write_text(json.dumps(report,indent=2)+'\n');print('Package bytes',report['model_package_bytes'])
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--model',required=True);p.add_argument('--output',required=True);export(p.parse_args())
