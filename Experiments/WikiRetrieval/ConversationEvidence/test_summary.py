import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from summarize import summarize
from run_comparison import ARMS,digest

class SummaryTests(unittest.TestCase):
    def test_review_binds_to_passage_and_complete_matrix(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);suite=p/'suite.jsonl';run=p/'run.jsonl';review=p/'review.jsonl'
            suite.write_text(json.dumps({'id':'a','expected_behavior':'answer','split':'regression','category':'standalone'})+'\n')
            rows=[{'id':'a','arm':arm,'corpus':'test','decision':'retrieved','passage':'A supported fact.','elapsed_ms':1}for arm in ARMS]
            run.write_text(''.join(json.dumps(r)+'\n'for r in rows))
            run.with_suffix('.manifest.json').write_text(json.dumps({'complete':True,'suite_sha256':digest(suite),'output_sha256':digest(run)}))
            labels=[{'id':'a','arm':arm,'corpus':'test','support':'sufficient','note':'fixture','passage_sha256':hashlib.sha256(b'A supported fact.').hexdigest()}for arm in ARMS]
            review.write_text(''.join(json.dumps(r)+'\n'for r in labels))
            report=summarize(suite,[run],[review])
            self.assertEqual(len(report['reviewed_outputs']),3)
            labels[0]['passage_sha256']='wrong'
            review.write_text(''.join(json.dumps(r)+'\n'for r in labels))
            with self.assertRaises(ValueError):summarize(suite,[run],[review])
            run.write_text(json.dumps(rows[0])+'\n')
            with self.assertRaises(ValueError):summarize(suite,[run],[review])

if __name__=='__main__':unittest.main()
