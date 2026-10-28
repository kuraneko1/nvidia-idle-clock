import subprocess
import unittest
from unittest.mock import Mock
import z170_guard_nvidia_smi as g

A = 'GPU-95283591-83a0-dfef-b9ff-e9e601e3d593'
B = 'GPU-450167d4-8564-727d-8a97-232f720b0d23'

class GuardTests(unittest.TestCase):
    def q(self, line):
        return Mock(return_value=subprocess.CompletedProcess([], 0, stdout=line + '\n'))

    def test_uuid_target_and_index_are_rewritten_for_control_and_cleanup(self):
        q = self.q('1, ' + B + ', Tesla PG500-216, 0x1DF010DE')
        for args in (['-i','1','-lgc','135,135'], ['-i','1','-rgc'],
                     ['-i','1','--query-gpu=utilization.gpu,index','--format=csv,noheader,nounits','--loop-ms=200']):
            self.assertEqual(g.guarded_args(args, B, q)[1], B)

    def test_global_enumeration_is_only_unscoped_query(self):
        q = self.q('0, ' + A + ', Tesla V100-PCIE-32GB, 0x1DB610DE')
        args = ['--query-gpu=index,uuid','--format=csv,noheader,nounits']
        self.assertEqual(g.guarded_args(args, A, q), args)
        with self.assertRaises(ValueError): g.guarded_args(['-rgc'], A, q)

    def test_refuses_wrong_card_model_pci_or_missing(self):
        for row in ('1, '+ B +', NVIDIA GeForce RTX 3090, 0x1DF010DE',
                    '1, '+ B +', Tesla PG500-216, 0x220410DE',
                    '1, GPU-c355b495-83b9-8b9a-8aec-b9868f6963d7, Tesla PG500-216, 0x1DF010DE', ''):
            with self.assertRaises(ValueError): g.guarded_args(['-i','1','-lgc','135,135'], B, self.q(row))
        with self.assertRaises(ValueError): g.guarded_args(['-i','1','-rgc'], 'GPU-unknown', self.q(''))
        with self.assertRaises(subprocess.CalledProcessError):
            g.guarded_args(['-i','1','-rgc'], B, Mock(side_effect=subprocess.CalledProcessError(1,'nvidia-smi')))

    def test_reordered_index_refused_even_when_uuid_exists(self):
        q = self.q('0, '+ B +', Tesla PG500-216, 0x1DF010DE')
        with self.assertRaises(ValueError): g.guarded_args(['-i','1','-rgc'], B, q)
        self.assertEqual(g.guarded_args(['-i','0','-rgc'], B, q)[1], B)

    def test_refuses_multiple_or_ambiguous_selectors(self):
        q = self.q('1, '+ B +', Tesla PG500-216, 0x1DF010DE')
        for a in (['-i','0,1','-rgc'],['-i','1','-i','0','-rgc'],['--id=1','-rgc'],['-i']):
            with self.assertRaises(ValueError): g.guarded_args(a, B, q)

if __name__ == '__main__': unittest.main()
