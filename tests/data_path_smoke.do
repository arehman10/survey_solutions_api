version 14.2
set more off

* Run from the extracted package/repository root in licensed Stata:
*     do tests/data_path_smoke.do
* Uses synthetic data only. The wrapper restores the caller's data on success
* or error. No server, credentials or Java/SFI calls are needed for this file.
adopath ++ "."
quietly suso about
capture program drop _suso_data_path_smoke
program _suso_data_path_smoke
    version 14.2
    preserve
    tempfile raw events detail final cases meta assessed trcases trassessed

    * Shared policy: explicit numeric codes replace the default list. Text that
    * happens to spell a numeric code is still an answer, and IDs are untouched.
    clear
    set obs 4
    gen str12 interview__id="one"
    replace interview__id="two" in 2
    replace interview__id="##N/A##" in 3
    replace interview__id="four" in 4
    gen double answer=-9
    replace answer=-8 in 2
    replace answer=-999999999 in 3
    replace answer=.a in 4
    gen str12 textanswer="-9"
    replace textanswer=" ##n/a## " in 2
    replace textanswer="actual text" in 3
    replace textanswer="" in 4
    _suso_para_missing, misscodes(-9)
    assert missing(answer) in 1
    assert answer==-8 in 2
    assert answer==-999999999 in 3
    assert answer==.a in 4
    assert textanswer=="-9" in 1
    assert textanswer=="" in 2
    assert interview__id=="##N/A##" in 3
    _suso_para_missing
    assert missing(answer) in 3

    * Full-list membership crosses several batch boundaries, including option
    * 61 and option 260. Missing values never become bad-code findings.
    clear
    set obs 10
    gen double answer=1
    replace answer=20 in 2
    replace answer=21 in 3
    replace answer=60 in 4
    replace answer=61 in 5
    replace answer=260 in 6
    replace answer=261 in 7
    replace answer=-1 in 8
    replace answer=. in 9
    replace answer=.a in 10
    gen byte interview__status=100
    replace interview__status=130 in 4
    replace interview__status=130 in 5
    replace interview__status=130 in 6
    replace interview__status=130 in 8
    replace interview__status=130 in 10
    gen byte district=1
    replace district=2 in 3
    replace district=2 in 4
    replace district=2 in 8
    replace district=2 in 9
    local values ""
    forvalues j=1/260 {
        local values "`values' `j'"
    }
    _suso_para_badcodes answer, values(`"`values'"') nopts(260) generate(bad)
    assert r(nbad)==2
    assert bad==inlist(answer,261,-1)
    count if bad & interview__status==100
    assert r(N)==1
    count if bad & district==2
    assert r(N)==1
    capture _suso_para_badcodes answer, values("1 2") nopts(3) generate(badshort)
    assert _rc==459
    capture _suso_para_badcodes answer, values("1 text") nopts(2) generate(badtext)
    assert _rc==459

    * Final answer and enablement use the same normalized final-data copy.
    clear
    set obs 6
    gen str12 interview__id="blank"
    replace interview__id="answered" in 2
    replace interview__id="systemmiss" in 3
    replace interview__id="unknown" in 4
    replace interview__id="unknown2" in 5
    replace interview__id="disabled" in 6
    gen double answer=-9
    replace answer=5 in 2
    replace answer=.a in 3
    gen double gate=1
    replace gate=-9 in 4
    replace gate=.a in 5
    replace gate=0 in 6
    save `"`final'"', replace
    keep interview__id
    gen long sk_run=1
    gen str32 affected_var="answer"
    gen str80 affected_roster=""
    gen str244 affected_qkey=affected_var
    gen str244 affected_qdisp=affected_var
    save `"`cases'"', replace

    clear
    set obs 1
    gen str32 qx_var="answer"
    gen str60 qx_type="Numeric"
    foreach v in qx_section qx_subsection qx_section_enable qx_group_enable ///
        qx_enable_deps qx_calc {
        gen strL `v'=""
    }
    gen strL qx_item_enable="gate==1"
    gen strL qx_enable=qx_item_enable
    gen strL qx_section_tri="1"
    gen strL qx_group_tri="1"
    gen strL qx_item_tri="cond(missing(gate),.5,gate==1)"
    save `"`meta'"', replace
    _suso_para_casefinal using `"`cases'"', data(`"`final'"') ///
        qxmeta(`"`meta'"') saving(`"`assessed'"') misscodes(-9)
    use `"`assessed'"', clear
    assert _N==6
    assert final_status==3 if inlist(interview__id,"blank","systemmiss")
    assert final_status==1 if interview__id=="answered"
    assert final_status==4 if inlist(interview__id,"unknown","unknown2")
    assert final_status==2 if interview__id=="disabled"

    * Trigger final state treats the configured missing gate as blank, too.
    use `"`cases'"', clear
    keep interview__id sk_run
    gen str32 trigger="gate"
    gen str80 trigger_roster=""
    gen strL trigval="1"
    gen strL oldval="0"
    gen strL qx_optmap=""
    gen str60 qx_type="Numeric"
    save `"`trcases'"', replace
    _suso_para_triggerfinal using `"`trcases'"', data(`"`final'"') ///
        saving(`"`trassessed'"') misscodes(-9)
    use `"`trassessed'"', clear
    assert _N==6
    assert trigger_final_status==2 if inlist(interview__id,"unknown","unknown2")
    assert trigger_final_status==1 if interview__id=="disabled"
    assert trigger_final_value=="0" if interview__id=="disabled"
    use `"`final'"', clear
    assert answer==-9 if interview__id=="blank"
    assert gate==-9 if interview__id=="unknown"

    * A five-hour-later answer cannot be a 60-second removal trigger. Exactly
    * 60 seconds is included; equal distance uses the previous answer.
    clear
    set obs 12
    gen str12 interview__id="far"
    replace interview__id="prev" in 4
    replace interview__id="prev" in 5
    replace interview__id="prev" in 6
    replace interview__id="next" in 7
    replace interview__id="next" in 8
    replace interview__id="next" in 9
    replace interview__id="tie" in 10
    replace interview__id="tie" in 11
    replace interview__id="tie" in 12
    gen double order=1
    replace order=2 in 2
    replace order=3 in 3
    replace order=2 in 5
    replace order=3 in 6
    replace order=2 in 8
    replace order=3 in 9
    replace order=2 in 11
    replace order=3 in 12
    gen str30 event="AnswerSet"
    replace event="AnswerRemoved" in 2
    replace event="AnswerRemoved" in 5
    replace event="AnswerRemoved" in 8
    replace event="AnswerRemoved" in 11
    gen str24 responsible="Enumerator A"
    gen str20 role="Interviewer"
    gen str23 timestamp_utc="2026-08-20T09:00:00.000"
    replace timestamp_utc="2026-08-20T10:00:00.000" in 2
    replace timestamp_utc="2026-08-20T15:00:00.000" in 3
    replace timestamp_utc="2026-08-20T09:59:00.000" in 4
    replace timestamp_utc="2026-08-20T10:00:00.000" in 5
    replace timestamp_utc="2026-08-20T15:00:00.000" in 6
    replace timestamp_utc="2026-08-20T10:00:00.000" in 8
    replace timestamp_utc="2026-08-20T10:01:00.000" in 9
    replace timestamp_utc="2026-08-20T09:59:30.000" in 10
    replace timestamp_utc="2026-08-20T10:00:00.000" in 11
    replace timestamp_utc="2026-08-20T10:00:30.000" in 12
    gen str9 tz_offset="+00:00:00"
    gen str80 parameters="gate||1||"
    replace parameters="answer||" in 2
    replace parameters="after||2||" in 3
    replace parameters="answer||" in 5
    replace parameters="after||2||" in 6
    replace parameters="answer||" in 8
    replace parameters="after||2||" in 9
    replace parameters="answer||" in 11
    replace parameters="after||2||" in 12
    save `"`raw'"', replace
    _suso_para_prep
    save `"`events'"', replace
    suso paradata skips, cascade(1) window(60) detail(`"`detail'"') replace
    assert r(nhistories)==4
    assert r(nremovalevents)==4
    assert r(ncascades)==3
    assert r(noutsideevents)==1
    use `"`detail'"', clear
    assert _N==4
    assert trigger=="" & trigval=="" & trigger_qkey=="" if interview__id=="far"
    assert missing(trigger_tsu) & missing(trigger_ord) & missing(trigger_seq) if interview__id=="far"
    assert strpos(transition_text,"No answer event within the selected window")>0 if interview__id=="far"
    assert trigger=="gate" if inlist(interview__id,"prev","tie")
    assert trigger=="after" if interview__id=="next"

    * A genuinely reduced export omits Parameters entirely. Keep every removal
    * and give it an unknown identity rather than stopping with r(111).
    use `"`raw'"', clear
    drop parameters
    _suso_para_prep
    capture confirm variable para_var, exact
    assert _rc==111
    suso paradata skips, cascade(1) window(60) detail(`"`detail'"') replace
    assert r(nhistories)==4
    assert r(nremovalevents)==4
    assert r(ncascades)==0
    use `"`detail'"', clear
    assert _N==4
    assert trigger==""
    assert n_identityunknown==1
    restore
end
capture noisily _suso_data_path_smoke
local smoke_rc=_rc
capture program drop _suso_data_path_smoke
if `smoke_rc' exit `smoke_rc'
di as result "PASS: synthetic missing-policy, full-option-list, trigger-window and reduced-export Stata tests."
