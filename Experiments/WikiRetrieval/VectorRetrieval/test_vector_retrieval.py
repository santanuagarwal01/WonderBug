import json,sqlite3,tempfile,unittest
from pathlib import Path
import numpy as np
from build_index import connect
from export_index import export
from fusion import rank_fusion,shortlist
from run_comparison import vector_hits,validate_index
from embedding import digest,document_text

class FusionTests(unittest.TestCase):
 def test_duplicate_windows_cannot_multiply_source_vote(self):
  a=rank_fusion([['a','a','a','b'],['b']],{'a','b'})
  b=rank_fusion([['a','b'],['b']],{'a','b'})
  self.assertEqual(a,b);self.assertEqual(a[0][0],'b')
 def test_dense_can_promote_passage_outside_keyword_top20(self):
  ids=[f'p{i:02}'for i in range(48)];available=set(ids)
  old,_,_=shortlist(ids,ids,None,available)
  new,_,_=shortlist(ids,ids,[ids[21]],available)
  self.assertNotIn(ids[21],old);self.assertIn(ids[21],new);self.assertEqual(len(new),20)
 def test_budget_and_deterministic_ties(self):
  ids=[f'p{i:02}'for i in range(60)]
  first=shortlist(ids,ids[::-1],ids[20:],set(ids))
  self.assertEqual(first,shortlist(ids,ids[::-1],ids[20:],set(ids)))
  self.assertEqual(len(first[0]),20);self.assertEqual(len(set(first[0])),20)
  with self.assertRaises(ValueError):shortlist(ids,ids,None,set(ids),limit=21)
 def test_unavailable_sources_are_never_admitted(self):
  ids,_,_=shortlist(['unsafe','valid'],['unsafe'],['unsafe'],{'valid'})
  self.assertEqual(ids,['valid'])
 def test_identical_text_cannot_spend_two_reranker_slots(self):
  available={'a':{'text':'A fact.'},'b':{'text':'A  fact.'},'c':{'text':'Another fact.'}}
  selected,_,_=shortlist(['a','b','c'],[],None,available)
  self.assertEqual(selected,['a','c'])
 def test_empty_pool_and_lexical_fallback(self):
  self.assertEqual(shortlist([],[],[],set())[0],[])
  self.assertEqual(shortlist(['a'],[],None,{'a'})[0],['a'])

class SQLiteVecTests(unittest.TestCase):
 def test_real_knn_and_binary_export(self):
  with tempfile.TemporaryDirectory()as d:
   p=Path(d);source=p/'index.db';out=p/'binary.db'
   v=np.ones(384,dtype='<f4');v/=np.linalg.norm(v)
   with connect(source)as db:
    db.executescript('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);CREATE VIRTUAL TABLE vectors_float USING vec0(embedding float[384] distance_metric=cosine);CREATE VIRTUAL TABLE vectors_binary USING vec0(embedding bit[384]);')
    db.execute("insert into metadata values('complete','true')")
    for i,x in [(1,v),(2,-v)]:
     db.execute('insert into vectors_float(rowid,embedding)values(?,?)',(i,x.tobytes()))
     db.execute('insert into vectors_binary(rowid,embedding)values(?,vec_quantize_binary(?))',(i,x.tobytes()))
    db.commit()
    self.assertEqual(vector_hits(db,'float',v,2)[0][0],1)
    self.assertEqual(vector_hits(db,'binary',v,2),[(1,0.0),(2,384.0)])
   before=digest(source);report=export(source,out,'binary')
   self.assertEqual(digest(source),before);self.assertEqual(report['vectors_verified'],2)
   with connect(out,True)as db:
    self.assertEqual(vector_hits(db,'binary',v,2)[0][0],1)
    self.assertEqual(db.execute("select count(*)from sqlite_master where name='vectors_float'").fetchone()[0],0)
   with self.assertRaises(ValueError):export(source,source,'binary')
   with self.assertRaises(ValueError):export(source,out,'binary')
 def test_index_identity_and_completeness_checked(self):
  db=sqlite3.connect(':memory:');db.execute('create table metadata(key text,value text)')
  identity={'model':'fixture'};saved={'corpus_sha256':'good','embedder':identity}
  db.executemany('insert into metadata values(?,?)',[('complete','true'),('identity',json.dumps(saved))])
  self.assertEqual(validate_index(db,identity,'good'),saved)
  with self.assertRaises(ValueError):validate_index(db,identity,'wrong')
  with self.assertRaises(ValueError):validate_index(db,{'model':'wrong'},'good')
  db.execute("update metadata set value='false'where key='complete'")
  with self.assertRaises(ValueError):validate_index(db,identity,'good')
 def test_embedding_context_retains_entity_and_heading(self):
  self.assertEqual(document_text('Person','Family','Spouse: Alex.'),'Person: Family\nSpouse: Alex.')

if __name__=='__main__':unittest.main()
