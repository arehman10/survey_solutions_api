version 14.2
set more off
* Run from this package root in a fresh licensed Stata session.
* Exercises the production allocator and Mata serializer; no API/Java required.
* Input intervals are hand-built to isolate attribution from event derivation.
adopath ++ "."
quietly suso about

capture program drop _suso_test_sections
program _suso_test_sections
    version 14.2
    preserve
    tempfile qmap events payload unmapped numeric
    clear
    input str80 para_var long section_id
    "employees" 1
    "sales" 3
    end
    save `"`qmap'"'
    clear
    input str8 interview__id str8 para_actor_key long para_session str80 para_var str24 para_ev double para_act byte para_firstpass byte para_clockback
    "i1" "alpha" 1 ""          "interviewrestarted" 0   1 0
    "i1" "alpha" 1 "employees" "answerset"          60  1 0
    "i1" "alpha" 1 "sales"     "answerdeclaredvalid" 5  1 0
    "i1" "alpha" 1 ""          "resumed"            15  1 0
    "i1" "alpha" 1 "sales"     "answerset"          120 1 0
    "i1" "alpha" 1 "unknown"   "answerremoved"      30  1 0
    "i1" "alpha" 1 ""          "paused"             5   1 0
    "i1" "alpha" 2 ""          "resumed"            10  0 0
    "i1" "alpha" 2 "employees" "answerset"          40  0 0
    "i1" "beta"  3 ""          "resumed"            7   0 0
    "i1" "beta"  3 "sales"     "commentset"         20  0 0
    "i2" "alpha" 1 "employees" "answerset"          0   1 1
    end
    gen str8 para_actor = para_actor_key
    gen long para_ord = _n
    gen long para_seq = _n
    gen byte para_ivw = 1
    gen byte para_time_missing = 0
    gen byte para_fieldans = para_ev=="answerset"
    gen byte para_fieldrem = para_ev=="answerremoved"
    save `"`events'"'
    _suso_para_sectionpayload, saving(`"`payload'"') qmap(`"`qmap'"')
    assert _N==12
    assert para_act[5]==120 & para_var[3]=="sales"
    cf _all using `"`events'"'
    use `"`payload'"', clear
    isid interview__id para_actor_key section_id
    assert st_first==80 & st_rework==40 if interview__id=="i1" & section_id==1
    assert st_first==120 & st_rework==0 if interview__id=="i1" & section_id==3 & para_actor_key=="alpha"
    assert st_first==35 & st_rework==10 if interview__id=="i1" & section_id==0 & para_actor_key=="alpha"
    assert st_first==0 & st_rework==7 if interview__id=="i1" & section_id==0 & para_actor_key=="beta"
    assert st_first==0 & st_rework==20 if interview__id=="i1" & section_id==3 & para_actor_key=="beta"
    assert st_first==0 & st_seen_first==1 & st_bad_first==1 if interview__id=="i2"
    summarize st_first, meanonly
    assert r(sum)==235
    summarize st_rework, meanonly
    assert r(sum)==77
    use `"`events'"', clear
    _suso_para_sectionpayload, saving(`"`unmapped'"')
    use `"`unmapped'"', clear
    assert section_id==0
    summarize st_first, meanonly
    assert r(sum)==235
    summarize st_rework, meanonly
    assert r(sum)==77

    * The serialized zero-based lookup and millisecond precision are preserved.
    clear
    set obs 51
    gen long st_actor_index = _n-1
    gen long section_id = 3
    gen double st_first = 1.125
    gen double st_rework = 2.250
    foreach v in st_seen_first st_seen_rework st_bad_first st_bad_rework {
        gen long `v' = 0
    }
    mata: _suso_section_json(st_local("numeric"))
    tempname fh
    file open `fh' using `"`numeric'"', read text
    file read `fh' line
    assert substr(`"`line'"',1,26)=="[0,3,1.125,2.250,0,0,0,0],"
    file read `fh' line
    assert `"`line'"'==",[50,3,1.125,2.250,0,0,0,0]"
    file read `fh' line
    assert r(eof)==1
    file close `fh'

    * An empty eligible stream must still produce a valid empty payload file.
    use `"`events'"', clear
    keep if 0
    tempfile empty
    _suso_para_sectionpayload, saving(`"`empty'"') qmap(`"`qmap'"')
    use `"`empty'"', clear
    assert _N==0
    restore
end
capture noisily _suso_test_sections
local rc = _rc
capture program drop _suso_test_sections
if `rc' exit `rc'
di as result "PASS: section allocation, boundaries, unmapped/rework conservation, data preservation and numeric serialization"
