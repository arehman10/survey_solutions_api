#!/usr/bin/env python3
"""Static integration guards for the September 2026 Stata data-path fixes.

These exercise source wiring, not Stata execution. Run data_path_smoke.do in a
licensed Stata session to verify dataset calculations and return codes.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADO = (ROOT / 'suso.ado').read_text(encoding='utf-8')


def program(name):
    match = re.search(rf'(?ms)^program {re.escape(name)}(?:,[^\n]*)?\n(.*?)^end$', ADO)
    if not match:
        raise AssertionError(f'Program missing: {name}')
    return match[1]


def commands(body):
    return re.sub(r'///[^\n]*\n\s*', ' ', body).splitlines()


class DataPathSourceTests(unittest.TestCase):
    def test_missing_policy_reaches_both_report_scopes_and_final_checks(self):
        edges = [('_suso_para_suite', '_suso_para_report', 1),
                 ('_suso_para_report', '_suso_para_skips', 2),
                 ('_suso_para_skips', '_suso_para_casefinal', 1),
                 ('_suso_para_skips', '_suso_para_triggerfinal', 1)]
        for caller, callee, n in edges:
            body = program(caller)
            self.assertIn('MISScodes(numlist)', body)
            calls = [c for c in commands(body) if re.search(rf'\b{callee}\b', c)
                     and not c.lstrip().startswith('*')]
            self.assertEqual(len(calls), n, (caller, callee))
            for c in calls:
                self.assertIn("`missopt'", c, (caller, callee))
        self.assertIn("misscodes(`misscodes')", program('_suso_para_suite'))

    def test_one_shared_normalization_policy(self):
        for name in ('_suso_para_casefinal', '_suso_para_triggerfinal', '_suso_para_check'):
            body = program(name)
            self.assertIn('MISScodes(numlist)', body)
            self.assertIn('_suso_para_missing ,', body)
            self.assertNotIn('==-999999999', body)
        policy = program('_suso_para_missing')
        self.assertIn('local misscodes "-999999999"', policy)
        self.assertIn('foreach mc of numlist', policy)
        self.assertIn('if "`v\'"!="interview__id"', policy)
        self.assertIn('upper(strtrim(`v\'))=="##N/A##"', policy)
        self.assertNotIn('real(', policy, 'Do not reinterpret arbitrary text answers as numeric missing codes')

    def test_working_copies_only_are_normalized(self):
        for name in ('_suso_para_casefinal', '_suso_para_triggerfinal', '_suso_para_check'):
            body = program(name)
            self.assertLess(body.index('use `"`data\'"\', clear'), body.index('_suso_para_missing'))
            self.assertNotRegex(body, r'save\s+`"`data\'')

    def test_no_trigger_field_survives_without_a_bounded_candidate(self):
        body = program('_suso_para_skips')
        for name in ('sk_trig', 'sk_trigval', 'sk_trigroster', 'sk_trigqkey',
                     'sk_trigts', 'sk_trigord', 'sk_trigseq'):
            c = next(c for c in commands(body) if re.search(rf'gen\s+\w+\s+{name}\s*=', c))
            self.assertIn('if sk_first & (sk_prevcontext | sk_nextcontext)', c, name)
        self.assertIn('No answer event within the selected window', body)
        self.assertLess(body.index('sk_prevcontext = sk_prevnear'), body.index('sk_trig ='))
        self.assertLess(body.index('sk_nextcontext = sk_nextnear'), body.index('sk_trig ='))

    def test_reduced_export_fallback_precedes_unconditional_identity_use(self):
        body = program('_suso_para_skips')
        fallback = body.index('* Reduced paradata may contain no Parameters')
        identity = body.index('gen str80 para_var = ""', fallback)
        self.assertLess(identity, body.index('gen str80 sk_itemvar = para_var'))
        self.assertLess(body.index('local hasvar 0'), identity)
        self.assertIn('sk_itemvar = "(identity unavailable)" if sk_identityunknown', body)

    def test_full_option_list_not_capped_at_60(self):
        body = program('_suso_para_check')
        self.assertIn('_suso_para_badcodes', body)
        self.assertNotIn("`no_`i''<=60", body)
        self.assertIn('complete answer option values', program('_suso_para_qxload'))
        validator = program('_suso_para_badcodes')
        self.assertIn("`nvalues'!=`nopts'", validator)
        self.assertIn("if missing(`value')", validator)
        self.assertIn('exit 459', validator)
        self.assertIn("if `nbat'==20", validator)
        self.assertIn("if `nbat'>0", validator)
        self.assertIn("!missing(`varlist')", validator)

    def test_all_bad_code_scopes_use_one_mask(self):
        body = program('_suso_para_check')
        self.assertIn("local nbd = r(nbad)", body)
        self.assertIn("count if `badcode' & interview__status==`s'", body)
        self.assertIn("count if `badcode' & `fvv'==`s'", body)
        self.assertNotIn("!inlist(`v_`i'', `vl')", body)
        self.assertIn("quietly keep if `badcode'", body)

    def test_runtime_fixture_covers_failure_cases_and_boundaries(self):
        smoke = (ROOT / 'tests/data_path_smoke.do').read_text()
        for marker in ('nopts(260)', 'nopts(3)', 'values("1 text")',
                       'final_status==3', 'trigger_final_status==2',
                       'r(nhistories)==4', 'r(nremovalevents)==4',
                       'r(noutsideevents)==1', 'n_identityunknown==1',
                       '09:59:00.000', '10:01:00.000', '15:00:00.000',
                       'drop parameters', "assert answer==-9", 'restore'):
            self.assertIn(marker, smoke)


if __name__ == '__main__':
    unittest.main(verbosity=2)
