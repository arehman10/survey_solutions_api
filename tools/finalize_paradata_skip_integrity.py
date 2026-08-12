#!/usr/bin/env python3
from pathlib import Path

ADO_FILES = [Path("suso.ado"), Path("install/suso.ado")]
HELP_FILES = [Path("suso.sthlp"), Path("install/suso.sthlp")]


def rep(text: str, old: str, new: str, label: str, count: int = 1) -> str:
    found = text.count(old)
    if found != count:
        raise RuntimeError(f"{label}: expected {count} match(es), found {found}")
    return text.replace(old, new, count)


def patch_ado(text: str) -> str:
    text = text.replace("v1.7.1 build 2026-07-02-SCRUB", "v1.7.1 build 2026-08-12-SKIPFIX")
    text = text.replace("v1.7.1 (build 2026-07-02-SCRUB)", "v1.7.1 (build 2026-08-12-SKIPFIX)")

    old = '''    quietly gen byte sk_prevnear = `prevnear'
    quietly gen byte sk_nextnear = `nextnear'
    quietly gen byte sk_casc1 = sk_prevnear | sk_nextnear
    quietly by interview__id sk_run para_rem: gen byte sk_casc = (sk_casc1[1]==1) if para_rem
    quietly replace sk_casc = 0 if missing(sk_casc)
    quietly gen sk_trig = cond(sk_prevnear, sk_lastvar, sk_nextvar) if sk_casc1
    quietly by interview__id sk_run para_rem: replace sk_trig = sk_trig[1] if sk_casc & para_rem
'''
    new = '''    quietly gen byte sk_prevnear = `prevnear'
    quietly gen byte sk_nextnear = `nextnear'
    quietly gen byte sk_useprev = sk_prevnear & (!sk_nextnear | (`dtprev'<=`dtnext'))
    quietly gen byte sk_casc1 = sk_prevnear | sk_nextnear
    tempvar runiscasc
    quietly egen byte `runiscasc' = max(sk_casc1), by(interview__id sk_run)
    quietly gen byte sk_casc = para_rem & `runiscasc'
    quietly gen sk_trig = cond(sk_useprev, sk_lastvar, sk_nextvar) if sk_casc1
    quietly bysort interview__id sk_run (para_ord para_seq): ///
        replace sk_trig = sk_trig[_n-1] if sk_trig=="" & _n>1
    quietly replace sk_trig = "" if !sk_casc
'''
    text = rep(text, old, new, "robust cascade propagation")
    text = rep(text,
        '        quietly gen sk_val = cond(sk_prevnear, sk_lastval, sk_nextval)\n',
        '        quietly gen sk_val = cond(sk_useprev, sk_lastval, sk_nextval)\n',
        "consistent trigger value")

    old = '''    quietly count if sk_casc1
    local ncasc = r(N)
    quietly count if sk_casc
    local nremevents = r(N)
    quietly count if sk_qtag
    local nwiped = r(N)
    quietly count if sk_reanswered
'''
    new = '''    quietly count if sk_casc1
    local ncasc = r(N)
    quietly count if sk_casc
    local nwiped = r(N)                 // backward-compatible: removal-event count
    local nremevents = `nwiped'
    quietly count if sk_qtag
    local naffectedqall = r(N)          // distinct question-within-run cases
    quietly count if sk_reanswered
'''
    text = rep(text, old, new, "separate event and question counts")

    text = rep(text,
'''    collapse (sum) n_answers=para_ans n_removed=para_rem n_cascades=sk_casc1     ///
        casc_removed=sk_qtag casc_open=sk_open casc_reanswered=sk_reanswered     ///
        casc_unknown=sk_unknown (first) responsible=sk_resp,                    ///
        by(interview__id sk_trig) fast''',
'''    collapse (sum) n_answers=para_ans n_removed=para_rem n_cascades=sk_casc1     ///
        casc_removed=sk_casc casc_questions=sk_qtag casc_open=sk_open            ///
        casc_reanswered=sk_reanswered casc_unknown=sk_unknown                    ///
        (first) responsible=sk_resp, by(interview__id sk_trig) fast''',
        "stage-one compatibility")

    text = rep(text,
'''    collapse (sum) n_answers n_removed n_cascades casc_removed casc_open          ///
        casc_reanswered casc_unknown n_triggers=sk_tg                              ///
        (first) responsible, by(interview__id) fast''',
'''    collapse (sum) n_answers n_removed n_cascades casc_removed casc_questions    ///
        casc_open casc_reanswered casc_unknown n_triggers=sk_tg                    ///
        (first) responsible, by(interview__id) fast''',
        "stage-two compatibility")

    text = rep(text,
'''    label variable casc_removed    "distinct questions affected by removal runs"
    label variable casc_open       "affected questions whose final event is AnswerRemoved"''',
'''    label variable casc_removed    "AnswerRemoved events in detected cascades"
    label variable casc_questions  "distinct question-within-run cases affected"
    label variable casc_open       "affected questions whose final event is AnswerRemoved"''',
        "aggregate labels")

    text = rep(text,
'''    di as txt "  cascades " as res "`ncasc'" as txt "  |  questions affected historically " as res "`nwiped'" ///
        as txt "  |  re-answered later " as res "`nreansweredall'" as txt "  |  still removed " as res "`nopenall'" ///''',
'''    di as txt "  cascades " as res "`ncasc'" as txt "  |  question-run cases affected " as res "`naffectedqall'" ///
        as txt "  |  removal events " as res "`nwiped'" as txt "  |  re-answered later " as res "`nreansweredall'" ///
        as txt "  |  still removed " as res "`nopenall'" ///''',
        "summary counts")

    text = text.replace('if wl!="" & nrem>8', 'if wl!="" & nqrem>8')
    text = text.replace('cond(nrem>8, " ... and " + strofreal(nqrem-8) + " more", "")',
                        'cond(nqrem>8, " ... and " + strofreal(nqrem-8) + " more", "")')
    text = text.replace('NOTE: the erased items carry no skip conditions',
                        'NOTE: the affected items carry no skip conditions')
    text = text.replace('Review/approval workflow reset (erased items carry no skip conditions)',
                        'Review/approval workflow reset (affected items carry no skip conditions)')
    text = text.replace('heavily restructured, `inv_w_`rr\'\' answers erased.',
                        'heavily restructured, `inv_w_`rr\'\' questions affected.')
    text = text.replace('same gate variable erased across many interviews',
                        'the same candidate gate recurring across many interviews')

    text = rep(text,
'''    return scalar nwiped       = `nwiped'
    return scalar nremovalevents = `nremevents'
    return scalar nreanswered  = `nreansweredall' ''',
'''    return scalar nwiped       = `nwiped'
    return scalar nremovalevents = `nremevents'
    return scalar naffectedquestions = `naffectedqall'
    return scalar nreanswered  = `nreansweredall' ''',
        "return affected count")

    text = rep(text,
'''    local nwiped = r(nwiped)
    local nopen = r(nopen)''',
'''    local nwiped = r(nwiped)
    local naffectedq = r(naffectedquestions)
    local nopen = r(nopen)''',
        "capture report affected count")

    text = rep(text,
'''    quietly keep interview__id n_cascades casc_removed casc_open casc_reanswered casc_unknown n_triggers''',
'''    quietly keep interview__id n_cascades casc_removed casc_questions casc_open casc_reanswered casc_unknown n_triggers''',
        "keep report fields")
    text = rep(text,
'''    foreach v in n_cascades casc_removed casc_open casc_reanswered casc_unknown n_triggers {''',
'''    foreach v in n_cascades casc_removed casc_questions casc_open casc_reanswered casc_unknown n_triggers {''',
        "fill report fields")
    text = rep(text,
'''<div class="k">skip cascades (`nwiped' affected; `nopen' still removed)</div>''',
'''<div class="k">skip cascades (`naffectedq' affected; `nopen' still removed)</div>''',
        "report card")
    text = rep(text,
'''<th class="r">questions affected</th>''',
'''<th class="r">removal events</th>''',
        "trigger table heading")
    text = rep(text,
'''"cas":`=n_cascades[`i']',"wip":`=casc_removed[`i']',"cop":''',
'''"cas":`=n_cascades[`i']',"rem":`=casc_removed[`i']',"wip":`=casc_questions[`i']',"cop":''',
        "embed compatible counts")

    # Standalone skip-review totals should use distinct question-run cases.
    text = text.replace('"`nwiped\' distinct question-case(s) affected historically;',
                        '"`naffectedqall\' distinct question-run case(s) affected historically;')
    text = text.replace('<div class="card"><div class="v">`nwiped\'</div><div class="k">questions affected historically</div>',
                        '<div class="card"><div class="v">`naffectedqall\'</div><div class="k">question-run cases affected</div>')

    # Console and table language: historical evidence, not a claim about current blanks.
    text = text.replace('trigger variables wiping the most answers',
                        'candidate gate variables associated with the most removal events')
    text = text.replace('{ul:answers wiped}', '{ul:removal events}')
    text = text.replace('interviews wiping the most answers',
                        'interviews with the largest historical removal runs')
    text = text.replace('{ul:wiped}', '{ul:removal events}')
    text = text.replace('{ul:wiped/set}', '{ul:removed/set}')
    text = text.replace('answers wiped "', 'removal events "')

    if 'the skip logic erased them' in text or 'they are empty now' in text:
        raise RuntimeError('unsafe current-state assertion remains')
    return text


def patch_help(text: str) -> str:
    text = text.replace('{* *! version 1.5.0  17jun2026}{...}',
                        '{* *! version 1.7.1  12aug2026}{...}')
    text = text.replace(
'''{synopt :{cmd:skips}}gate flips: skip-triggered answer-removal cascades ({opt cascade()} {opt window()} {opt top()} {opt saving()}); {opt qx(file.html)} names the questions, {opt messages(file.txt)} writes an email-ready action list, and {opt html(file.html)} writes a shareable, printable Skip Violation Review page for the vendor/field supervisor{p_end}''',
'''{synopt :{cmd:skips}}historical answer-removal runs near candidate gate changes ({opt cascade()} {opt window()} {opt top()} {opt saving()} {opt vars()}); {opt qx(file.html)} adjudicates candidate gates, {opt messages(file.txt)} writes an email-ready review list, and {opt html(file.html)} writes a shareable, printable review page{p_end}''')

    old = '''{pstd}
{cmd:skips} answers the skip-check question the way paradata can. The Survey
Solutions engine enforces enablement at capture time, so a disabled question
can never carry an answer; the abuse that {bf:does} happen is the {bf:gate flip}:
the interviewer changes a filter/gate answer and the engine cascades
{cmd:AnswerRemoved} through the section it disables {hline 1} sometimes a
legitimate correction, sometimes workload avoidance or fabrication cleanup.
{cmd:skips} detects every run of {opt cascade(3)} or more consecutive
{cmd:AnswerRemoved} events that starts within {opt window(60)} seconds of an
{cmd:AnswerSet} (the trigger), names the trigger variable, and reports: the gate
variables wiping the most answers survey-wide, the worst interviews, and an
interviewer league table by cascade rate. It leaves one row per interview
({cmd:n_cascades}, {cmd:casc_removed}, {cmd:n_triggers}, {cmd:wipe_share}) that
merges 1:1 on {cmd:interview__id} with the {cmd:flags} table. For enabled-but-
unanswered counts (item nonresponse), {cmd:suso interview stats , id()} returns
the server's own {cmd:NotAnsweredCount} per interview.
'''
    new = '''{pstd}
{cmd:skips} detects historical runs of {opt cascade(3)} or more consecutive
{cmd:AnswerRemoved} events in the untouched paradata stream. A run must be compact
and lie within {opt window(60)} seconds of a candidate {cmd:AnswerSet} immediately
before or after it. With {opt qx()}, questionnaire enabling conditions are used to
confirm or reattribute the candidate gate; without that evidence the relationship
is reported as timing-only, never as proven causation. Raw removal events are not
assumed to describe the current interview: for every affected question the command
checks its last paradata event and separates questions re-answered later, questions
still ending in {cmd:AnswerRemoved}, and unknown final states. Rejection is advised
only after the final export confirms that a question is actually blank and the
final questionnaire logic says it should be asked.

{pstd}
{opt vars()} is applied only after runs have been constructed on the full event
stream. It filters which completed runs are reported; it never drops intervening
events before adjacency is evaluated. The output keeps backward-compatible
{cmd:casc_removed} and {cmd:r(nwiped)} as removal-event counts and adds
{cmd:casc_questions}, {cmd:casc_open}, {cmd:casc_reanswered},
{cmd:casc_unknown}, and {cmd:r(naffectedquestions)} for final-state-aware review.
The one-row-per-interview result merges 1:1 on {cmd:interview__id} with the
{cmd:flags} table. For enabled-but-unanswered counts, use the final-data
{cmd:check} audit or {cmd:suso interview stats , id()}.
'''
    text = rep(text, old, new, "help skips method")

    text = text.replace('the gate variables wiping answers',
                        'candidate gates associated with historical removal runs')

    old = '''{pstd}
{cmd:skips} ends with a supervisor action list, and its shareable review page
({opt html()}) groups the action cases by gate question (with per-gate totals:
cases, answers erased, interviews, enumerators), shows the gate{c 39}s old {c 45}{c 62} new
values recovered from the answer history, the interview key for Headquarters,
and a per-case decision line; when a chained flip erased the gate itself, the
card says so instead of listing the gate among its own casualties.
{cmd:skips} ends with a supervisor action list: one message per violation stating
the interview, the enumerator, when it happened, which gate variable was changed
(and to what value), how many later answers the skip logic erased, and what to do
about it. Point {opt qx()} at the questionnaire HTML that Survey Solutions includes
with every data export and each message also carries the question wording, its
section, and its own enabling condition; {opt messages()} writes the list to a plain
text file ready to paste into an email to the vendor. {cmd:report , qx()} shows the
same action list in the interactive report. {cmd:qx} on its own loads the parsed
questionnaire as a dataset for browsing. {cmd:check} closes the loop on the data
side: it translates the questionnaire{c 39}s C# enabling conditions to Stata (the
common patterns; untranslatable ones are listed, never guessed), normalises the
Survey Solutions missing sentinels, and audits the exported main file record by
record. Conditions whose numeric referents are themselves unanswered are scored
undetermined and excluded from both counts, matching C# null semantics rather
than Stata{c 39}s missing-is-infinity rule. skips watches the paradata stream for
mid-interview gate flips; check audits the final exported state that analysts
actually receive.
'''
    new = '''{pstd}
The supervisor action list and {opt html()} review page group historical removal
runs by candidate gate, show old and new values recovered from answer history,
and report both removal-event counts and distinct affected questions. Every case
states how many affected questions were re-answered later, how many still end in
{cmd:AnswerRemoved}, and how many have unknown final state. The page does not say
that answers are currently empty merely because an earlier removal event exists.
Point {opt qx()} at the questionnaire HTML for question wording and gate
adjudication; {opt messages()} writes the same evidence to a plain-text review
file. {cmd:report , qx()} embeds it in the interactive report. {cmd:check} then
audits the final exported data against the questionnaire, complementing the
historical event-stream evidence from {cmd:skips}.
'''
    text = rep(text, old, new, "help review output")
    return text


def main() -> None:
    if ADO_FILES[0].read_bytes() != ADO_FILES[1].read_bytes():
        raise RuntimeError('ado copies differ before finalization')
    if HELP_FILES[0].read_bytes() != HELP_FILES[1].read_bytes():
        raise RuntimeError('help copies differ before finalization')

    ado = patch_ado(ADO_FILES[0].read_text(encoding='utf-8'))
    help_text = patch_help(HELP_FILES[0].read_text(encoding='utf-8'))
    for p in ADO_FILES:
        p.write_text(ado, encoding='utf-8')
    for p in HELP_FILES:
        p.write_text(help_text, encoding='utf-8')

    test = Path('tests/test_paradata_skip_integrity.py')
    t = test.read_text(encoding='utf-8')
    t += '''\n\ndef test_run_propagation_does_not_depend_on_first_physical_row():\n    assert "egen byte `runiscasc' = max(sk_casc1)" in TEXT\n    assert "sk_casc1[1]" not in TEXT\n    assert "sk_useprev" in TEXT\n\n\ndef test_backward_compatible_event_counts_are_preserved():\n    assert "casc_removed=sk_casc" in TEXT\n    assert "casc_questions=sk_qtag" in TEXT\n    assert "return scalar naffectedquestions" in TEXT\n    assert '"wip":`=casc_questions[`i\']\'' in TEXT\n\n\ndef test_affected_list_uses_distinct_question_threshold():\n    assert 'if wl!="" & nqrem>8' in TEXT\n    assert 'cond(nqrem>8, " ... and " + strofreal(nqrem-8)' in TEXT\n'''
    test.write_text(t, encoding='utf-8')

    Path('.gitignore').write_text('__pycache__/\n*.py[cod]\n', encoding='utf-8')

    raw = ADO_FILES[0].read_bytes()
    if b'\x08' in raw:
        raise RuntimeError('raw backspace remains')
    if ADO_FILES[0].read_bytes() != ADO_FILES[1].read_bytes():
        raise RuntimeError('ado copies differ after finalization')
    if HELP_FILES[0].read_bytes() != HELP_FILES[1].read_bytes():
        raise RuntimeError('help copies differ after finalization')
    for phrase in ('they are empty now', 'the skip logic erased them'):
        if phrase in ado:
            raise RuntimeError(f'unsafe phrase remains: {phrase}')
    print('finalized paradata skip-integrity patch')


if __name__ == '__main__':
    main()
