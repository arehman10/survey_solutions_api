#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re
import sys

FILES = [Path("suso.ado"), Path("install/suso.ado")]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    n = text.count(old)
    if n != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {n}")
    return text.replace(old, new, 1)


def patch_file(path: Path) -> None:
    raw = path.read_bytes()
    if b"*! suso v1.7.1" in raw:
        validate(path, raw)
        return

    backspaces = raw.count(b"\x08")
    if backspaces < 2:
        raise RuntimeError(f"{path}: expected raw backspace regex bytes, found {backspaces}")
    raw = raw.replace(b"\x08", b"\\b")
    text = raw.decode("utf-8")

    text = text.replace("suso v1.7.0", "suso v1.7.1")
    text = text.replace("suso  v1.7.0", "suso  v1.7.1")

    # 1) Cascade construction must see the untouched event stream.
    text = replace_once(
        text,
        '''    _suso_para_need events
    _suso_para_varsel , vars(`"`vars'"')
    if `cascade'<2 {''',
        '''    _suso_para_need events
    if `cascade'<2 {''',
        "remove pre-detection vars filter from skips",
    )

    text = replace_once(
        text,
        '''    capture drop sk_*

    * responsible (same rule as timing: at the last answer, else at the last event)''',
        '''    capture drop sk_*

    * vars() is an output filter only. Cascade construction must always use the
    * untouched event stream; otherwise dropping intervening events changes
    * adjacency and can manufacture a removal run that never occurred.
    quietly gen byte sk_vsel = 1
    if `"`vars'"'!="" {
        quietly replace sk_vsel = 0
        if `hasvar' {
            foreach p of local vars {
                quietly replace sk_vsel = 1 if (para_ans | para_rem) & strmatch(para_var, "`p'")
            }
        }
    }

    * Final paradata state for every interview-question. A historical
    * AnswerRemoved event does not imply that the answer is still absent:
    * a later AnswerSet restores it.
    tempfile FSTATE
    local hasfstate 0
    if `hasvar' {
        preserve
        quietly keep if (para_ans | para_rem) & para_var!=""
        if _N>0 {
            sort interview__id para_var para_ord para_seq
            quietly by interview__id para_var: keep if _n==_N
            quietly gen byte sk_finalans = para_ans
            quietly keep interview__id para_var sk_finalans
            quietly save `"`FSTATE'"'
            local hasfstate 1
        }
        restore
    }

    * responsible (same rule as timing: at the last answer, else at the last event)''',
        "insert vars marker and final-state lookup",
    )

    # Replace the run detector and make previous/next timing bounded and nonnegative.
    old_detector = '''    * runs of consecutive AnswerRemoved events
    tempvar rise
    quietly by interview__id: gen byte `rise' = para_rem & para_rem[_n-1]!=1
    quietly by interview__id: gen double sk_run = sum(`rise')
    quietly bysort interview__id sk_run para_rem (para_ord para_seq): ///
        gen long sk_len = _N if para_rem
    quietly by interview__id sk_run para_rem: gen byte sk_first = (_n==1) & para_rem

    * cascade test on the first removal of each run (missing-safe: . <= x is false)
    quietly gen byte sk_casc1 = sk_first & sk_len>=`cascade' & !missing(sk_len)   ///
        & (para_tsu - sk_lastts) <= `window'*1000 & sk_lastvar!=""
    quietly by interview__id sk_run para_rem: gen byte sk_casc = (sk_casc1[1]==1) if para_rem
    quietly replace sk_casc = 0 if missing(sk_casc)
    quietly gen sk_trig = sk_lastvar if sk_casc1
    quietly by interview__id sk_run para_rem: replace sk_trig = sk_trig[1] if sk_casc & para_rem

    quietly count if sk_casc1
    local ncasc = r(N)
    quietly count if sk_casc
    local nwiped = r(N)
'''
    new_detector = '''    * Runs are constructed on the FULL event stream. The whole removal run must
    * be compact, and a candidate gate may be the nearest AnswerSet immediately
    * before OR after the run (SuSo versions differ in event ordering).
    sort interview__id para_ord para_seq
    tempvar rise rmin rmax rspan dtprev dtnext prevnear nextnear
    quietly by interview__id: gen byte `rise' = para_rem & para_rem[_n-1]!=1
    quietly by interview__id: gen double sk_run = sum(`rise')
    quietly bysort interview__id sk_run para_rem (para_ord para_seq): ///
        gen long sk_len = _N if para_rem
    quietly by interview__id sk_run para_rem: gen byte sk_first = (_n==1) & para_rem
    quietly egen double `rmin' = min(cond(para_rem, para_tsu, .)), by(interview__id sk_run)
    quietly egen double `rmax' = max(cond(para_rem, para_tsu, .)), by(interview__id sk_run)
    quietly gen double `rspan' = `rmax' - `rmin'
    quietly gen double `dtprev' = para_tsu - sk_lastts if sk_first
    quietly gen double `dtnext' = sk_nextts - para_tsu if sk_first
    quietly gen byte `prevnear' = sk_first & sk_len>=`cascade' & !missing(sk_len) ///
        & inrange(`dtprev', 0, `window'*1000) & `rspan'<=`window'*1000 & sk_lastvar!=""
    quietly gen byte `nextnear' = sk_first & sk_len>=`cascade' & !missing(sk_len) ///
        & inrange(`dtnext', 0, `window'*1000) & `rspan'<=`window'*1000 & sk_nextvar!=""
    quietly gen byte sk_prevnear = `prevnear'
    quietly gen byte sk_nextnear = `nextnear'
    quietly gen byte sk_casc1 = sk_prevnear | sk_nextnear
    quietly by interview__id sk_run para_rem: gen byte sk_casc = (sk_casc1[1]==1) if para_rem
    quietly replace sk_casc = 0 if missing(sk_casc)
    quietly gen sk_trig = cond(sk_prevnear, sk_lastvar, sk_nextvar) if sk_casc1
    quietly by interview__id sk_run para_rem: replace sk_trig = sk_trig[1] if sk_casc & para_rem

    * Apply vars() only AFTER a run exists. Keep a run when either its candidate
    * trigger or at least one affected question matches the requested patterns.
    if `"`vars'"'!="" {
        tempvar remsel runsel trigsel
        quietly gen byte `remsel' = sk_vsel & para_rem
        quietly egen byte `runsel' = max(`remsel'), by(interview__id sk_run)
        quietly gen byte `trigsel' = 0
        foreach p of local vars {
            quietly replace `trigsel' = 1 if sk_casc & strmatch(sk_trig, "`p'")
        }
        quietly replace sk_casc1 = 0 if sk_casc1 & `runsel'==0 & `trigsel'==0
        quietly replace sk_casc  = 0 if sk_casc  & `runsel'==0 & `trigsel'==0
        quietly replace sk_trig = "" if !sk_casc
    }

    * Determine the final state of each distinct question affected by each run.
    if `hasfstate' {
        quietly merge m:1 interview__id para_var using `"`FSTATE'"', ///
            keep(master match) nogenerate
    }
    else quietly gen byte sk_finalans = .
    tempvar qtag
    if `hasvar' {
        quietly egen byte `qtag' = tag(interview__id sk_run para_var) ///
            if sk_casc & para_rem & para_var!=""
        quietly replace `qtag' = 0 if missing(`qtag')
        quietly gen byte sk_qtag = `qtag'
    }
    else quietly gen byte sk_qtag = sk_casc
    quietly gen byte sk_reanswered = sk_qtag & sk_finalans==1
    quietly gen byte sk_open       = sk_qtag & sk_finalans==0
    quietly gen byte sk_unknown    = sk_qtag & missing(sk_finalans)

    quietly count if sk_casc1
    local ncasc = r(N)
    quietly count if sk_casc
    local nremevents = r(N)
    quietly count if sk_qtag
    local nwiped = r(N)
    quietly count if sk_reanswered
    local nreansweredall = r(N)
    quietly count if sk_open
    local nopenall = r(N)
    quietly count if sk_unknown
    local nunknownall = r(N)
'''
    text = replace_once(text, old_detector, new_detector, "replace cascade detector")

    old_detail = '''        quietly keep if sk_casc
        quietly gen sk_val = sk_lastval
        sort interview__id sk_run para_ord para_seq
        quietly by interview__id sk_run: gen long sk_k = _n
        quietly gen strL sk_wl = ""
        if `hasvar' {
            quietly by interview__id sk_run: replace sk_wl =                     ///
                cond(sk_k==1, para_var, cond(sk_k<=8, sk_wl[_n-1]+", "+para_var, sk_wl[_n-1]))
        }
        collapse (last) wl=sk_wl avar=sk_nextvar aval=sk_nextval               ///
            (max) ats=sk_nextts tend=para_tsu                                    ///
            (count) nrem=sk_k (min) ts0=para_tsu                                 ///
            (first) trigger=sk_trig trigval=sk_val actor=sk_actor resp=sk_resp,  ///
            by(interview__id sk_run) fast
        quietly replace avar = "" if missing(ats) | (ats - tend) > `window'*1000
'''
    new_detail = '''        quietly keep if sk_casc
        quietly gen sk_val = cond(sk_prevnear, sk_lastval, sk_nextval)
        sort interview__id sk_run para_ord para_seq
        quietly by interview__id sk_run: gen long sk_k = _n
        quietly gen strL sk_wl = ""
        if `hasvar' {
            quietly by interview__id sk_run: replace sk_wl = ///
                cond(_n==1, cond(sk_qtag, para_var, ""), ///
                cond(sk_qtag, sk_wl[_n-1] + cond(sk_wl[_n-1]=="", "", ", ") + para_var, sk_wl[_n-1]))
        }
        collapse (last) wl=sk_wl avar=sk_nextvar aval=sk_nextval               ///
            (max) ats=sk_nextts tend=para_tsu                                    ///
            (count) nrem=sk_k (sum) nqrem=sk_qtag nreanswered=sk_reanswered    ///
            nopen=sk_open nunknown=sk_unknown (min) ts0=para_tsu                ///
            (first) trigger=sk_trig trigval=sk_val actor=sk_actor resp=sk_resp,  ///
            by(interview__id sk_run) fast
        quietly replace avar = "" if missing(ats) | (ats-tend)<0 | (ats-tend)>`window'*1000
'''
    text = replace_once(text, old_detail, new_detail, "add final-state counts to detail")

    # Stage 1/2: aggregate distinct affected questions and their final states.
    text = replace_once(
        text,
        '''    collapse (sum) n_answers=para_ans n_removed=para_rem n_cascades=sk_casc1     ///
        casc_removed=sk_casc (first) responsible=sk_resp,                        ///
        by(interview__id sk_trig) fast''',
        '''    collapse (sum) n_answers=para_ans n_removed=para_rem n_cascades=sk_casc1     ///
        casc_removed=sk_qtag casc_open=sk_open casc_reanswered=sk_reanswered     ///
        casc_unknown=sk_unknown (first) responsible=sk_resp,                    ///
        by(interview__id sk_trig) fast''',
        "stage-1 final-state aggregation",
    )
    text = replace_once(
        text,
        '''    collapse (sum) n_answers n_removed n_cascades casc_removed n_triggers=sk_tg  ///
        (first) responsible, by(interview__id) fast''',
        '''    collapse (sum) n_answers n_removed n_cascades casc_removed casc_open          ///
        casc_reanswered casc_unknown n_triggers=sk_tg                              ///
        (first) responsible, by(interview__id) fast''',
        "stage-2 final-state aggregation",
    )
    text = replace_once(
        text,
        '''    label variable casc_removed  "answers wiped by cascades"
    label variable n_triggers    "distinct gate variables flipped"
    label variable wipe_share    "wiped / answers set"''',
        '''    label variable casc_removed    "distinct questions affected by removal runs"
    label variable casc_open       "affected questions whose final event is AnswerRemoved"
    label variable casc_reanswered "affected questions re-answered later"
    label variable casc_unknown    "affected questions with unknown final state"
    label variable n_triggers      "distinct candidate gate variables"
    label variable wipe_share      "historically affected / answers set"''',
        "update aggregate labels",
    )

    text = replace_once(
        text,
        '''    di as txt "  cascades " as res "`ncasc'" as txt "  |  answers wiped " as res "`nwiped'" ///
        as txt "  |  interviews affected " as res "`naff'" as txt " of " as res "`nints'"''',
        '''    di as txt "  cascades " as res "`ncasc'" as txt "  |  questions affected historically " as res "`nwiped'" ///
        as txt "  |  re-answered later " as res "`nreansweredall'" as txt "  |  still removed " as res "`nopenall'" ///
        as txt "  |  interviews affected " as res "`naff'" as txt " of " as res "`nints'"''',
        "safe cascade summary",
    )

    # Triage should weight distinct questions, not duplicate removal events.
    text = text.replace("quietly egen long __wint = total(nrem), by(interview__id)",
                        "quietly egen long __wint = total(nqrem), by(interview__id)")
    text = text.replace("if allsvc==1 & nrem>=20", "if allsvc==1 & nqrem>=20")
    text = text.replace("local inv_w_`rr' = `inv_w_`rr'' + nrem[`r']",
                        "local inv_w_`rr' = `inv_w_`rr'' + nqrem[`r']")
    text = text.replace("gsort -nrem interview__id sk_run",
                        "gsort -nqrem -nrem interview__id sk_run")
    text = text.replace("quietly gen long __w = nrem",
                        "quietly gen long __w = nqrem")
    text = text.replace("cond(nrem>=5, \" big\", \"\")",
                        "cond(nqrem>=5, \" big\", \"\")")

    # Safe, historically accurate case text with final-state accounting.
    old_mwhat = '''        quietly gen strL m_what = "WHAT HAPPENED: the answer to [" + trigger + "] was changed"
        quietly replace m_what = m_what + " to " + char(34) + trigval + char(34) if trigval!=""
        quietly replace m_what = m_what + " after " + strofreal(nrem)                   ///
            + " later answer(s) had already been recorded. The skip logic then ERASED those " ///
            + strofreal(nrem) + " answer(s)."
'''
    new_mwhat = '''        quietly gen strL m_what = "PARADATA HISTORY: " + strofreal(nrem) ///
            + " AnswerRemoved event(s) affected " + strofreal(nqrem) ///
            + " distinct question(s) near an answer change to [" + trigger + "]"
        quietly replace m_what = m_what + " = " + char(34) + trigval + char(34) if trigval!=""
        quietly replace m_what = m_what + ". Final paradata event state: " ///
            + strofreal(nreanswered) + " re-answered later; " + strofreal(nopen) ///
            + " still end in AnswerRemoved; " + strofreal(nunknown) + " unknown."
'''
    text = replace_once(text, old_mwhat, new_mwhat, "safe case narrative")
    text = text.replace('"ERASED ANSWERS: " + substr(wl,1,300)',
                        '"HISTORICALLY AFFECTED QUESTIONS: " + substr(wl,1,300)')
    text = text.replace("the erased questions depend on", "the affected questions depend on")
    text = text.replace("none of the erased questions depends on", "none of the affected questions depends on")

    insert_after_mc = '''            quietly replace m_c = "CAUTION: timing points to [" + trigger + "] but none of the affected questions depends on it - verify in the interview history before raising this with the enumerator." if conf==0 & allsvc==0
        }
'''
    new_after_mc = insert_after_mc + '''        quietly gen strL m_a = "ACTION: review the interview history and the final export. "
        quietly replace m_a = m_a + "All affected questions were re-answered later; this removal run alone is not a reason to reject the interview." if nopen==0 & nunknown==0
        quietly replace m_a = m_a + strofreal(nopen) + " question(s) still end in AnswerRemoved and " + strofreal(nunknown) + " have unknown final state. Reject only if the final export confirms a question is blank and the final questionnaire logic says it should be asked." if nopen>0 | nunknown>0
'''
    text = replace_once(text, insert_after_mc, new_after_mc, "add safe action text")
    text = text.replace("foreach mv in m_q m_s m_e m_w m_c {",
                        "foreach mv in m_q m_s m_e m_w m_c m_a {")

    old_action = '''            di as txt "  ACTION: 1. Open this interview in Headquarters and check the changed question."
            di as txt "          2. Ask the enumerator why it changed after the later questions were done."
            di as txt "          3. If the NEW value is correct: REJECT the interview so the erased"
            di as txt "             questions are asked again - they are empty now."
            di as txt "          4. If the OLD value was correct: restore it and verify the answers below it."
            if `mh' {
                file write `mf' "ACTION: 1. Open this interview in Headquarters and check the changed question." _n
                file write `mf' "        2. Ask the enumerator why it changed after the later questions were done." _n
                file write `mf' "        3. If the NEW value is correct: REJECT the interview so the erased questions are asked again - they are empty now." _n
                file write `mf' "        4. If the OLD value was correct: restore it and verify the answers below it." _n
            }
'''
    text = replace_once(text, old_action, "", "remove unconditional rejection instructions")

    # Message-file overview.
    text = text.replace(
        '''            file write `mf' "Definition: a case is `cascade' or more answers erased by the skip logic within `window' seconds of an answer being changed." _n
            file write `mf' "`ncasc' case(s) found, `nwiped' answers erased in total." _n''',
        '''            file write `mf' "Definition: a case is `cascade' or more consecutive AnswerRemoved events in a compact run near an AnswerSet event." _n
            file write `mf' "`ncasc' case(s) found; `nwiped' distinct question-case(s) affected historically; `nreansweredall' re-answered later; `nopenall' still end in AnswerRemoved; `nunknownall' unknown." _n''',
    )

    # Standalone HTML cards/banner and per-case text.
    text = text.replace(
        '''            quietly gen strL h_chip = "<div class=" + char(34) + "chip" + char(34) + ">" + strofreal(nrem) + " erased</div>"''',
        '''            quietly gen strL h_chip = "<div class=" + char(34) + "chip" + char(34) + ">" + strofreal(nqrem) + " affected; " + strofreal(nopen) + " still removed</div>"''',
    )
    old_hl2 = '''            quietly gen strL h_l2 = "<div class=" + char(34) + "c2" + char(34) + ">The answer to <b class=" + char(34) + "mono" + char(34) + ">" + h_tg + "</b> was changed"
            quietly replace h_l2 = h_l2 + " from &quot;" + h_ov0 + "&quot;" if h_ov0!="" & h_ov0!=h_tv0
            quietly replace h_l2 = h_l2 + " to &quot;" + h_tv0 + "&quot;" if h_tv0!=""
            quietly replace h_l2 = h_l2 + " after <b>" + strofreal(nrem) + "</b> later answers were recorded - the skip logic erased them.</div>"
'''
    new_hl2 = '''            quietly gen strL h_l2 = "<div class=" + char(34) + "c2" + char(34) + ">Paradata logged <b>" + strofreal(nrem) + "</b> AnswerRemoved event(s), affecting <b>" + strofreal(nqrem) + "</b> distinct question(s), near an answer change to <b class=" + char(34) + "mono" + char(34) + ">" + h_tg + "</b>"
            quietly replace h_l2 = h_l2 + " from &quot;" + h_ov0 + "&quot;" if h_ov0!="" & h_ov0!=h_tv0
            quietly replace h_l2 = h_l2 + " to &quot;" + h_tv0 + "&quot;" if h_tv0!=""
            quietly replace h_l2 = h_l2 + ". Final paradata state: <b>" + strofreal(nreanswered) + "</b> re-answered later; <b>" + strofreal(nopen) + "</b> still end in AnswerRemoved; <b>" + strofreal(nunknown) + "</b> unknown.</div>"
'''
    text = replace_once(text, old_hl2, new_hl2, "safe standalone HTML case narrative")
    text = text.replace('">Erased: <span class="', '">Historically affected: <span class="')
    old_hdo = '''            quietly gen strL h_do = ""
            quietly replace h_do = "<div class=" + char(34) + "meta do" + char(34) + ">Do: if &quot;" + h_tv0 + "&quot; is correct, <b>reject the interview</b> so the erased answers are re-asked (they are empty now); if " ///
                + cond(h_ov0!="" & h_ov0!=h_tv0, "&quot;" + h_ov0 + "&quot;", "the old answer") ///
                + " was correct, restore it and verify the section.</div>" if h_tv0!=""
'''
    new_hdo = '''            quietly gen strL h_do = "<div class=" + char(34) + "meta do" + char(34) + ">Review the history and final export. "
            quietly replace h_do = h_do + "All affected questions were re-answered later; this historical removal run alone is not a reason to reject.</div>" if nopen==0 & nunknown==0
            quietly replace h_do = h_do + "Reject only if the final export confirms one of the " + strofreal(nopen) + " still-removed or " + strofreal(nunknown) + " unknown question(s) is actually blank and should be enabled.</div>" if nopen>0 | nunknown>0
'''
    text = replace_once(text, old_hdo, new_hdo, "safe standalone HTML action")
    text = text.replace(
        '''            file write `hf' `"<div class="card"><div class="v">`nwiped'</div><div class="k">answers erased</div></div>"' _n
            file write `hf' `"<div class="card"><div class="v">`nintaff'</div><div class="k">interviews affected</div></div>"' _n
            file write `hf' `"<div class="card"><div class="v">`ngates'</div><div class="k">gate questions involved</div></div>"' _n''',
        '''            file write `hf' `"<div class="card"><div class="v">`nwiped'</div><div class="k">questions affected historically</div></div>"' _n
            file write `hf' `"<div class="card"><div class="v">`nopenall'</div><div class="k">still removed at final event</div></div>"' _n
            file write `hf' `"<div class="card"><div class="v">`nreansweredall'</div><div class="k">re-answered later</div></div>"' _n''',
    )
    text = text.replace(
        '''            file write `hf' `"<div class="how"><b>How to handle every case below:</b> open the interview in Headquarters and check the changed question; ask the enumerator why it changed after the later questions were done; if the NEW value is correct, <b>reject the interview</b> so the erased questions are asked again (they are empty now); if the OLD value was correct, restore it and verify the answers below it. Occasional cases are honest corrections - the pattern to challenge is the same gate erased across many interviews, or one enumerator producing many cases.</div>"' _n''',
        '''            file write `hf' `"<div class="how"><b>How to handle these historical removal runs:</b> review the interview history and final export. A removal event does not mean the answer is still blank; many affected questions are answered again later. Reject only when the final export confirms that a question is actually blank and the final questionnaire logic says it should be asked.</div>"' _n''',
    )
    text = text.replace("answers erased, in ", "questions affected, in ")
    text = text.replace("answers erased</th>", "questions affected</th>")
    text = text.replace("answers erased, ", "questions affected, ")
    text = text.replace("answers erased across sections", "questions affected across sections")

    # Return final-state counts.
    text = replace_once(
        text,
        '''    return scalar nwiped    = `nwiped'
    return scalar naffected = `naff'
end''',
        '''    return scalar nwiped       = `nwiped'
    return scalar nremovalevents = `nremevents'
    return scalar nreanswered  = `nreansweredall'
    return scalar nopen        = `nopenall'
    return scalar nunknown     = `nunknownall'
    return scalar naffected    = `naff'
end''',
        "return final-state counts",
    )

    # 2) Report: preserve a full copy for cascade detection, filter only behavior metrics.
    text = replace_once(
        text,
        '''    _suso_para_need events
    _suso_para_varsel , vars(`"`vars'"')

    if `"`saving'"'=="" local saving "suso_paradata_qc.html"''',
        '''    _suso_para_need events
    tempfile EVFULL
    quietly save `"`EVFULL'"'
    _suso_para_varsel , vars(`"`vars'"')

    if `"`saving'"'=="" local saving "suso_paradata_qc.html"''',
        "save full stream before report vars filter",
    )
    text = replace_once(
        text,
        '''    quietly use `"`EV'"', clear
    quietly _suso_para_skips , cascade(`cascade') window(`window') qx(`"`qx'"') detail(`"`RSD'"')''',
        '''    quietly use `"`EVFULL'"', clear
    quietly _suso_para_skips , cascade(`cascade') window(`window') qx(`"`qx'"') ///
        detail(`"`RSD'"') vars(`"`vars'"')''',
        "run report skips on full stream",
    )
    text = replace_once(
        text,
        '''    local nwiped = r(nwiped)
    local trignames''',
        '''    local nwiped = r(nwiped)
    local nopen = r(nopen)
    local nreanswered = r(nreanswered)
    local nunknown = r(nunknown)
    local trignames''',
        "capture report final-state totals",
    )
    text = text.replace(
        '''    quietly keep interview__id n_cascades casc_removed n_triggers''',
        '''    quietly keep interview__id n_cascades casc_removed casc_open casc_reanswered casc_unknown n_triggers''',
    )
    text = text.replace(
        '''    foreach v in n_cascades casc_removed n_triggers {''',
        '''    foreach v in n_cascades casc_removed casc_open casc_reanswered casc_unknown n_triggers {''',
    )
    text = text.replace(
        '''<div class="k">skip cascades (`nwiped' wiped)</div>''',
        '''<div class="k">skip cascades (`nwiped' affected; `nopen' still removed)</div>''',
    )
    text = text.replace("<h2>Gate variables wiping answers</h2>", "<h2>Candidate gate variables near removal runs</h2>")
    text = text.replace(
        "Occasional cascades are honest corrections; the same gate flipped across many interviews is skip abuse or a badly worded filter.",
        "These are historical removal runs. Affected questions may be re-answered later; repeated patterns still warrant review.",
    )
    text = text.replace("<th class=\"r\">answers wiped</th>", "<th class=\"r\">questions affected</th>")

    # Report's static supervisor section must also be final-state aware.
    text = text.replace(
        '''        file write `fh' `"<div class="note">One entry per skip violation, largest first. If the new gate value is right, the interview should be rejected so the erased questions are re-asked; if the old value was right, restore it and verify the section. For an email-ready version run: suso paradata skips , qx(questionnaire.html) messages(review.txt)</div>"' _n''',
        '''        file write `fh' `"<div class="note">One entry per historical removal run, largest first. Review the history and final export; reject only when a question is actually blank and should be enabled. For an email-ready version run: suso paradata skips , qx(questionnaire.html) messages(review.txt)</div>"' _n''',
    )
    old_static = '''            file write `fh' `"<div style="font-size:12.5px;margin-top:3px">The answer to <b class="mono">"' (e_tg[`i']) `"</b> was changed"' (e_tv[`i']) `" after <b>"' (strofreal(nrem[`i'])) `"</b> later answers were recorded - the skip logic erased them.</div>"' _n'''
    new_static = '''            file write `fh' `"<div style="font-size:12.5px;margin-top:3px">Paradata logged <b>"' (strofreal(nrem[`i'])) `"</b> AnswerRemoved event(s), affecting <b>"' (strofreal(nqrem[`i'])) `"</b> distinct question(s), near an answer change to <b class="mono">"' (e_tg[`i']) `"</b>"' (e_tv[`i']) `". Final state: <b>"' (strofreal(nreanswered[`i'])) `"</b> re-answered; <b>"' (strofreal(nopen[`i'])) `"</b> still removed; <b>"' (strofreal(nunknown[`i'])) `"</b> unknown.</div>"' _n'''
    text = replace_once(text, old_static, new_static, "safe report static case")
    text = text.replace("Erased: <span class=", "Historically affected: <span class=")
    text = text.replace("strofreal(nrem-8)", "strofreal(nqrem-8)")
    text = text.replace("if nrem>8 & e_wl!=\"\"", "if nqrem>8 & e_wl!=\"\"")

    # Embed final-state fields and use safe browser evidence.
    text = text.replace(
        '''"cas":`=n_cascades[`i']',"wip":`=casc_removed[`i']',"fr":''',
        '''"cas":`=n_cascades[`i']',"wip":`=casc_removed[`i']',"cop":`=casc_open[`i']',"cr":`=casc_reanswered[`i']',"cu":`=casc_unknown[`i']',"fr":''',
    )
    text = text.replace(
        '''    file write `fh' `"    if(row.cas>0) out.push({t:'flag', s:'A gate flip erased '+row.wip+' recorded answer(s) - details in the skip sections below.'});"' _n''',
        '''    file write `fh' `"    if(row.cas>0) out.push({t:'flag', s:'Historical removal run affected '+row.wip+' distinct question(s): '+row.cr+' re-answered later, '+row.cop+' still removed, '+row.cu+' unknown - details in the skip sections below.'});"' _n''',
    )
    text = text.replace(
        "Skip cascade: a gate answer flip erased later answers",
        "Historical removal run; affected questions may have been re-answered",
    )
    text = text.replace("answers_wiped", "questions_affected")

    # 3) Suite: never prefilter the shared event stream; delegate vars() safely.
    suite_start = '''    _suso_para_need events
    _suso_para_varsel , vars(`"`vars'"')
    if `"`saving'"'=="" local saving "suso_qc_suite.html"'''
    suite_new = '''    _suso_para_need events
    if `"`saving'"'=="" local saving "suso_qc_suite.html"'''
    text = replace_once(text, suite_start, suite_new, "remove suite prefilter")
    text = replace_once(
        text,
        '''        data(`"`data'"') filters(`"`filters'"')                                    ///
        gapmins(`gapmins') fastsecs(`fastsecs') `allroles'                        ///''',
        '''        data(`"`data'"') filters(`"`filters'"') vars(`"`vars'"')                  ///
        gapmins(`gapmins') fastsecs(`fastsecs') `allroles'                        ///''',
        "pass vars to report from suite",
    )
    text = replace_once(
        text,
        '''        qx(`"`qx'"') html(`"`T2'"') replace''',
        '''        qx(`"`qx'"') html(`"`T2'"') vars(`"`vars'"') replace''',
        "pass vars to skips from suite",
    )

    # Remove every remaining current-state assertion that was known to be unsafe.
    forbidden = [
        "they are empty now",
        "the skip logic erased them",
        "are re-asked (they are empty now)",
    ]
    for phrase in forbidden:
        if phrase in text:
            raise RuntimeError(f"{path}: unsafe phrase remains: {phrase!r}")

    path.write_text(text, encoding="utf-8")
    validate(path, path.read_bytes())


def validate(path: Path, raw: bytes) -> None:
    if b"\x08" in raw:
        raise RuntimeError(f"{path}: raw backspace byte remains")
    text = raw.decode("utf-8")
    required = [
        "*! suso v1.7.1",
        "vars() is an output filter only",
        "sk_reanswered",
        "sk_open",
        "sk_unknown",
        "inrange(`dtprev', 0, `window'*1000)",
        "inrange(`dtnext', 0, `window'*1000)",
        "quietly use `\"`EVFULL'\"', clear",
        "All affected questions were re-answered later",
    ]
    for item in required:
        if item not in text:
            raise RuntimeError(f"{path}: required patch marker missing: {item}")
    skips = text[text.index("program _suso_para_skips"):text.index("* ---- report:", text.index("program _suso_para_skips"))]
    if "_suso_para_varsel" in skips:
        raise RuntimeError(f"{path}: skips still prefilters the event stream")
    suite = text[text.index("program _suso_para_suite"):text.index("*===============================================================================\n* examples", text.index("program _suso_para_suite"))]
    head = suite.split('if `"`saving\'"\'==""', 1)[0]
    if "_suso_para_varsel" in head:
        raise RuntimeError(f"{path}: suite still prefilters the shared event stream")
    for phrase in ("they are empty now", "the skip logic erased them"):
        if phrase in text:
            raise RuntimeError(f"{path}: unsafe current-state assertion remains: {phrase}")


def write_tests() -> None:
    p = Path("tests/test_paradata_skip_integrity.py")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(r'''from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADO = (ROOT / "suso.ado").read_bytes()
TEXT = ADO.decode("utf-8")


def _section(start: str, end: str) -> str:
    i = TEXT.index(start)
    j = TEXT.index(end, i)
    return TEXT[i:j]


def test_no_raw_backspace_regex_bytes():
    assert b"\x08" not in ADO
    assert "\\b`av'\\b" in TEXT
    assert "\\b`bv'\\b" in TEXT


def test_skips_detects_on_full_stream_then_filters():
    s = _section("program _suso_para_skips", "* ---- report:")
    assert "_suso_para_varsel" not in s
    assert "vars() is an output filter only" in s
    assert "sk_vsel" in s and "runsel" in s and "trigsel" in s


def test_report_and_suite_preserve_event_adjacency():
    r = _section("program _suso_para_report", "* ---- helper: escape text for HTML")
    assert "tempfile EVFULL" in r
    assert 'quietly use `"`EVFULL\'"\', clear' in r
    assert 'vars(`"`vars\'"\')' in r
    q = _section("program _suso_para_suite", "*===============================================================================\n* examples")
    prefix = q.split('if `"`saving\'"\'==""', 1)[0]
    assert "_suso_para_varsel" not in prefix
    assert q.count('vars(`"`vars\'"\')') >= 2


def test_final_state_is_computed_and_reported_safely():
    assert "sk_finalans" in TEXT
    assert "sk_reanswered" in TEXT
    assert "sk_open" in TEXT
    assert "sk_unknown" in TEXT
    assert "All affected questions were re-answered later" in TEXT
    assert "they are empty now" not in TEXT
    assert "the skip logic erased them" not in TEXT


def test_time_window_is_nonnegative_and_supports_both_event_orders():
    assert "inrange(`dtprev', 0, `window'*1000)" in TEXT
    assert "inrange(`dtnext', 0, `window'*1000)" in TEXT
    assert "sk_prevnear | sk_nextnear" in TEXT
    assert "`rspan'<=`window'*1000" in TEXT


def test_reanswer_model():
    events = [
        ("q1", "AnswerRemoved"),
        ("q2", "AnswerRemoved"),
        ("q1", "AnswerSet"),
    ]
    final = {}
    for var, event in events:
        final[var] = event
    assert final["q1"] == "AnswerSet"
    assert final["q2"] == "AnswerRemoved"


def test_filtering_after_detection_cannot_create_adjacency():
    stream = [
        ("AnswerRemoved", "l6"),
        ("AnswerSet", "other"),
        ("AnswerRemoved", "l3"),
        ("AnswerSet", "other2"),
        ("AnswerRemoved", "l7a"),
    ]
    raw_runs = []
    run = []
    for event, var in stream:
        if event == "AnswerRemoved":
            run.append(var)
        else:
            if run:
                raw_runs.append(run)
                run = []
    if run:
        raw_runs.append(run)
    assert max(map(len, raw_runs)) == 1
    selected = [r for r in raw_runs if any(v.startswith("l") for v in r)]
    assert max(map(len, selected)) == 1


def test_install_copy_matches_root():
    assert (ROOT / "install" / "suso.ado").read_bytes() == ADO
''', encoding="utf-8")


def main() -> None:
    for p in FILES:
        if not p.exists():
            raise RuntimeError(f"missing {p}")
    if FILES[0].read_bytes() != FILES[1].read_bytes():
        raise RuntimeError("root and install suso.ado differ before patch")
    for p in FILES:
        patch_file(p)
    if FILES[0].read_bytes() != FILES[1].read_bytes():
        raise RuntimeError("root and install suso.ado differ after patch")
    write_tests()
    print("patched:", ", ".join(map(str, FILES)))
    print("wrote: tests/test_paradata_skip_integrity.py")


if __name__ == "__main__":
    main()
