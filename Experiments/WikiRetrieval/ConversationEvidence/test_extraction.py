import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from extract_evidence import extract, plain
from build_corpus import build
from export_runtime import export

class ExtractionTests(unittest.TestCase):
    def texts(self,raw,**kwargs):
        return '\n'.join(b.text for b in extract(raw,'Example','',**kwargs))
    def test_infobox_preserves_relationship_and_discards_layout(self):
        result=self.texts('{{Infobox person|spouse=[[Alex Example]]<br>(m. 1990)|image=photo.jpg|image_size=200|birth_date={{birth date|1970|2|3}}}}')
        self.assertIn('spouse: Alex Example (m. 1990)',result)
        self.assertNotIn('photo.jpg',result)
        self.assertNotIn('200',result)
    def test_complete_labelled_list_and_negation_survive(self):
        raw="== Stages ==\n* A ''first stage'' starts the process.\n* The ''second stage'' does not happen in winter."
        result=self.texts(raw)
        self.assertIn('first stage; second stage',result)
        self.assertIn('does not happen in winter',result)
    def test_nested_list_retains_parent(self):
        result=self.texts('== Animals ==\n* Mammals\n** [[Whale]] – An animal that breathes air.\n* Birds\n** [[Duck]] – A bird.')
        self.assertIn('Mammals: Whale',result)
        self.assertIn('Birds: Duck',result)
    def test_table_retains_headers(self):
        result=self.texts('== Measurements ==\n{| class="wikitable"\n! Name !! Mass (kg)\n|-\n| Alpha || 23.5\n|-\n| Beta || 6.2\n|}')
        self.assertIn('Name: Alpha; Mass (kg): 23.5',result)
        self.assertIn('Name: Beta; Mass (kg): 6.2',result)
    def test_merged_table_is_not_guessed(self):
        result=self.texts('{|\n! Name !! Mass\n|-\n| rowspan="2" | Alpha || 23.5\n|}')
        self.assertNotIn('23.5',result)
    def test_references_and_subsections_excluded(self):
        result=self.texts('== Life ==\nThis is a short factual statement.\n== References ==\n* [[Unrelated]]\n=== Sources ===\nDo not index this citation.\n== Diet ==\nIt eats leaves from trees.')
        self.assertNotIn('Unrelated',result);self.assertNotIn('citation',result)
        self.assertIn('eats leaves',result)
    def test_short_facts_survive_and_numbers_do_not_break(self):
        result=self.texts('== Size ==\nIt is 2.5 metres long.\n\nIt has eight legs.')
        self.assertIn('2.5 metres',result)
    def test_budget_is_hard_bound_and_does_not_cut_sentences(self):
        raw='== Facts ==\n'+('\n\n'.join('A different fact number %s is complete.'%i for i in range(50)))
        blocks=extract(raw,'Example','',budget=200)
        self.assertLessEqual(sum(len(b.text) for b in blocks),200)
        self.assertTrue(all(b.text.endswith('.') for b in blocks))
    def test_measurements_and_unknown_templates(self):
        self.assertEqual(plain('{{convert|25|km|mi}}'),'25 kilometres')
        self.assertEqual(plain('{{unrecognized|invented answer}}'),'')
    def test_no_duplicate_lead(self):
        self.assertEqual(extract('This is the complete introduction.','Example','This is the complete introduction.'),[])
    def test_rebuild_is_separate_searchable_and_refuses_clobber(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);source=p/'source.db';output=p/'new.db';dump=p/'dump.xml'
            db=sqlite3.connect(source)
            db.executescript("CREATE TABLE articles(id INTEGER PRIMARY KEY,title TEXT,lead TEXT); CREATE TABLE redirects(title_lower TEXT PRIMARY KEY,target TEXT); CREATE TABLE paragraphs(article INTEGER,ord INTEGER,section TEXT,text TEXT); INSERT INTO articles VALUES(1,'Example','Example is an article.'); INSERT INTO paragraphs VALUES(1,0,'Life','Original body.');")
            db.commit();db.close();before=source.read_bytes()
            dump.write_text('<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.11/"><page><title>Example</title><ns>0</ns><id>1</id><revision><id>55</id><text>{{Infobox person|spouse=[[Alex Example]]}}\nExample is an article.</text></revision></page></mediawiki>')
            manifest=build(source,dump,output)
            self.assertEqual(source.read_bytes(),before)
            with sqlite3.connect(output) as c:
                self.assertEqual(c.execute("SELECT count(*) FROM passage_fts WHERE passage_fts MATCH 'Alex'").fetchone()[0],1)
                self.assertEqual(c.execute('SELECT revision FROM evidence_provenance').fetchone()[0],'55')
            with self.assertRaises(ValueError):build(source,dump,source)
            with self.assertRaises(ValueError):build(source,dump,output)
            link=p/'link.db';link.symlink_to(p/'missing.db')
            with self.assertRaises(ValueError):build(source,dump,link)
            runtime=p/'runtime.db';audit_before=output.read_bytes()
            runtime_manifest=export(output,runtime)
            self.assertEqual(output.read_bytes(),audit_before)
            self.assertGreater(runtime_manifest['passages_verified_identical'],0)
            with sqlite3.connect(runtime) as c:
                self.assertEqual(c.execute("SELECT count(*) FROM sqlite_master WHERE name='evidence_provenance'").fetchone()[0],0)
                self.assertEqual(c.execute("SELECT count(*) FROM passage_fts WHERE passage_fts MATCH 'Alex'").fetchone()[0],1)
            with self.assertRaises(ValueError):export(output,output)

if __name__=='__main__':unittest.main()
