#!/usr/bin/env python3
"""Static wiring checks for download safety; these do not execute Stata.

Run download_flow_smoke.do in licensed Stata for offline return-code/import
checks. Backend transfer/extraction behavior has separate Java tests.
"""
from pathlib import Path
import re
import unittest

ADO = (Path(__file__).resolve().parents[1] / 'suso.ado').read_text(encoding='utf-8')


def program(name):
    match = re.search(rf'(?ms)^program {re.escape(name)}(?:,[^\n]*)?\n(.*?)^end$', ADO)
    if not match:
        raise AssertionError(f'Missing program: {name}')
    return re.sub(r'///[^\n]*\n\s*', ' ', match[1])


class DownloadFlowTests(unittest.TestCase):
    def test_backup_completion_is_recorded_after_work(self):
        p = program('_suso_backup')
        self.assertLess(p.index('INCOMPLETE: backup run started'), p.index('suso questionnaire list ,'))
        self.assertGreater(p.index('local completion = cond('), p.index('suso supervisor list ,'))
        self.assertIn('"COMPLETE","PARTIAL"', p)
        self.assertIn('return scalar complete =', p)

    def test_validate_before_creating_a_job(self):
        p = program('_suso_export_get')
        start = p.index('suso export start ,')
        self.assertLess(p.index("if `pollsecs'<1"), start)
        self.assertLess(p.index('confirm new file'), start)
        self.assertIn("missing(`pollsecs')", p)
        self.assertIn("missing(`jobtimeout')", p)

    def test_elapsed_includes_start_and_status_request_time(self):
        p = program('_suso_export_get')
        self.assertLess(p.index('local started = clock('), p.index('suso export start ,'))
        status = p.index('capture noisily _suso_export_status ,')
        completed = p.index('=="Completed"')
        self.assertIn('local elapsed = max(0, (clock(', p[status:completed])
        self.assertNotIn("`elapsed' + `pollsecs'", p)
        self.assertNotRegex(p, r'(?m)^\s*timer\s')

    def test_early_polls_are_bounded(self):
        p = program('_suso_export_get')
        self.assertIn("cond(`polls'==1,1,cond(`polls'==2,2,cond(`polls'==3,5,`pollsecs')))", p)
        self.assertIn("min(`delay',`pollsecs',60,`jobtimeout'-`elapsed')", p)
        self.assertIn("sleep `=`delay'*1000'", p)

    def test_no_blind_download_retry_or_automatic_job_restart(self):
        p = program('_suso_export_get')
        # Exclude explanatory recovery commands printed for the user.
        calls = [line.strip() for line in p.splitlines()
                 if not line.lstrip().startswith(('*', 'di '))]
        self.assertEqual(sum('suso export start ,' in line for line in calls), 1)
        self.assertEqual(sum('suso export download ,' in line for line in calls), 1)
        self.assertNotIn('sleep 2000', p)
        self.assertIn('The server job was not cancelled', p)
        self.assertIn('Retry the existing job', p)

    def test_download_quotes_paths_and_honors_destination_alone(self):
        p = program('_suso_export').split('if "`verb\'"=="download" {', 1)[1]
        p = p.split('if "`verb\'"=="cancel" {', 1)[0]
        self.assertIn('savefile(`"`saving\'"\')', p)
        self.assertIn('| `"`unzipto\'"\'!=""', p)
        self.assertIn('return local unzipdir `"`r(unzipdir)\'"\'', p)

    def test_download_metadata_survives_wrappers(self):
        p = program('_suso_export')
        self.assertIn('local download_seconds = r(elapsed_seconds)', p)
        self.assertIn('local backup `"`r(backup)\'"\'', p)
        self.assertIn('local checksum `"`r(sha256)\'"\'', p)
        for name in ('_suso_export_get', '_suso_para_get'):
            p = program(name)
            self.assertIn('return add', p)
        self.assertIn('return scalar prepare_seconds', program('_suso_export_get'))
        self.assertIn('return scalar unzip_seconds', program('_suso_para_get'))

    def test_paradata_honors_replace_even_for_default_name_collisions(self):
        p = program('_suso_para_get')
        self.assertNotIn('else if "`replace\'"==""', p)
        call = next(line for line in p.splitlines() if line.lstrip().startswith('_suso_export_get ,'))
        self.assertIn("`replace'", call)
        self.assertNotRegex(call, r'\sreplace\s')
        self.assertIn('_suso_para_load , dir(`"`xdir\'"\')', p)

    def test_loading_retains_memory_on_failure_and_rejects_ambiguous_files(self):
        p = program('_suso_para_load')
        self.assertIn("if `ncands'>1", p)
        self.assertLess(p.index("if `ncands'>1"), p.index('import delimited'))
        self.assertLess(p.index('\n    preserve\n'), p.index('capture noisily import delimited'))
        self.assertIn("if `import_rc' {\n        restore", p)
        self.assertIn('restore, not', p)
        self.assertIn('_suso_unzip , file(`"`file\'"\') dir(`"`dir\'"\')', p)

    def test_backup_allocates_new_run_before_fetching_or_saving(self):
        p = program('_suso_backup')
        allocate = p.index('_suso_backup_dir ,')
        self.assertLess(allocate, p.index('suso questionnaire list ,'))
        self.assertLess(allocate, p.index('mkdir `"`dir\'/exports'))
        self.assertIn('local dir `"`r(dir)\'"\'', p)
        self.assertIn('return local dir `"`dir\'"\'', p)
        self.assertNotRegex(p, r'(?m)^\s*quietly save .*?,\s*replace')
        helper = program('_suso_backup_dir')
        self.assertIn('forvalues attempt=0/999', helper)
        self.assertIn('capture mkdir `"`candidate\'"\'', helper)
        self.assertIn("if !`mkdir_rc' {", helper)
        self.assertIn('direxists(st_local("candidate"))', helper)
        self.assertIn('fileexists(st_local("candidate"))', helper)
        self.assertNotRegex(helper, r'(?m)^\s*(?:rmdir|erase|copy)\s')

    def test_extraction_manifest_and_bytes_survive_all_consumers(self):
        for name in ('_suso_export', '_suso_para_get', '_suso_para_load'):
            p = program(name)
            calls = p.count('_suso_unzip ,')
            self.assertGreater(calls, 0)
            self.assertEqual(p.count('return local manifest `"`r(manifest)\'"\''), calls)
            self.assertEqual(p.count('return scalar unzip_bytes = r(unzip_bytes)'), calls)


if __name__ == '__main__':
    unittest.main()
