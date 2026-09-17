version 14.2
set more off

* OFFLINE test; run from this package root in a fresh licensed Stata session:
*     do tests/export_progress_smoke.do
* No Java, API account, or network is used. Only _suso_call is mocked.
* This executes the production formatter, public router and polling loop.
* The original _suso_call is restored on both success and assertion failure.
* The poll scenarios take approximately five seconds in total.
adopath ++ "."
quietly suso about

* Save the package's exact _suso_call definition before replacing anything.
* A fresh session ensures this is also the definition Stata has just loaded.
tempfile restore_call normal_log verbose_log
tempname source saved logname
file open `source' using "suso.ado", read text
file open `saved' using `"`restore_call'"', write text
local copying 0
local complete 0
file read `source' line
while r(eof)==0 {
    if strtrim(`"`macval(line)'"')=="program _suso_call, rclass" local copying 1
    if `copying' file write `saved' `"`macval(line)'"' _n
    if `copying' & strtrim(`"`macval(line)'"')=="end" {
        local complete 1
        continue, break
    }
    file read `source' line
}
file close `source'
file close `saved'
if !`complete' {
    di as err "Original _suso_call could not be saved; no mock was installed."
    exit 459
}

local testglobals "SUSO_BASE SUSO_BODY_REQ SUSO_PTEST_CASE SUSO_PTEST_INDEX SUSO_PTEST_FILES SUSO_PTEST_STATUS SUSO_PTEST_RAW SUSO_PTEST_HAS SUSO_PTEST_LAST"
foreach g of local testglobals {
    local old_`g' : copy global `g'
}
global SUSO_BASE ""
program drop _suso_call
program _suso_call, rclass
    version 14.2
    syntax , METHOD(string) PATH(string) [ SAVEFILE(string) * ]
    if "`method'"=="POST" & "`path'"=="/api/v2/export" {
        return local jobid "17779"
        return local exportstatus "Created"
        return local http "201"
        exit
    }
    if "`method'"=="GET" & "`path'"=="/api/v2/export/17779/file" {
        * Catch early download even if Running already says 100 or hasFile=1.
        assert "$SUSO_PTEST_LAST"=="Completed"
        global SUSO_PTEST_FILES = $SUSO_PTEST_FILES + 1
        return local saved `"`savefile'"'
        return local http "200"
        return scalar bytes = 123
        return scalar elapsed_seconds = 0.25
        return local sha256 "fixture-hash"
        return scalar attempts = 1
        exit
    }
    if "`method'"!="GET" | "`path'"!="/api/v2/export/17779" {
        di as err "Unexpected API path in offline test: `method' `path'"
        exit 459
    }
    global SUSO_PTEST_INDEX = $SUSO_PTEST_INDEX + 1
    local i = $SUSO_PTEST_INDEX
    if "$SUSO_PTEST_CASE"=="reset" {
        assert `i'<=5
        local statuses "Created Running Running Running Completed"
        local progress "0 100 0 8 100"
        local files "0 0 0 0 1"
        local status : word `i' of `statuses'
        local raw : word `i' of `progress'
        local has : word `i' of `files'
    }
    else if "$SUSO_PTEST_CASE"=="completed42" {
        assert `i'<=2
        local statuses "Running Completed"
        local progress "75 42"
        local status : word `i' of `statuses'
        local raw : word `i' of `progress'
        local has "1"
    }
    else {
        local status : copy global SUSO_PTEST_STATUS
        local raw : copy global SUSO_PTEST_RAW
        local has : copy global SUSO_PTEST_HAS
    }
    global SUSO_PTEST_LAST `"`status'"'
    return local exportstatus `"`status'"'
    return local progress `"`raw'"'
    return local hasexportfile `"`has'"'
    return local jobid "17779"
    return local http "200"
    return local marker "unrelated API metadata"
end

capture program drop _suso_progress_smoke
program _suso_progress_smoke
    version 14.2
    syntax , LOGNAME(name) NORMALLOG(string) VERBOSELOG(string)
    preserve
    clear
    set obs 1
    gen byte retained_marker = 1
    global SUSO_PTEST_FILES 0

    log using `"`normallog'"', text name(`logname')
    * User screenshot: 0 -> 100 -> 0 -> 8 while still preparing.
    global SUSO_PTEST_CASE "reset"
    global SUSO_PTEST_INDEX 0
    local expectedraw "0 100 0 8 100"
    local expectedstatus "Created Running Running Running Completed"
    forvalues i=1/5 {
        suso export status, id(17779)
        local raw `"`r(progress)'"'
        local status `"`r(exportstatus)'"'
        local has `"`r(hasexportfile)'"'
        local phase `"`r(preparation_state)'"'
        local http `"`r(http)'"'
        local jobid `"`r(jobid)'"'
        local marker `"`r(marker)'"'
        local expected : word `i' of `expectedraw'
        local wantedstatus : word `i' of `expectedstatus'
        assert `"`raw'"'=="`expected'"
        assert `"`status'"'=="`wantedstatus'"
        assert `"`http'"'=="200"
        assert `"`jobid'"'=="17779"
        assert `"`marker'"'=="unrelated API metadata"
        if `i'==1 assert `"`phase'"'=="Queued on server"
        if inrange(`i',2,4) assert `"`phase'"'=="Preparing on server"
        if `i'<5 assert `"`has'"'=="0"
        if `i'==5 {
            assert `"`phase'"'=="Ready for download"
            assert `"`has'"'=="1"
        }
    }

    * Prior log: hasFile=1 does not mean Running is finished; Completed42 is.
    global SUSO_PTEST_CASE "completed42"
    global SUSO_PTEST_INDEX 0
    suso export status, id(17779)
    assert `"`r(progress)'"'=="75"
    assert `"`r(preparation_state)'"'=="Preparing on server"
    suso export status, id(17779)
    assert `"`r(progress)'"'=="42"
    assert `"`r(preparation_state)'"'=="Ready for download"
    log close `logname'

    * Assert actual displayed default output does not print raw percentages.
    tempname fh
    file open `fh' using `"`normallog'"', read text
    local sawqueued 0
    local sawpreparing 0
    local sawready 0
    file read `fh' line
    while r(eof)==0 {
        if strpos(`"`macval(line)'"',"Export 17779:") {
            assert strpos(`"`macval(line)'"',"%")==0
            if strpos(`"`macval(line)'"',"Queued on server") local sawqueued 1
            if strpos(`"`macval(line)'"',"Preparing on server") local sawpreparing 1
            if strpos(`"`macval(line)'"',"Ready for download") local sawready 1
        }
        file read `fh' line
    }
    file close `fh'
    assert `sawqueued' & `sawpreparing' & `sawready'

    * Raw invalid values remain available to scripts, but aren't printed as %.
    global SUSO_PTEST_CASE "single"
    global SUSO_PTEST_STATUS "Running"
    global SUSO_PTEST_HAS "0"
    log using `"`verboselog'"', text name(`logname')
    foreach raw in "" "oops" "-1" "101" "." {
        global SUSO_PTEST_RAW `"`raw'"'
        suso export status, id(17779) verbose
        assert `"`r(progress)'"'==`"`raw'"'
        assert `"`r(http)'"'=="200"
        assert `"`r(preparation_state)'"'=="Preparing on server"
    }
    global SUSO_PTEST_RAW "100"
    suso export status, id(17779) verbose
    assert `"`r(progress)'"'=="100"
    assert `"`r(preparation_state)'"'=="Preparing on server"
    log close `logname'
    file open `fh' using `"`verboselog'"', read text
    local unavailable 0
    local raw100 0
    local caveats 0
    file read `fh' line
    while r(eof)==0 {
        if strpos(`"`macval(line)'"',"Raw server progress: unavailable") local ++unavailable
        if strpos(`"`macval(line)'"',"Raw server progress: 100%") local ++raw100
        if strpos(`"`macval(line)'"',"not overall completion or file-download progress") local ++caveats
        file read `fh' line
    }
    file close `fh'
    assert `unavailable'==5
    assert `raw100'==1
    assert `caveats'==6

    * File flags are normalized only for display; original API text survives.
    global SUSO_PTEST_STATUS "Completed"
    global SUSO_PTEST_HAS " YES "
    suso export status, id(17779)
    assert `"`r(hasexportfile)'"'==" YES "
    assert `"`r(preparation_state)'"'=="Ready for download"
    global SUSO_PTEST_HAS "false"
    suso export status, id(17779)
    assert `"`r(preparation_state)'"'=="Completed; no export file"
    global SUSO_PTEST_HAS ""
    suso export status, id(17779)
    assert `"`r(preparation_state)'"'=="Completed; file availability unknown"
    global SUSO_PTEST_STATUS "Failed"
    suso export status, id(17779)
    assert `"`r(preparation_state)'"'=="Export failed"
    global SUSO_PTEST_STATUS "Cancelled"
    suso export status, id(17779)
    assert `"`r(preparation_state)'"'=="Export cancelled"
    global SUSO_PTEST_STATUS "FutureState"
    suso export status, id(17779)
    assert `"`r(preparation_state)'"'=="Server status: FutureState"
    global SUSO_PTEST_STATUS ""
    suso export status, id(17779)
    assert `"`r(preparation_state)'"'=="Server status unavailable"

    local now = clock("`c(current_date)' `c(current_time)'", "DMYhms")
    _suso_export_status, id(17779) started(`=`now'-2000')
    assert r(prepare_seconds)>=2 & r(prepare_seconds)<.
    assert `"`r(http)'"'=="200"
    _suso_export_status, id(17779) started(`=`now'+60000')
    assert r(prepare_seconds)==0

    * Real polling flow, mocked start/status/file API: no early file request.
    tempfile destination
    foreach scenario in reset completed42 {
        global SUSO_PTEST_CASE "`scenario'"
        global SUSO_PTEST_INDEX 0
        global SUSO_PTEST_FILES 0
        _suso_export_get, type(STATA) saving(`"`destination'"') ///
            guid("0123456789abcdef0123456789abcdef") qver(1) pollsecs(1) jobtimeout(30)
        assert `"`r(status)'"'=="Completed"
        assert r(jobid)==17779
        assert r(prepare_seconds)>=0 & r(prepare_seconds)<.
        assert r(bytes)==123
        assert "$SUSO_PTEST_FILES"=="1"
        if "`scenario'"=="reset" assert "$SUSO_PTEST_INDEX"=="5"
        else assert "$SUSO_PTEST_INDEX"=="2"
    }
    global SUSO_PTEST_CASE "single"
    global SUSO_PTEST_STATUS "Completed"
    global SUSO_PTEST_HAS "false"
    global SUSO_PTEST_FILES 0
    _suso_export_get, type(STATA) saving(`"`destination'"') ///
        guid("0123456789abcdef0123456789abcdef") qver(1) pollsecs(1) jobtimeout(30)
    assert `"`r(status)'"'=="NoFile"
    assert `"`r(saved)'"'==""
    assert "$SUSO_PTEST_FILES"=="0"
    global SUSO_PTEST_STATUS "Failed"
    capture _suso_export_get, type(STATA) saving(`"`destination'"') ///
        guid("0123456789abcdef0123456789abcdef") qver(1) pollsecs(1) jobtimeout(30)
    assert _rc==459
    assert "$SUSO_PTEST_FILES"=="0"
    assert _N==1
    assert retained_marker==1
    restore
end

capture noisily _suso_progress_smoke, logname(`logname') ///
    normallog(`"`normal_log'"') verboselog(`"`verbose_log'"')
local test_rc = _rc
capture log close `logname'
capture program drop _suso_call
capture noisily run `"`restore_call'"'
local restore_rc = _rc
foreach g of local testglobals {
    global `g' `"`macval(old_`g')'"'
}
capture program drop _suso_progress_smoke
if `restore_rc' {
    di as err "Could not restore _suso_call; restart Stata before using suso."
    exit `restore_rc'
}
if `test_rc' exit `test_rc'
display as result "PASS: offline progress display, API return preservation, and completion-based polling"
