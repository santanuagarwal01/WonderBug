#!/usr/bin/env python3
"""Check that identical-text source IDs cannot suppress each other across retrieval arms."""
import argparse,json,sqlite3,tempfile
from pathlib import Path
from run_comparison import Bridge
from embedding import digest

def check(a):
 with tempfile.TemporaryDirectory(prefix='vector-isolation-')as d:
  p=Path(d);corpus=p/'fixture.db'
  text=' '.join(['This example concerns a generic topic with several ordinary factual details']*5)+'.'
  with sqlite3.connect(corpus)as db:
   db.executescript("CREATE TABLE articles(id INTEGER PRIMARY KEY,title TEXT,lead TEXT); CREATE TABLE paragraphs(article INTEGER,ord INTEGER,section TEXT,text TEXT);CREATE TABLE passage_index_metadata(key TEXT,value TEXT); INSERT INTO passage_index_metadata VALUES('schema_version','1');CREATE TABLE passage_documents(id INTEGER,source_id TEXT,article INTEGER,ordinal INTEGER,title TEXT,section TEXT,text TEXT);INSERT INTO articles VALUES(1,'Example','Example is a topic.');")
   for i in range(2):
    db.execute('insert into paragraphs values(1,?,?,?)',(i,'Facts',text))
    db.execute('insert into passage_documents values(?,?,1,?,?,?,?)',(i+1,f'a:1:p:{i}',i,'Example','Facts',text))
  with (p/'stderr.log').open('w')as stderr:
   bridge=Bridge(a.binary,str(corpus),a.reranker,a.vocabulary,a.embedder,a.embedding_vocabulary,stderr)
   try:
    def prepare(ids):return {r['sourceID']:r['text']for r in bridge.ask(op='prepare',question='What is this example topic?',source_ids=ids)['passages']}
    left=prepare(['a:1:p:0','a:1:p:1']);right=prepare(['a:1:p:1','a:1:p:0'])
    assert len(left)==2 and left==right and len(set(left.values()))==1
    bridge.close()
   finally:
    if bridge.proc.poll()is None:bridge.proc.terminate();bridge.proc.wait(timeout=15)
  report={'passed':True,'check':'Identical text on distinct source IDs survives either request ordering; candidate preparation cannot leak one arm into another.','binary_sha256':digest(a.binary)}
  Path(a.output).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
if __name__=='__main__':
 p=argparse.ArgumentParser()
 for name in ['binary','reranker','vocabulary','embedder','embedding-vocabulary','output']:p.add_argument('--'+name,required=True)
 check(p.parse_args())
