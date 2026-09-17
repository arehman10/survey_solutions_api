#!/usr/bin/env python3
"""Source-wiring guards only; run folder_flow_smoke.do for real Stata behavior."""
from pathlib import Path
import re
import unittest

ADO = (Path(__file__).resolve().parents[1] / 'suso.ado').read_text(encoding='utf-8')


def program(name):
    found = re.search(rf'(?ms)^program {re.escape(name)}(?:,[^\n]*)?\n(.*?)^end$', ADO)
    assert found, f'Missing program: {name}'
    return re.sub(r'///[^\n]*\n\s*', ' ', found[1])


class FolderFlowTests(unittest.TestCase):
    def test_local_extract_does_not_contact_server_or_import(self):
        p = program('_suso_export').split('if "`verb\'"=="extract" {', 1)[1]
        p = p.split('if "`verb\'"=="list" {', 1)[0]
        self.assertIn('syntax , FILE(string) [ UNZIPto(string) UNZIPW(string) ]', p)
        self.assertIn('confirm file', p)
        self.assertIn('_suso_unzip , file(`"`file\'"\') dir(`"`unzipto\'"\') pwd(`"`unzipw\'"\')', p)
        self.assertNotRegex(p, r'(?m)^\s*(?:_suso_call|_suso_export_get|import|use|clear|_suso_para_load)\b')
        self.assertNotIn('$SUSO_BASE', p)
        self.assertIn('local unzipw `"$SUSO_EXPORTPWD"\'', p)

    def test_local_extract_preserves_backend_metadata(self):
        p = program('_suso_export').split('if "`verb\'"=="extract" {', 1)[1]
        p = p.split('if "`verb\'"=="list" {', 1)[0]
        self.assertIn('return add', p)
        for field in ('unzipdir', 'manifest', 'archive', 'unzip_backup'):
            self.assertIn(f'return local {field}', p)
        for field in ('unzip_bytes', 'unzipped', 'unzip_seconds'):
            self.assertIn(f'return scalar {field}', p)

    def test_backup_runs_are_children_of_requested_root(self):
        p = program('_suso_backup_dir')
        self.assertIn('local candidate `"`requested\'/suso_backup_`stamp\'"\'', p)
        self.assertIn('local candidate `"`requested\'/suso_backup_`stamp\'_`attempt\'"\'', p)
        self.assertNotIn('local candidate `"`requested\'_`stamp\'', p)
        self.assertIn('if `root_isfile\' {', p)
        self.assertIn('return local root `"`requested\'"\'', p)
        self.assertNotRegex(p, r'(?m)^\s*(?:rmdir|erase|copy)\s')

    def test_backup_caller_retains_root_and_actual_run_folder(self):
        p = program('_suso_backup')
        self.assertIn('local root `"`r(root)\'"\'', p)
        self.assertIn('local dir `"`r(dir)\'"\'', p)
        self.assertIn('return local root `"`root\'"\'', p)
        self.assertIn('return local dir `"`dir\'"\'', p)

    def test_paradata_honors_requested_folder_on_get_and_local_load(self):
        for name, source in (('_suso_para_get', 'zip'), ('_suso_para_load', 'file')):
            p = program(name)
            self.assertIn('_suso_unzip , file(`"`' + source + '\'"\') dir(`"`dir\'"\')', p)
        p = program('_suso_para_load')
        self.assertIn("if `import_rc' {\n        restore", p)
        self.assertIn('restore, not', p)

    def test_extraction_backup_is_propagated_through_each_consumer(self):
        for name in ('_suso_export', '_suso_para_get', '_suso_para_load'):
            p = program(name)
            self.assertEqual(p.count('_suso_unzip ,'),
                             p.count('return local unzip_backup `"`r(unzip_backup)\'"\''))


if __name__ == '__main__':
    unittest.main()
