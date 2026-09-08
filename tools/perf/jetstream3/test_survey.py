"""Reject false completion evidence at the artifact boundary."""
import json
import unittest
from survey import completed_result

class CompletionTests(unittest.TestCase):
    def document(self, score=1):
        return json.dumps({'JetStream3.0': {'tests': {'case': {'metrics': {'Score': {'current': [score]}}}}}})

    def test_valid(self):
        self.assertIsNotNone(completed_result(self.document(), 'case', 0))

    def test_failure_and_missing(self):
        self.assertIsNone(completed_result(self.document(), 'case', 1))
        self.assertIsNone(completed_result('Starting case\n', 'case', 0))
        self.assertIsNone(completed_result(self.document(), 'different-case', 0))

    def test_duplicate_and_malformed(self):
        self.assertIsNone(completed_result(self.document()+'\n'+self.document(), 'case', 0))
        for value in [None, [], {'tests': None}, {'tests': {'case': None}}]:
            self.assertIsNone(completed_result(json.dumps({'JetStream3.0': value}), 'case', 0))

    def test_invalid_scores(self):
        for score in [0, -1, None, True, '1', float('nan'), float('inf'), 10**400]:
            self.assertIsNone(completed_result(self.document(score), 'case', 0))

    def test_timeout_cannot_complete_even_if_process_exits_zero(self):
        self.assertIsNone(completed_result(self.document(), 'case', 0, timed_out=True))

    def test_integer_exceeding_json_parser_limit(self):
        self.assertIsNone(completed_result(self.document().replace('[1]', '[' + '9'*5000 + ']'), 'case', 0))

if __name__ == '__main__':
    unittest.main()
