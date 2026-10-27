import unittest
from compact_corpus import plan

class CompactionTests(unittest.TestCase):
    def test_storage_only_budget_keeps_whole_blocks_and_is_deterministic(self):
        old={1:4000,2:1000};blocks={1:[(0,200),(1,700),(2,1500),(3,1200)],2:[(0,150),(1,500)],3:[(0,300),(1,100)]}
        keep,report=plan(old,blocks)
        self.assertEqual((keep,report),plan(old,blocks))
        self.assertLessEqual(report['selected']['body_characters'],4500)
        self.assertEqual(len(keep),len(set(keep)))
        expected=sum(n for aid,rows in blocks.items()for ordinal,n in rows if (aid,ordinal)in keep)
        self.assertEqual(expected,report['selected']['body_characters'])
        self.assertTrue(all(p['body_characters']>4500 for p in report['profiles'] if p['scale']>report['selected']['scale']))

if __name__=='__main__':unittest.main()
