version 14.2
set more off

* Run from this package root with the matching Java backend:
*     do tests/folder_flow_smoke.do
* This is an OFFLINE local extraction test. It does not use an API account.
* The ZIP fixture contains small text files, including a nested preview HTML.
* Real Stata/SFI execution is required; source checks are not a substitute.
adopath ++ "."
quietly suso about
local oldbase : copy global SUSO_BASE
global SUSO_BASE ""
capture program drop _suso_folder_flow_smoke
program _suso_folder_flow_smoke
    version 14.2
    preserve
    clear
    set obs 1
    gen long retained_marker = 98765
    tempfile dirbase missingarchive
    local target `"`dirbase'_dated_folder"'
    mkdir `"`target'"'
    tempname fh
    file open `fh' using `"`target'/keep.txt"', write text
    file write `fh' "existing unrelated file" _n
    file close `fh'

    * Missing archives fail before Java, without changing the active data.
    capture suso export extract, file(`"`missingarchive'.zip"') unzipto(`"`target'"')
    assert _rc==601
    assert _N==1
    assert retained_marker==98765

    * An existing folder, including unrelated files, is the exact destination.
    suso export extract, file("tests/fixtures/local_export_recovery.zip") unzipto(`"`target'"')
    local extracted = subinstr(`"`r(unzipdir)'"', "\", "/", .)
    local expected = subinstr(`"`target'"', "\", "/", .)
    local manifest `"`r(manifest)'"'
    assert `"`extracted'"'==`"`expected'"'
    assert r(unzipped)==2
    assert r(nfiles)==2
    assert r(unzip_bytes)>0
    assert r(unzip_seconds)>=0
    assert _N==1
    assert retained_marker==98765
    confirm file `"`target'/data.csv"'
    confirm file `"`target'/Questionnaire/Preview/English test.html"'
    confirm file `"`manifest'"'
    confirm file "tests/fixtures/local_export_recovery.zip"
    file open `fh' using `"`target'/keep.txt"', read text
    file read `fh' sentinel
    file close `fh'
    assert `"`sentinel'"'=="existing unrelated file"

    * Re-extraction stays at the same root; Java tests verify retained versions.
    suso export extract, file("tests/fixtures/local_export_recovery.zip") unzipto(`"`target'"')
    local extracted = subinstr(`"`r(unzipdir)'"', "\", "/", .)
    assert `"`extracted'"'==`"`expected'"'
    confirm file `"`target'/data.csv"'
    confirm file `"`target'/keep.txt"'
    assert _N==1
    assert retained_marker==98765
    di as txt "Offline extraction test artifacts retained for inspection at: " as res `"`target'"'
    restore
end

capture noisily _suso_folder_flow_smoke
local rc = _rc
global SUSO_BASE `"`macval(oldbase)'"'
capture program drop _suso_folder_flow_smoke
if `rc' exit `rc'
display as result "PASS: exact folder local extraction, offline recovery and dataset preservation"
