import json, unittest
from pathlib import Path
from calibrate_gate import calibrate, metrics
class RankingChecks(unittest.TestCase):
 def test_calibration_ignores_validation(self):
  with self.assertRaises(ValueError):calibrate([dict(id='x',partition='validation',score=3,supported=True)])
 def test_tradeoff_and_bad_scores(self):
  rows=[dict(id=str(i),partition='calibration',score=s,supported=y)for i,(s,y)in enumerate([(6,True),(5,False),(4.1,True),(3.9,True),(3,False)])]
  result=calibrate(rows,minimum_precision=.70)
  self.assertEqual(result['selected']['threshold'],3.9)
  self.assertEqual(result['selected']['unsupported_accepted'],1)
  with self.assertRaises(ValueError):calibrate(rows+rows)
  with self.assertRaises(ValueError):calibrate([dict(id='x',partition='calibration',score=float('nan'),supported=True)])
 def test_split_and_label_integrity(self):
  p=Path(__file__).parent/'evaluation/ranking';splits=json.loads((p/'split.json').read_text())
  rows=[json.loads(l)for l in(p/'train.jsonl').read_text().splitlines()]
  self.assertTrue(all(splits['topics'].get(r['topic'],splits['cases'].get(r['id']))in ['train','model-selection']for r in rows))
  fresh=[json.loads(l)for l in(p/'fresh-suite.jsonl').read_text().splitlines()]
  self.assertEqual(len(fresh),40);self.assertEqual(len({r['id']for r in fresh}),40)
  self.assertFalse({r['topic']for r in fresh if r.get('gold')}&set(splits['topics']))
  import hashlib
  for r in map(json.loads,(p/'gate-reviews.jsonl').read_text().splitlines()):
   self.assertEqual(r['text_sha256'],hashlib.sha256(r['text'].encode()).hexdigest())
  for r in map(json.loads,(p/'training-reviews.jsonl').read_text().splitlines()):
   self.assertEqual(r['text_sha256'],hashlib.sha256(r['candidate'].encode()).hexdigest())
if __name__=='__main__':unittest.main()
