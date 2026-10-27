#!/usr/bin/env python3
"""Build resumable full-corpus sqlite-vec indexes; never reads evaluation questions."""
import argparse,json,os,sqlite3,time
from pathlib import Path
import sqlite_vec
from embedding import Embedder,digest,document_text

def connect(path,readonly=False):
 db=sqlite3.connect(Path(path).resolve().as_uri()+('?mode=ro' if readonly else '?mode=rwc'),uri=True)
 db.enable_load_extension(True);sqlite_vec.load(db);db.enable_load_extension(False)
 return db

def build(a):
 out=Path(a.output).absolute();source=Path(a.corpus).resolve()
 if out.is_symlink()or out.resolve()==source:raise ValueError('Separate regular index output required')
 out.parent.mkdir(parents=True,exist_ok=True)
 embed=Embedder(a.model,a.device);started=time.monotonic()
 with sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)as src,connect(out)as db:
  identity={'corpus_sha256':digest(source),'embedder':embed.identity,'document_format':'title + optional section + newline + whole paragraph (tokenizer truncates to 256)','sqlite_vec':db.execute('select vec_version()').fetchone()[0]}
  existing=db.execute("select count(*)from sqlite_master where name='metadata'").fetchone()[0]
  if existing:
   saved=json.loads(db.execute("select value from metadata where key='identity'").fetchone()[0])
   if saved!=identity:raise ValueError('Resume identity mismatch')
   if db.execute("select value from metadata where key='complete'").fetchone()[0]=='true':raise ValueError('Already complete; refusing overwrite')
  else:
   if db.execute("select count(*)from sqlite_master").fetchone()[0]:raise ValueError('Unknown existing DB')
   db.executescript('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE VIRTUAL TABLE vectors_float USING vec0(embedding float[384] distance_metric=cosine); CREATE VIRTUAL TABLE vectors_binary USING vec0(embedding bit[384]);')
   db.executemany('insert into metadata values(?,?)',[('identity',json.dumps(identity,sort_keys=True)),('complete','false'),('last_id','0')]);db.commit()
  last=int(db.execute("select value from metadata where key='last_id'").fetchone()[0]);done=db.execute('select count(*)from vectors_float').fetchone()[0]
  count=src.execute('select count(*)from passage_documents').fetchone()[0]
  print(json.dumps({'device':embed.device,'resume_after':last,'done':done,'total':count}),flush=True)
  cursor=src.execute('select id,title,section,text from passage_documents where id>? order by id',(last,))
  initial=done;last_report=time.monotonic()
  while batch:=cursor.fetchmany(a.batch_size):
   vectors=embed.encode([document_text(t,s,x)for _,t,s,x in batch])
   for (identifier,_,_,_),vector in zip(batch,vectors):
    blob=vector.tobytes()
    db.execute('insert into vectors_float(rowid,embedding)values(?,?)',(identifier,blob))
    db.execute('insert into vectors_binary(rowid,embedding)values(?,vec_quantize_binary(?))',(identifier,blob))
   done+=len(batch);db.execute("update metadata set value=?where key='last_id'",(str(batch[-1][0]),));db.commit()
   if time.monotonic()-last_report>=20:
    elapsed=time.monotonic()-started;print(json.dumps({'done':done,'total':count,'seconds':round(elapsed,1),'passages_per_second':round((done-initial)/elapsed,1)}),flush=True);last_report=time.monotonic()
  assert done==count
  assert db.execute('select count(*)from vectors_binary').fetchone()[0]==count
  db.execute("update metadata set value='true'where key='complete'");db.commit()
  if db.execute('pragma integrity_check').fetchone()[0]!='ok':raise ValueError('SQLite integrity failed')
  manifest={**identity,'complete':True,'passages':count,'batch_size':a.batch_size,'device':embed.device,'seconds_this_run':round(time.monotonic()-started,2),'output_bytes':out.stat().st_size,'output_sha256':digest(out)}
  out.with_suffix('.manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
  print(json.dumps(manifest,indent=2),flush=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--corpus',required=True);p.add_argument('--model',required=True);p.add_argument('--output',required=True);p.add_argument('--device',default='auto');p.add_argument('--batch-size',type=int,default=128);build(p.parse_args())
