#!/usr/bin/env python3
"""Run three frozen retrieval arms with unchanged Swift MiniLM and safety checks."""
import argparse,hashlib,json,resource,sqlite3,subprocess,time
import numpy as np
from pathlib import Path
from embedding import model_identity,digest
from build_index import connect
from fusion import shortlist,unique
ARMS=['bm25-fusion','vec-float-fusion','vec-binary-fusion']

def package_digest(path):
 p=Path(path);h=hashlib.sha256()
 for f in sorted(x for x in p.rglob('*')if x.is_file()):h.update(str(f.relative_to(p)).encode());h.update(digest(f).encode())
 return h.hexdigest()

class Bridge:
 def __init__(self,binary,corpus,reranker,vocabulary,coreml_embedder,embedding_vocabulary,stderr):
  self.proc=subprocess.Popen([binary,corpus,reranker,vocabulary,coreml_embedder,embedding_vocabulary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,text=True,bufsize=1)
 def ask(self,**request):
  self.proc.stdin.write(json.dumps(request)+'\n');self.proc.stdin.flush()
  line=self.proc.stdout.readline()
  if not line:raise RuntimeError('Swift bridge exited; inspect stderr')
  out=json.loads(line)
  if 'error'in out:raise RuntimeError(out['error'])
  return out
 def close(self):
  if self.proc.poll()is None:
   self.proc.stdin.close();self.proc.wait(timeout=30)
  if self.proc.returncode:raise RuntimeError('Swift bridge failed')

def vector_hits(db,kind,vector,count):
 table='vectors_float' if kind=='float' else 'vectors_binary'
 expression='?' if kind=='float' else 'vec_quantize_binary(?)'
 query=f'SELECT rowid,distance FROM {table} WHERE embedding MATCH {expression} AND k=? ORDER BY distance'
 return sorted(db.execute(query,(vector.tobytes(),count)).fetchall(),key=lambda r:(r[1],r[0]))

def validate_index(db,identity,corpus_hash):
 metadata=dict(db.execute('select key,value from metadata'))
 if metadata.get('complete')!='true':raise ValueError('Incomplete vector index')
 saved=json.loads(metadata['identity'])
 if saved['corpus_sha256']!=corpus_hash or saved['embedder']!=identity:raise ValueError('Wrong corpus/model/tokenizer for index')
 return saved

def run(a):
 output=Path(a.output)
 if output.exists():raise ValueError('Use a new output path')
 protocol=json.loads(Path(a.protocol).read_text());corpus_hash=digest(a.corpus)
 if corpus_hash!=protocol['corpus_sha256']or digest(a.suite)!=protocol['suite_sha256']:raise ValueError('Frozen inputs mismatch')
 cases=[json.loads(l)for l in Path(a.suite).read_text().splitlines()]
 if len(cases)!=75 or len({r['id']for r in cases})!=75:raise ValueError('Incomplete/duplicate suite')
 encoder_identity=model_identity(a.model)
 with connect(a.float_index,True)as floats,connect(a.binary_index,True)as bits,sqlite3.connect(Path(a.corpus).resolve().as_uri()+'?mode=ro',uri=True)as corpus:
  index_identity=validate_index(floats,encoder_identity,corpus_hash);validate_index(bits,encoder_identity,corpus_hash)
  # SQLite integer IDs are meaningful only for the hashed corpus version.
  source_ids=dict(corpus.execute('select id,source_id from passage_map'))
  manifest={'protocol_sha256':digest(a.protocol),'suite_sha256':digest(a.suite),'corpus_sha256':corpus_hash,
    'float_index_sha256':digest(a.float_index),'binary_index_sha256':digest(a.binary_index),'embedder':encoder_identity,
    'reranker_sha256':package_digest(a.reranker),'bridge_sha256':digest(a.binary),'vocabulary_sha256':digest(a.vocabulary),'query_encoder':'Swift Core ML, int8-compressed weights, float16 compute','coreml_embedder_sha256':package_digest(a.coreml_embedder),'embedding_vocabulary_sha256':digest(a.embedding_vocabulary),'cases':len(cases),
    'arms':ARMS,'question_modes':['original','reviewed-complete'],'gate':4.0,'reranker_limit':20,'generation':False,
    'performance_note':'Mac only. Embedding shared between retrieval arms of one query; component times are explicit. Corpus/index/model loading excluded from query timings.',
    'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
  output.parent.mkdir(parents=True,exist_ok=True);stderr=output.with_suffix('.stderr.log').open('x')
  bridge=Bridge(a.binary,a.corpus,a.reranker,a.vocabulary,a.coreml_embedder,a.embedding_vocabulary,stderr);started=time.monotonic();count=0
  try:
   actual=bridge.ask(op='identity',question='')['embedder']
   if actual.get('source')!=encoder_identity['model'] or actual.get('revision')!=encoder_identity['revision'] or actual.get('source_weights_sha256')!=encoder_identity['weights_sha256']:raise ValueError('Core ML encoder does not match indexed model')
   if digest(a.embedding_vocabulary)!=digest(Path(a.model)/'vocab.txt'):raise ValueError('Core ML vocabulary mismatch')
   manifest['coreml_encoder_identity']=actual
   with output.open('x')as f:
    pending={};episode=None
    for case_index,case in enumerate(cases):
     if case['conversation_id']!=episode:episode=case['conversation_id'];pending={}
     for mode in ['original','reviewed-complete']:
      question=case['question'];resolved=case['resolved_question'] if mode=='reviewed-complete' else question
      row={k:case[k]for k in ['id','split','conversation_id','turn','category','expected_behavior']}
      row.update({'question':question,'retrieval_question':resolved,'question_mode':mode})
      safety=bridge.ask(op='safety',question=question)
      blocked=safety['blocked']or(pending.get(mode,False)and safety['bare_followup'])
      if resolved and not blocked:blocked=bridge.ask(op='safety',question=resolved)['blocked']
      pending[mode]=blocked
      if blocked or not resolved:
       for arm in ARMS:
        f.write(json.dumps({**row,'arm':arm,'decision':'question_blocked'if blocked else 'oracle_unresolved','candidates':[]})+'\n');count+=1
       continue
      t=time.monotonic();pools=bridge.ask(op='pools',question=resolved)['pools'];lexical_ms=(time.monotonic()-t)*1000
      encoded=bridge.ask(op='embed',question=resolved);vector=np.asarray(encoded['embedding'],dtype='<f4');embedding_ms=encoded['embedding_ms']
      t=time.monotonic();float_hits=vector_hits(floats,'float',vector,48);float_ms=(time.monotonic()-t)*1000
      t=time.monotonic();bit_hits=vector_hits(bits,'binary',vector,48);binary_ms=(time.monotonic()-t)*1000
      ranks={'article':unique(r['sourceID']for r in pools['article']if r.get('sourceID')),
         'body':unique(r['sourceID']for r in pools['body']if r.get('sourceID')),
         'float':[source_ids[i]for i,_ in float_hits],'binary':[source_ids[i]for i,_ in bit_hits]}
      ids=unique(s for values in ranks.values()for s in values)
      t=time.monotonic();prepared=bridge.ask(op='prepare',question=resolved,source_ids=ids)['passages'];prepare_ms=(time.monotonic()-t)*1000
      canonical={}
      for r in prepared:canonical.setdefault(r['sourceID'],r)
      # Canonical rendering depends only on question/source, never on retrieval method or score.
      for arm,kind in [('bm25-fusion',None),('vec-float-fusion','float'),('vec-binary-fusion','binary')]:
       selected,scores,lexical=shortlist(ranks['article'],ranks['body'],ranks[kind]if kind else None,canonical)
       result=bridge.ask(op='score',question=resolved,passages=[canonical[i]for i in selected])
       result.update(row);result['arm']=arm
       result.update({'raw_source_ranks':ranks,'fused_source_ids':selected,'fusion_scores':scores,'lexical_fused_ranking':lexical,
         'prepared_source_ids':list(canonical),'lexical_ms':lexical_ms,'embedding_ms':embedding_ms if kind else 0,
         'vector_search_ms':(float_ms if kind=='float' else binary_ms)if kind else 0,'prepare_union_ms':prepare_ms,
         'float_binary_top48_overlap':len(set(ranks['float'])&set(ranks['binary']))})
       f.write(json.dumps(result,ensure_ascii=False)+'\n');count+=1
      f.flush()
     if (case_index+1)%10==0:print(f'{case_index+1}/{len(cases)} cases, {count} records',flush=True)
   bridge.close();manifest.update({'complete':True,'records':count,'output_sha256':digest(output)})
   assert count==450
  finally:
   if bridge.proc.poll()is None:bridge.proc.terminate();bridge.proc.wait(timeout=15)
   stderr.close();manifest['seconds']=round(time.monotonic()-started,2)
   manifest['python_peak_rss_bytes']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
   manifest['swift_peak_rss_bytes']=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
   output.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
  print(json.dumps(manifest,indent=2))

if __name__=='__main__':
 p=argparse.ArgumentParser()
 for name in ['binary','corpus','reranker','vocabulary','model','coreml-embedder','embedding-vocabulary','float-index','binary-index','suite','protocol','output']:p.add_argument('--'+name,required=True)
 run(p.parse_args())
