#!/usr/bin/env python3
"""Static wiring guards only: these checks do not execute Stata.

Run export_progress_smoke.do in licensed Stata for mocked API behavior,
returned results, displayed text, and actual polling control flow.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADO = (ROOT / 'suso.ado').read_text(encoding='utf-8')


def program(name):
    found = re.search(rf'(?ms)^program {re.escape(name)}(?:,[^\n]*)?\n(.*?)^end$', ADO)
    if not found:
        raise AssertionError(f'Missing program: {name}')
    return re.sub(r'///[^\n]*\n\s*', ' ', found[1])


class ExportProgressSourceTests(unittest.TestCase):
    def test_public_status_and_polling_share_one_status_reader(self):
        p = program('_suso_export')
        status = p.split('if "`verb\'"=="status" {', 1)[1].split('if "`verb\'"=="get" {', 1)[0]
        self.assertIn('_suso_export_status , id(`id\') `verbose\'', status)
        self.assertIn('return add', status)
        self.assertNotIn('_suso_call', status)
        poll = program('_suso_export_get')
        self.assertIn('_suso_export_status , id(`jid\') started(`started\') `verbose\'', poll)

    def test_raw_api_results_are_copied_before_display_work(self):
        p = program('_suso_export_status')
        self.assertIn('_suso_call , method(GET) path(/api/v2/export/`id\')', p)
        self.assertLess(p.index('return add'), p.index('local phase'))
        # New display metadata must not replace any of these API fields.
        for field in ('progress', 'exportstatus', 'hasexportfile', 'http', 'jobid'):
            self.assertNotRegex(p, rf'(?m)^\s*return\s+(?:local|scalar)\s+{field}\b')

    def test_default_output_has_state_and_no_percentage(self):
        p = program('_suso_export_status')
        default, verbose = p.split('if "`verbose\'"!="" {', 1)
        output_lines = [line for line in default.splitlines() if line.lstrip().startswith('di ')]
        self.assertTrue(output_lines)
        self.assertTrue(all('%' not in line and 'rawprogress' not in line for line in output_lines))
        self.assertIn('`phase\'', ''.join(output_lines))
        self.assertIn('Raw server progress:', verbose)
        self.assertIn('not overall completion or file-download progress', verbose)

    def test_diagnostics_validate_without_smoothing_or_rescaling(self):
        p = program('_suso_export_status')
        self.assertIn('local pct = real(`"`rawprogress\'"\')', p)
        self.assertIn('!missing(`pct\') & inrange(`pct\',0,100)', p)
        self.assertIn('local diagnostic "unavailable"', p)
        self.assertNotRegex(p, r'(?m)^\s*(?:global|scalar)\s')
        self.assertNotRegex(p, r'(?m)^\s*local\s+pct\s*=.*(?:max\(|min\(|\*\s*100)')

    def test_elapsed_is_wall_clock_bounded_at_zero(self):
        p = program('_suso_export_status')
        self.assertIn('STARTED(real -1)', p)
        self.assertIn('if `started\'>=0 & !missing(`started\')', p)
        self.assertIn('local elapsed = max(0, (clock(', p)
        self.assertIn('return scalar prepare_seconds = `elapsed\'', p)
        self.assertNotRegex(p, r'(?m)^\s*timer\b')

    def test_ready_label_requires_completed_and_explicit_file(self):
        p = program('_suso_export_status')
        completed = p.split('if "`status\'"=="Completed" {', 1)[1].split('\n    }', 1)[0]
        self.assertIn('Completed; file availability unknown', completed)
        self.assertIn('inlist("`hasfile\'","true","1","yes") local phase "Ready for download"', completed)
        self.assertIn('inlist("`hasfile\'","false","0","no") local phase "Completed; no export file"', completed)
        self.assertEqual(p.count('Ready for download'), 1)

    def test_polling_never_uses_percentage_to_start_download(self):
        p = program('_suso_export_get')
        self.assertNotIn('r(progress)', p)
        self.assertIn('if "`status\'"=="Completed" continue, break', p)
        self.assertLess(p.index('=="Completed" continue, break'), p.index('capture noisily suso export download ,'))
        self.assertIn('"Fail","Failed","Canceled","Cancelled"', p)
        self.assertIn('return local status "NoFile"', p)

    def test_smoke_restores_the_mock_without_discard(self):
        smoke = (ROOT / 'tests/export_progress_smoke.do').read_text(encoding='utf-8')
        self.assertIn('capture noisily _suso_progress_smoke', smoke)
        self.assertIn('capture noisily run `"`restore_call\'"\'', smoke)
        self.assertNotRegex(smoke, r'(?m)^\s*discard\b')
        self.assertIn('global SUSO_BASE ""', smoke)
        self.assertIn('Unexpected API path in offline test', smoke)


if __name__ == '__main__':
    unittest.main()
