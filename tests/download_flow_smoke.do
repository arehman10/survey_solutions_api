version 14.2
set more off

* Run from the package root in licensed Stata:
*     do tests/download_flow_smoke.do
* Offline only. No Java or server is needed. The server setting is temporarily
* blanked so a regression cannot accidentally reach an existing connection.
* The caller's dataset and server setting are restored on success or error.
adopath ++ "."
quietly suso about
local oldbase : copy global SUSO_BASE
global SUSO_BASE ""
capture program drop _suso_download_flow_smoke
program _suso_download_flow_smoke
    version 14.2
    preserve
    clear
    set obs 1
    gen long retained_marker = 98765
    tempfile taken fresh badbase dirbase
    tempname fh
    file open `fh' using `"`taken'"', write text
    file write `fh' "existing archive sentinel" _n
    file close `fh'

    * Conflicts are reported before Java or export creation, including Paradata.
    capture _suso_export_get, type(STATA) saving(`"`taken'"')
    assert _rc==602
    capture _suso_para_get, saving(`"`taken'"')
    assert _rc==602
    file open `fh' using `"`taken'"', read text
    file read `fh' sentinel
    file close `fh'
    assert `"`sentinel'"'=="existing archive sentinel"

    * Backup runs stay inside dir() and never reuse an earlier snapshot.
    local requested `"`dirbase'_backup"'
    _suso_backup_dir, dir(`"`requested'"')
    local firstdir `"`r(dir)'"'
    assert `"`r(root)'"'==`"`requested'"'
    assert strpos(`"`firstdir'"',`"`requested'/suso_backup_"')==1
    file open `fh' using `"`firstdir'/keep.txt"', write text
    file write `fh' "prior run" _n
    file close `fh'
    _suso_backup_dir, dir(`"`requested'"')
    local nextdir `"`r(dir)'"'
    assert `"`nextdir'"'!=`"`firstdir'"'
    assert `"`r(root)'"'==`"`requested'"'
    assert strpos(`"`nextdir'"',`"`requested'/suso_backup_"')==1
    confirm file `"`firstdir'/keep.txt"'
    * A file occupying dir() is preserved; never redirect the run elsewhere.
    capture _suso_backup_dir, dir(`"`taken'"')
    assert _rc==602
    confirm file `"`taken'"'
    rmdir `"`nextdir'"'
    erase `"`firstdir'/keep.txt"'
    rmdir `"`firstdir'"'
    rmdir `"`requested'"'
    capture _suso_backup_dir, dir(".")
    assert _rc==198

    * Invalid waiting intervals fail before any API request.
    foreach invalid in 0 -1 . {
        capture _suso_export_get, type(STATA) saving(`"`fresh'"') pollsecs(`invalid')
        assert _rc==198
        capture _suso_export_get, type(STATA) saving(`"`fresh'"') jobtimeout(`invalid')
        assert _rc==198
    }

    * An invalid tab import must not replace the user's in-memory dataset.
    local bad `"`badbase'.tab"'
    file open `fh' using `"`bad'"', write text
    file write `fh' "wrong_column" _n "value" _n
    file close `fh'
    capture noisily _suso_para_load, file(`"`bad'"')
    local badrc = _rc
    capture erase `"`bad'"'
    assert `badrc'==459
    assert _N==1
    assert retained_marker==98765

    * A valid import should still become the active dataset on success.
    _suso_para_load, file("examples/synthetic/paradata.tab")
    assert r(nevents)>0
    assert r(nints)>0
    confirm string variable interview__id
    confirm numeric variable para_seq
    restore
end

capture noisily _suso_download_flow_smoke
local rc = _rc
global SUSO_BASE `"`macval(oldbase)'"'
capture program drop _suso_download_flow_smoke
if `rc' exit `rc'
display as result "PASS: offline download preflight and failure-preserving import checks"
