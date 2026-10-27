import copy
import json
from pathlib import Path
import unittest
from run_comparison import validate

class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.rows=[json.loads(l) for l in Path(__file__).with_name('suite.jsonl').read_text().splitlines()]
    def test_frozen_suite_integrity(self):
        validate(self.rows)
        self.assertEqual(len(self.rows),75)
        self.assertEqual(sum(r['split']=='regression' for r in self.rows),41)
        self.assertEqual(len({r['conversation_id'] for r in self.rows if r['split']=='regression'}),2)
        self.assertEqual(sum(r['category']=='context_dependent' for r in self.rows),10)
        self.assertEqual(sum(r['split']=='unseen' for r in self.rows),34)
        manifest=json.loads(Path(__file__).with_name('suite.manifest.json').read_text())
        import hashlib
        self.assertEqual(hashlib.sha256(Path(__file__).with_name('suite.jsonl').read_bytes()).hexdigest(),manifest['sha256'])
    def test_duplicate_and_missing_turns_rejected(self):
        with self.assertRaises(ValueError):validate(self.rows+[self.rows[-1]])
        broken=copy.deepcopy(self.rows);broken[1]['turn']=3
        with self.assertRaises(ValueError):validate(broken)
    def test_reordered_conversations_rejected(self):
        with self.assertRaises(ValueError):validate(self.rows[:2]+self.rows[30:]+self.rows[2:30])
    def test_orphan_is_not_given_an_invented_referent(self):
        orphans=[r for r in self.rows if r['category']=='unresolved']
        self.assertEqual(len(orphans),2)
        self.assertTrue(all(r['resolved_question'] is None for r in orphans))
    def test_explicit_correction_uses_intended_subject(self):
        cases={r['id']:r for r in self.rows}
        self.assertEqual(cases['device-33']['resolved_question'],'Where is the planet Jupiter?')
        self.assertEqual(cases['new-mercury-3']['resolved_question'],'Is the chemical element mercury a metal?')

if __name__=='__main__':unittest.main()
