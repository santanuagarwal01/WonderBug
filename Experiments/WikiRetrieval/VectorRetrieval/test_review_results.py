import json,tempfile,unittest
from pathlib import Path
from argparse import Namespace
from review_results import validated,summarize,text_hash,ARMS,MODES
from embedding import digest

class ReviewValidationTests(unittest.TestCase):
 def fixture(self,p):
  suite=p/'suite.jsonl';run=p/'run.jsonl';protocol=p/'protocol.json';reviews=p/'reviews.json'
  suite.write_text(json.dumps({'id':'fixture','question':'What is this?','resolved_question':'What is this?','expected_behavior':'answer','category':'standalone','split':'unseen'})+'\n')
  protocol.write_text('{}')
  data=[{'id':'fixture','question_mode':mode,'arm':arm,'decision':'retrieved','title':'Example','passage':'A supported definition.','candidates':[{'text':'A supported definition.'}]}for mode in MODES for arm in ARMS]
  run.write_text(''.join(json.dumps(r)+'\n'for r in data))
  run.with_suffix('.manifest.json').write_text(json.dumps({'complete':True,'output_sha256':digest(run),'suite_sha256':digest(suite),'protocol_sha256':digest(protocol)}))
  reviews.write_text(json.dumps([{'id':'fixture','passage_sha256':text_hash('A supported definition.'),'passage':'A supported definition.','review':{'support':'sufficient','note':'fixture'}}]))
  return Namespace(suite=str(suite),run=str(run),protocol=str(protocol),reviews=str(reviews),output=str(p/'summary.json'))
 def test_summary_requires_exact_evidence_review(self):
  with tempfile.TemporaryDirectory()as d:
   p=Path(d);a=self.fixture(p);summarize(a)
   report=json.loads(Path(a.output).read_text());self.assertEqual(len(report['reviewed_outputs']),6)
   values=json.loads(Path(a.reviews).read_text());values[0]['passage']='Changed evidence.';Path(a.reviews).write_text(json.dumps(values));a.output=str(p/'bad.json')
   with self.assertRaises(ValueError):summarize(a)
 def test_missing_or_changed_run_and_unreviewed_passage_rejected(self):
  with tempfile.TemporaryDirectory()as d:
   a=self.fixture(Path(d));values=json.loads(Path(a.reviews).read_text());values[0]['review']=None;Path(a.reviews).write_text(json.dumps(values))
   with self.assertRaises(ValueError):summarize(a)
   Path(a.run).write_text(Path(a.run).read_text().splitlines()[0]+'\n')
   with self.assertRaises(ValueError):validated(a.suite,a.run,a.protocol)

if __name__=='__main__':unittest.main()
