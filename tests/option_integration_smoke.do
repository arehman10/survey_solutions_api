version 14.2
set more off

* Licensed Stata + the packaged Java/SFI bridge are required. Run from the
* extracted package/repository root. Everything is synthetic and offline.
adopath ++ "."
quietly suso about
capture program drop _suso_option_integration_smoke
program _suso_option_integration_smoke
    version 14.2
    preserve
    tempfile questionnaire final results parsed html
    tempname qf
    file open `qf' using `"`questionnaire'"', write text replace
    file write `qf' `"<!doctype html><html><body><section class="section"><div class="section_header"><h2 id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">SYNTHETIC OPTION TEST</h2></div>"' _n
    file write `qf' `"<div class="question-container" id="11111111111111111111111111111111"><div class="question"><div class="question-title">Choose one of 61 values</div><div class="common-info"></div></div><div class="answer"><div class="question-meta"><div class="type">single-select</div><div class="variable_name">gate</div></div><div class="answer-editor">"' _n
    forvalues j=1/61 {
        file write `qf' `"<div class="option"><div class="option-value"><span >`j'</span></div><div class="option-text"><label>Option `j'</label></div></div>"' _n
    }
    file write `qf' "</div></div></div>" _n
    file write `qf' `"<div class="question-container" id="22222222222222222222222222222222"><div class="question"><div class="question-title">Enabled only when gate is one</div><div class="common-info"><div class="condition"><span>E</span>gate==1</div></div></div><div class="answer"><div class="question-meta"><div class="type">numeric: integer</div><div class="variable_name">answer</div></div></div></div></section></body></html>"' _n
    file close `qf'
    suso paradata qx, file(`"`questionnaire'"') saving(`"`parsed'"') replace
    assert qx_nopts==61 if qx_var=="gate"
    count if qx_var=="gate" & strpos(" "+qx_optvals+" "," 61 ")>0
    assert r(N)==1

    clear
    set obs 4
    gen str12 interview__id="valid61"
    replace interview__id="invalid" in 2
    replace interview__id="missing" in 3
    replace interview__id="enabledblank" in 4
    gen double gate=61
    replace gate=999 in 2
    replace gate=-9 in 3
    replace gate=1 in 4
    gen double answer=.
    replace answer=-9 in 4
    gen int interview__status=130
    replace interview__status=100 in 2
    replace interview__status=100 in 4
    gen byte district=1
    replace district=2 in 2
    replace district=2 in 3
    save `"`final'"', replace
    suso paradata check, qx(`"`questionnaire'"') data(`"`final'"') ///
        misscodes(-9) filters(district) saving(`"`results'"') html(`"`html'"') replace
    assert r(nbadval)==1
    assert r(nimiss)==2
    assert r(nviol)==0
    use `"`results'"', clear
    assert n_bad==1 if qvar=="gate"
    assert n_imiss==1 if qvar=="gate"
    assert n_imiss==1 if qvar=="answer"
    assert strpos(jstat,`""bds":[1,0]"')>0 if qvar=="gate"
    assert strpos(jfilt,`""2":[2,0,0,0,1,1]"')>0 if qvar=="gate"
    use `"`final'"', clear
    assert gate==-9 if interview__id=="missing"
    assert answer==-9 if interview__id=="enabledblank"
    restore
end
capture noisily _suso_option_integration_smoke
local smoke_rc=_rc
capture program drop _suso_option_integration_smoke
if `smoke_rc' exit `smoke_rc'
di as result "PASS: 61-option Java/SFI → Stata Data-QC totals and subgroup integration."
