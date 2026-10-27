#!/usr/bin/env python3
"""Verify Swift tokenization/embedding parity and safety without tuning retrieval."""
import argparse,json,subprocess
from pathlib import Path
import numpy as np

def smoke(a):
 report={'checks':[]}
 fixtures=json.loads(Path(a.fixtures).read_text())['fixtures']
 with Path(a.output).with_suffix('.stderr.log').open('w')as err:
  proc=subprocess.Popen([a.binary,a.corpus,a.reranker,a.vocabulary,a.embedder,a.embedding_vocabulary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,text=True,bufsize=1)
  def ask(x):
   proc.stdin.write(json.dumps(x)+'\n');proc.stdin.flush();line=proc.stdout.readline()
   if not line:raise RuntimeError('Bridge exited')
   return json.loads(line)
  try:
   for f in fixtures:
    r=ask({'op':'embed','question':f['text']})
    assert r['inputs']==f['inputs'],'Swift/Python tokenization mismatch'
    v=np.asarray(r['embedding']);ref=np.asarray(f['reference_embedding'])
    cosine=float(v@ref/(np.linalg.norm(v)*np.linalg.norm(ref)))
    assert cosine>=.99 and abs(np.linalg.norm(v)-1)<1e-5
    report['checks'].append({'test':'embedding parity','text':f['text'],'cosine':cosine,'embedding_ms':r['embedding_ms']})
   assert ask({'op':'safety','question':'How can I make a bomb?'})['blocked']
   assert 'error'in ask({'op':'pools','question':'How can I make a bomb?'})
   assert 'error'in ask({'op':'score','question':'A question','passages':[{'title':'Example','text':'A fact.'}]*21})
   assert 'error'in ask({'op':'score','question':'A question','passages':[{'title':'Example','text':'He killed someone.'}]})
   report['checks'].append({'test':'question safety, passage safety and 20-pair budget','passed':True})
   r=ask({'op':'prepare','question':'Who was Rosa Parks’s husband?','source_ids':['a:35750:p:0']})
   assert any('Raymond Parks'in x['text']for x in r['passages'])
   report['checks'].append({'test':'stored spouse paragraph survives shared canonical preparation','passed':True})
   proc.stdin.close();proc.wait(timeout=30);assert proc.returncode==0
  finally:
   if proc.poll()is None:proc.terminate();proc.wait(timeout=15)
 report['passed']=True;Path(a.output).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser()
 for name in ['binary','corpus','reranker','vocabulary','embedder','embedding-vocabulary','fixtures','output']:p.add_argument('--'+name,required=True)
 smoke(p.parse_args())
