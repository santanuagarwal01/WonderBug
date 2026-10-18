import sqlite3,tempfile,unittest
from pathlib import Path
from build_passage_index import build,digest

class IndexTests(unittest.TestCase):
 def test_body_only_stable_sources_and_readonly_input(self):
  with tempfile.TemporaryDirectory()as folder:
   src=Path(folder)/'source.db';out=Path(folder)/'index.db'
   with sqlite3.connect(src)as db:
    db.executescript("CREATE TABLE articles(id INTEGER PRIMARY KEY,title TEXT,lead TEXT); CREATE TABLE paragraphs(article INTEGER,ord INTEGER,section TEXT,text TEXT); INSERT INTO articles VALUES(7,'Arachnid','Eight-legged animals.'); INSERT INTO paragraphs VALUES(7,3,'Physiology','A book lung exchanges gas with the air.');")
   before=digest(src);report=build(src,out)
   self.assertEqual(before,digest(src));self.assertEqual(report['passages'],'2')
   with sqlite3.connect(out)as db:
    self.assertEqual(db.execute("SELECT source_id FROM passage_documents JOIN passage_fts ON passage_documents.id=passage_fts.rowid WHERE passage_fts MATCH 'lung'").fetchone()[0],'a:7:p:3')
    self.assertEqual(db.execute('SELECT count(*) FROM articles').fetchone()[0],1)
   with self.assertRaises(ValueError):build(src,src)
   with self.assertRaises(ValueError):build(src,out)
   alias=Path(folder)/'alias.db';alias.symlink_to(src)
   with self.assertRaises(ValueError):build(src,alias)
   self.assertEqual(before,digest(src))
if __name__=='__main__':unittest.main()
