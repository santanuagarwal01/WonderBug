import json,tempfile,unittest
from pathlib import Path
from summarize_evaluation import summarize

class EvaluationTests(unittest.TestCase):
 def test_unreviewed_is_never_correct(self):
  with tempfile.TemporaryDirectory()as folder:
   path=Path(folder)/'run.jsonl'
   row={'id':'q','mode':'direct-passages','decision':'answered','generated_answer':'Yes, penguins fly.',
        'expected_behavior':'answer_from_evidence','word_overlap_score':1.0}
   path.write_text(json.dumps(row)+'\n')
   _,report=summarize([path],[])
   self.assertEqual(report['direct-passages']['reviewed_cases'],0)
   self.assertEqual(report['direct-passages']['unreviewed_generated_answers'],1)
   _,report=summarize([path],[{'id':'q','mode':'direct-passages','assessment':'incorrect'}])
   self.assertEqual(report['direct-passages']['reviewed_answer_assessments'],{'incorrect':1})
   with self.assertRaises(ValueError):summarize([path,path],[])
   with self.assertRaises(ValueError):summarize([path],[{'id':'q','mode':'direct-passages','assessment':'correct','answer_sha256':'wrong-run'}])
 def test_frozen_suite_has_no_source_leakage(self):
  suite=Path(__file__).parent/'evaluation/suite.jsonl'
  rows=[json.loads(l)for l in suite.read_text().splitlines()]
  self.assertEqual(len(rows),300);self.assertEqual(len({r['id']for r in rows}),300)
  for r in rows:
   if r.get('gold'):self.assertIn(r['gold']['support_span'],r['gold']['text'])
  dev={r['gold']['source_id'].split(':p:')[0].split(':lead')[0]for r in rows if r.get('gold')and r['split']!='heldout'}
  test={r['gold']['source_id'].split(':p:')[0].split(':lead')[0]for r in rows if r.get('gold')and r['split']=='heldout'}
  self.assertFalse(dev&test)
if __name__=='__main__':unittest.main()
