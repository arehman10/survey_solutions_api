*! suso v1.7.0  02jul2026  (suso paradata: timing analysis, behaviour flags and skip-flip cascade detection; suso export get: one-shot start->poll->download->unzip)
*! suso v1.6.0  18jun2026  (suso backup: full-workspace archive orchestrator (from data_backup notebook) + internal export start->poll->download helper)
*! Author: Attique Ur Rehman, Economist, The World Bank (DEC, Enterprise Surveys)
*!         attique@worldbank.org  ·  https://sites.google.com/view/attique-ur-rehman
*! The World Bank — Development Economics (DEC) · Enterprise Surveys
*! Requires: a Java 11+ runtime (check with: suso doctor) and suso.jar on the adopath.
*-------------------------------------------------------------------------------
* suso — a thin, safe Stata front-end over the Survey Solutions REST API.
*
* The heavy lifting (HTTP, JSON, loading results into the dataset) is done by
* suso.jar via -javacall-. This .ado parses syntax, builds requests, enforces
* safety checks around destructive operations, writes an audit log, paginates,
* and returns results in r().
*
* See:  help suso
*-------------------------------------------------------------------------------

* ----- Mata helpers (URL-encoding + JSON string escaping), UTF-8 byte-correct ----
capture mata: mata drop suso_urlencode()
capture mata: mata drop suso_jsonesc()
version 14.2
mata:
mata set matastrict off

string scalar suso_urlencode(string scalar s)
{
    real scalar   i, n, c
    string scalar out, ch, hex
    hex = "0123456789ABCDEF"
    out = ""
    n   = strlen(s)                      // byte length
    for (i=1; i<=n; i++) {
        ch = substr(s, i, 1)             // one byte
        if (regexm(ch, "[A-Za-z0-9._~-]")) out = out + ch
        else {
            c   = ascii(ch)
            out = out + "%" + substr(hex, floor(c/16)+1, 1) + substr(hex, mod(c, 16)+1, 1)
        }
    }
    return(out)
}

string scalar suso_jsonesc(string scalar s)
{
    s = subinstr(s, "\", "\\")
    s = subinstr(s, char(34), "\" + char(34))
    s = subinstr(s, char(13), "\r")
    s = subinstr(s, char(10), "\n")
    s = subinstr(s, char(9),  "\t")
    return(s)
}
end

*===============================================================================
* Router
*===============================================================================
program suso, rclass
    version 14.2
    gettoken noun 0 : 0, parse(" ,")
    local noun = strlower(`"`noun'"')

    if "`noun'"=="" {
        di as txt _n "{bf:suso} — talk to Survey Solutions from Stata."
        di as txt    "  1.  {bf:suso config , server(<url>) workspace(<ws>) user(<apiuser>) password(<pw>)}"
        di as txt    "  2.  {bf:suso ping}                 {txt}(check it works)"
        di as txt    "  3.  {bf:suso examples}             {txt}(copy/paste recipes)"
        di as txt _n "Type {stata suso examples:suso examples} for ready-to-run commands, " ///
                     "{stata suso endpoints:suso endpoints} for the full list, or {help suso} for help." _n
        exit
    }
    if inlist("`noun'","help","?") {
        capture help suso
        if _rc di as txt "suso — install suso.sthlp, then:  {bf:help suso}   (or {bf:suso examples})"
        exit
    }
    if inlist("`noun'","examples","example","recipes","cheatsheet","cheat") {
        _suso_examples
        exit
    }
    if inlist("`noun'","endpoints","endpoint","commands","menu","list") {
        _suso_endpoints
        exit
    }

    * single-word commands
    if "`noun'"=="login" {
        _suso_prompt
        exit
    }
    if "`noun'"=="backup" {
        _suso_backup `macval(0)'
        return add
        exit
    }
    if inlist("`noun'","config","doctor","ping","raw","version","about") {
        if "`noun'"=="version" | "`noun'"=="about" {
            _suso_about
            exit
        }
        _suso_`noun' `macval(0)'
        return add
        exit
    }

    * normalise plural nouns
    if "`noun'"=="assignments"   local noun assignment
    if "`noun'"=="interviews"    local noun interview
    if "`noun'"=="questionnaires" local noun questionnaire
    if "`noun'"=="exports"       local noun export
    if "`noun'"=="users"         local noun user
    if "`noun'"=="supervisors"   local noun supervisor
    if "`noun'"=="interviewers"  local noun interviewer
    if "`noun'"=="workspaces"    local noun workspace
    if "`noun'"=="setting"       local noun settings
    if "`noun'"=="statistic" | "`noun'"=="stats" local noun statistics
    if "`noun'"=="map"           local noun maps
    if "`noun'"=="para"          local noun paradata

    if !inlist("`noun'","assignment","interview","questionnaire","export","user","maps") ///
     & !inlist("`noun'","supervisor","interviewer","workspace","settings","statistics","paradata") {
        di as err "suso: unknown subcommand '`noun''.  See {help suso}."
        exit 198
    }

    _suso_`noun' `macval(0)'
    return add
end

*===============================================================================
* Configuration
*===============================================================================
program _suso_config, rclass
    version 14.2
    syntax [, SERVER(string) Workspace(string) User(string) Password(string)   ///
        TOKEN(string) AUTH(string) JAR(string) PROXYHost(string)               ///
        PROXYPort(integer 0) PROXYUser(string) PROXYPass(string)               ///
        INSECURE NOINSECURE CONNTimeout(integer 0) READTimeout(integer 0)      ///
        MAXrows(integer 0) AUDITfile(string) GUID(string) QVER(integer 0)      ///
        EXPORTPw(string) SHOW CLEAR ]

    if "`clear'"!="" {
        capture macro drop SUSO_BASE SUSO_WS SUSO_USER SUSO_PWD SUSO_TOKEN          ///
            SUSO_AUTHTYPE SUSO_PROXYHOST SUSO_PROXYPORT SUSO_PROXYUSER SUSO_PROXYPWD ///
            SUSO_INSECURE SUSO_CONNTO SUSO_READTO SUSO_MAXROWS SUSO_AUDIT            ///
            SUSO_GUID SUSO_QVER SUSO_EXPORTPWD
        di as txt "suso: configuration cleared for this session."
        exit
    }

    if "`server'"!="" {
        local server = trim("`server'")
        if substr("`server'", -1, 1)=="/" local server = substr("`server'", 1, length("`server'")-1)
        global SUSO_BASE "`server'"
    }
    if "`workspace'"!="" global SUSO_WS       "`workspace'"
    if "`user'"!=""      global SUSO_USER     "`user'"
    if "`password'"!=""  global SUSO_PWD      "`password'"
    if "`token'"!=""     global SUSO_TOKEN    "`token'"
    if "`auth'"!=""      global SUSO_AUTHTYPE = strlower("`auth'")
    if "`jar'"!=""       global SUSO_JAR      "`jar'"
    if "`proxyhost'"!="" global SUSO_PROXYHOST "`proxyhost'"
    if `proxyport'>0     global SUSO_PROXYPORT "`proxyport'"
    if "`proxyuser'"!="" global SUSO_PROXYUSER "`proxyuser'"
    if "`proxypass'"!="" global SUSO_PROXYPWD  "`proxypass'"
    if "`insecure'"!=""  global SUSO_INSECURE  "1"
    if "`noinsecure'"!="" global SUSO_INSECURE "0"
    if `conntimeout'>0   global SUSO_CONNTO  = `conntimeout'*1000
    if `readtimeout'>0   global SUSO_READTO  = `readtimeout'*1000
    if `maxrows'>0       global SUSO_MAXROWS "`maxrows'"
    if "`auditfile'"!="" global SUSO_AUDIT   "`auditfile'"
    if "`guid'"!=""      global SUSO_GUID    "`guid'"
    if `qver'>0          global SUSO_QVER    "`qver'"
    if `"`exportpw'"'!="" global SUSO_EXPORTPWD `"`exportpw'"'   // export-archive password

    _suso_init

    if "`insecure'"!="" {
        di as err "suso: WARNING — TLS certificate/hostname verification is DISABLED for this session."
        di as err "      Use this only as a last resort behind the corporate proxy. Prefer importing"
        di as err "      the WBG root CA into your Stata JVM trust store (see the README)."
    }

    if "`show'"!="" | trim(`"`server'`workspace'`user'`password'`token'`auth'`jar'`proxyhost'`exportpw'"')=="" {
        _suso_showconfig
    }
end

program _suso_showconfig
    di as txt _n "{hline 62}"
    di as txt "suso configuration (this Stata session)"
    di as txt "{hline 62}"
    di as txt "  server      : " as res cond("$SUSO_BASE"=="","(not set)","$SUSO_BASE")
    di as txt "  workspace   : " as res cond("$SUSO_WS"=="","(not set)","$SUSO_WS")
    if "$SUSO_GUID"!="" {
        di as txt "  questionnaire: " as res "$SUSO_GUID" ///
            cond("$SUSO_QVER"!=""," (v$SUSO_QVER)"," (any version)")
    }
    di as txt "  auth        : " as res cond("$SUSO_AUTHTYPE"=="","basic","$SUSO_AUTHTYPE")
    di as txt "  user        : " as res cond("$SUSO_USER"=="","(not set)","$SUSO_USER")
    di as txt "  password    : " as res cond("$SUSO_PWD"=="","(not set)","********")
    if "$SUSO_TOKEN"!="" di as txt "  bearer token: " as res "********"
    if `"$SUSO_EXPORTPWD"'!="" di as txt "  export pw   : " as res "********"
    di as txt "  jar         : " as res cond("$SUSO_JAR"=="","(auto-locate on adopath)","$SUSO_JAR")
    if "$SUSO_PROXYHOST"!="" di as txt "  proxy       : " as res "$SUSO_PROXYHOST:$SUSO_PROXYPORT"
    di as txt "  TLS verify  : " as res cond("$SUSO_INSECURE"=="1","DISABLED (insecure)","on")
    di as txt "  timeouts ms : " as res "connect=$SUSO_CONNTO  read=$SUSO_READTO"
    di as txt "  max rows    : " as res "$SUSO_MAXROWS"
    local af "$SUSO_AUDIT"
    if "`af'"=="" local af "`c(sysdir_personal)'suso_audit.log"
    di as txt "  audit log   : " as res `"`af'"'
    di as txt "{hline 62}"
end

program _suso_about
    di as txt _n "{hline 66}"
    di as txt "  suso  v1.7.0  —  Survey Solutions REST API client for Stata"
    di as txt "{hline 66}"
    di as txt "  Author       : Attique Ur Rehman, Economist, The World Bank"
    di as txt "                 Development Economics (DEC) · Enterprise Surveys"
    di as txt "  Email        : attique@worldbank.org"
    di as txt "  Web          : https://sites.google.com/view/attique-ur-rehman"
    di as txt "{hline 66}"
    di as txt "  Java backend : suso.jar (requires a Java 11+ runtime)"
    di as txt "  Help         : {help suso}        Diagnostics: {stata suso doctor:suso doctor}"
    di as txt "{hline 66}"
end

*===============================================================================
* Diagnostics
*===============================================================================
program _suso_doctor
    version 14.2
    di as txt _n "{hline 62}"
    di as txt "suso doctor — environment check"
    di as txt "{hline 62}"
    di as txt "Stata"
    di as txt "  version       : " as res "`c(flavor)' `c(stata_version)'"
    di as txt "  sysdir PLUS   : " as res "`c(sysdir_plus)'"
    di as txt "  sysdir PERSON : " as res "`c(sysdir_personal)'"

    di as txt "Java backend"
    capture _suso_jar
    if _rc {
        di as err "  suso.jar      : NOT FOUND — put it on the adopath or set -suso config , jar(...)-"
    }
    else {
        di as txt "  suso.jar      : " as res "$SUSO_JAR"
        capture noisily javacall org.worldbank.suso.Stata jvm , classpath("$SUSO_JAR")
        if _rc {
            di as err "  javacall      : FAILED (rc=`=_rc') — is Java available to Stata? See {help java}."
        }
        else if "$SUSO_JAVAOK"=="1" {
            di as txt "  Java 11+      : " as res "yes  ($SUSO_JAVAVER)"
        }
        else {
            di as err "  Java 11+      : NO ($SUSO_JAVAVER) — PATCH operations require Java 11 or newer."
        }
    }
    _suso_showconfig
    capture macro drop SUSO_JAVAVER SUSO_JAVAOK
end

program _suso_ping, rclass
    version 14.2
    syntax [, VERBOSE]
    _suso_call , method(GET) path(/api/v2/export) query(limit=1) `verbose'
    di as txt "suso: connection OK (HTTP " as res "`r(http)'" as txt ") to $SUSO_BASE/$SUSO_WS"
    return add
end

*===============================================================================
* Core helpers
*===============================================================================
program _suso_init
    if "$SUSO_AUTHTYPE"=="" global SUSO_AUTHTYPE "basic"
    if "$SUSO_CONNTO"==""   global SUSO_CONNTO   "30000"
    if "$SUSO_READTO"==""   global SUSO_READTO   "300000"
    if "$SUSO_MAXROWS"==""  global SUSO_MAXROWS  "100000"
    if "$SUSO_PWD"=="" & "$SUSO_TOKEN"=="" {
        local e : environment SUSO_PASSWORD
        if "`e'"!="" global SUSO_PWD "`e'"
    }
    * Ask for the API user/password if they were never supplied (basic auth only).
    if "$SUSO_AUTHTYPE"=="basic" & "$SUSO_TOKEN"=="" & ("$SUSO_USER"=="" | "$SUSO_PWD"=="") {
        _suso_prompt , user("$SUSO_USER")
    }
end

program _suso_prompt, rclass
    syntax [ , USER(string) ]
    _suso_jar
    mata: st_global("SUSO_PROMPT_USER", st_local("user"))
    capture noisily javacall org.worldbank.suso.Stata prompt , classpath("$SUSO_JAR")
    local jrc = _rc
    capture macro drop SUSO_PROMPT_USER
    if `jrc' {
        di as err "suso: credential prompt could not run (rc=`jrc')."
        di as err "      Set them directly:  suso config , user(<name>) password(<pw>)"
        exit `jrc'
    }
    if "$SUSO_RC"!="0" {
        local m "$SUSO_MSG"
        if "`m'"=="" local m "credential prompt cancelled"
        capture macro drop SUSO_RC SUSO_MSG
        di as err "suso: `m'"
        exit 198
    }
    capture macro drop SUSO_RC SUSO_MSG
    di as txt "suso: signed in as " as res "$SUSO_USER" as txt "."
end

program _suso_unzip, rclass
    syntax , FILE(string) [ DIR(string) PWD(string) ]
    _suso_jar
    * default destination: a folder named after the archive, beside it
    if `"`dir'"' == "" {
        local k = strrpos(`"`file'"', ".")
        if `k' > 0 local dir = substr(`"`file'"', 1, `k'-1)
        else       local dir `"`file'"'
    }
    mata: st_global("SUSO_ZIP_FILE", st_local("file"))
    mata: st_global("SUSO_ZIP_DIR",  st_local("dir"))
    mata: st_global("SUSO_ZIP_PWD",  st_local("pwd"))
    capture noisily javacall org.worldbank.suso.Stata unzip , classpath("$SUSO_JAR")
    local jrc = _rc
    capture macro drop SUSO_ZIP_FILE SUSO_ZIP_DIR SUSO_ZIP_PWD
    if `jrc' {
        di as err "suso: unzip bridge failed (rc=`jrc')."
        exit `jrc'
    }
    local rc = real("$SUSO_RC")
    if `rc'!=0 & !missing(`rc') {
        local m "$SUSO_MSG"
        if "`m'"=="" local m "unzip failed"
        capture macro drop SUSO_RC SUSO_MSG SUSO_UNZIP_N SUSO_UNZIP_DIR
        di as err "suso: `m'"
        exit `rc'
    }
    if "$SUSO_MSG"!="" di as txt "suso: $SUSO_MSG"
    di as txt "suso: extracted " as res "$SUSO_UNZIP_N" as txt " file(s) to " as res `"$SUSO_UNZIP_DIR"'
    return local unzipdir `"$SUSO_UNZIP_DIR"'
    return scalar nfiles = real("$SUSO_UNZIP_N")
    capture macro drop SUSO_RC SUSO_MSG SUSO_UNZIP_N SUSO_UNZIP_DIR
end

program _suso_gql, rclass
    syntax [ , TODATA NODEpath(string) VERBOSE ]
    _suso_init
    _suso_jar
    if "$SUSO_BASE"=="" {
        di as err "suso: no server configured.  suso config , server(<url>) workspace(<name>)"
        exit 198
    }
    * Body / operations / file / name are passed by the caller as SUSO_GQL_* globals
    * (set via mata to avoid macro-expansion of JSON braces and quotes).
    mata: st_global("SUSO_GQL_NODEPATH",   st_local("nodepath"))
    global SUSO_GQL_TODATA = cond("`todata'"!="","1","0")
    global SUSO_VERBOSE    = cond("`verbose'"!="","1","0")
    if "`todata'"!="" clear
    capture noisily javacall org.worldbank.suso.Stata gql , classpath("$SUSO_JAR")
    local jrc = _rc
    local rc    "$SUSO_RC"
    local http  "$SUSO_HTTP"
    local msg   `"$SUSO_MSG"'
    local nobs  "$SUSO_NOBS"
    local nvars "$SUSO_NVARS"
    local total "$SUSO_TOTALCOUNT"
    local fkeys "$SUSO_FKEYS"
    foreach k of local fkeys {
        local F_`k' `"${SUSO_F_`k'}"'
    }
    capture macro drop SUSO_GQL_BODY SUSO_GQL_OPERATIONS SUSO_GQL_MAP SUSO_UP_FILE ///
        SUSO_UP_NAME SUSO_GQL_NODEPATH SUSO_GQL_TODATA SUSO_VERBOSE
    if `jrc' {
        di as err "suso: the Java call failed (Stata rc=`jrc'). See:  suso doctor"
        exit `jrc'
    }
    if "`rc'"=="" {
        di as err "suso: no response from the Java backend."
        exit 459
    }
    if "`rc'"!="0" {
        di as err `"suso: `macval(msg)'"'
        exit 459
    }
    if "`todata'"!="" {
        if "`nobs'"!=""  return scalar nobs  = real("`nobs'")
        if "`nvars'"!="" return scalar nvars = real("`nvars'")
        if "`total'"!="" return scalar totalcount = real("`total'")
    }
    foreach k of local fkeys {
        return local `k' `"`F_`k''"'
    }
    return local http "`http'"
    capture macro drop SUSO_RC SUSO_HTTP SUSO_MSG SUSO_BODY SUSO_NOBS SUSO_NVARS SUSO_TOTALCOUNT SUSO_FKEYS
    local gl : all globals
    foreach g of local gl {
        if substr("`g'",1,7)=="SUSO_F_" capture macro drop `g'
    }
end

program _suso_maps, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="list" {
        syntax [ , WORKSPACE(string) PAGESize(integer 100) VERBOSE ]
        if "`workspace'"=="" local workspace "$SUSO_WS"
        if `"`workspace'"'=="" {
            di as err "suso maps: no workspace set. Run:  suso config , workspace(<name>)"
            di as err "           or add  workspace(<name>)  to this command."
            exit 198
        }
        _suso_maps_fetch , workspace(`"`workspace'"') pagesize(`pagesize') `verbose'
        local got   = r(nobs)
        local total = r(totalcount)
        local extra ""
        if "`total'"!="" & "`total'"!="." local extra " (of `total' on server)"
        di as txt "suso: fetched " as res "`got'" as txt " map(s)`extra'."
        return scalar nobs = `got'
        if "`total'"!="" & "`total'"!="." return scalar totalcount = `total'
        exit
    }
    if "`verb'"=="upload" {
        syntax , FILE(string) [ NAME(string) WORKSPACE(string) VERBOSE ]
        if "`workspace'"=="" local workspace "$SUSO_WS"
        if `"`workspace'"'=="" {
            di as err "suso maps: no workspace set. Run:  suso config , workspace(<name>)"
            di as err "           or add  workspace(<name>)  to this command."
            exit 198
        }
        _suso_jsonesc `"`workspace'"'
        local jws `"`r(js)'"'
        local fn `"`name'"'
        if `"`fn'"' == "" {
            local f2 = subinstr(`"`file'"', "\", "/", .)
            local k  = strrpos(`"`f2'"', "/")
            if `k' > 0 local fn = substr(`"`f2'"', `k'+1, .)
            else       local fn `"`f2'"'
        }
        * Survey Solutions uploadMap takes a .zip archive (shapefile family / GeoTIFF / TPK).
        local ops `"{"query":"mutation(__DOLLAR__file:Upload!,__DOLLAR__workspace:String){uploadMap(file:__DOLLAR__file,workspace:__DOLLAR__workspace){fileName size shapeType wkid importDateUtc}}","variables":{"file":null,"workspace":"`jws'"}}"'
        mata: st_global("SUSO_GQL_BODY",       "")
        mata: st_global("SUSO_GQL_OPERATIONS", st_local("ops"))
        mata: st_global("SUSO_UP_FILE",        st_local("file"))
        mata: st_global("SUSO_UP_NAME",        st_local("fn"))
        _suso_gql , `verbose'
        local h = r(http)
        di as txt "suso: uploaded " as res `"`fn'"' as txt " to workspace " as res "`workspace'" as txt " (HTTP `h')."
        return scalar http = `h'
        exit
    }
    if "`verb'"=="delete" {
        syntax , NAME(string) [ WORKSPACE(string) CONFIRM VERBOSE ]
        if "`workspace'"=="" local workspace "$SUSO_WS"
        if `"`workspace'"'=="" {
            di as err "suso maps: no workspace set. Run:  suso config , workspace(<name>)"
            di as err "           or add  workspace(<name>)  to this command."
            exit 198
        }
        _suso_block , action("DELETE map `name' from workspace `workspace' (irreversible)") `confirm'
        _suso_maps_del1 , workspace(`"`workspace'"') name(`"`name'"') `verbose'
        local h = r(http)
        _suso_audit , action("map delete") target("`name'") http("`h'")
        di as txt "suso: deleted map " as res "`name'" as txt " (HTTP `h')."
        return scalar http = `h'
        exit
    }
    if "`verb'"=="deleteall" {
        syntax [ , WORKSPACE(string) Iknowthis(string) SLEEP(integer 200) PAGESize(integer 100) DRYrun VERBOSE ]
        if "`workspace'"=="" local workspace "$SUSO_WS"
        if `"`workspace'"'=="" {
            di as err "suso maps: no workspace set. Run:  suso config , workspace(<name>)"
            di as err "           or add  workspace(<name>)  to this command."
            exit 198
        }
        preserve
        _suso_maps_fetch , workspace(`"`workspace'"') pagesize(`pagesize') `verbose'
        local N = r(nobs)
        if `N'==0 {
            di as txt "suso maps: workspace " as res "`workspace'" as txt " has no maps — nothing to delete."
            restore
            exit
        }
        * Two-phase safety (mirrors the wipe notebook): a dry run unless the user
        * confirms by typing the workspace name in iknowthis().
        local doit = 0
        if "`dryrun'"=="" & `"`iknowthis'"'==`"`workspace'"' local doit = 1
        if `doit'==0 {
            di as txt _n "{hline 64}"
            di as txt "  suso maps deleteall   —   DRY RUN (nothing deleted)"
            di as txt "{hline 64}"
            di as txt "  Workspace : " as res "`workspace'"
            di as txt "  Maps      : " as res "`N'" as txt " would be permanently deleted."
            local show = min(`N',8)
            di as txt "  Sample    :"
            forvalues i = 1/`show' {
                di as txt "      " as res `"`=fileName[`i']'"'
            }
            if `N' > `show' di as txt "      ... and " as res "`=`N'-`show''" as txt " more."
            di as err _n "  This is IRREVERSIBLE. To delete ALL `N' map(s), type the workspace name:"
            di as err "      suso maps deleteall , iknowthis(`workspace')"
            restore
            exit
        }
        di as txt "suso maps: deleting " as res "`N'" as txt " map(s) from workspace " as res "`workspace'" as txt " ..."
        local ok = 0
        local fail = 0
        forvalues i = 1/`N' {
            local fn = fileName[`i']
            capture _suso_maps_del1 , workspace(`"`workspace'"') name(`"`fn'"')
            if _rc local ++fail
            else   local ++ok
            if mod(`i',100)==0 di as txt "  ... `i'/`N'   (" as res "`ok'" as txt " ok, " as res "`fail'" as txt " failed)"
            if `sleep' > 0 sleep `sleep'
        }
        _suso_audit , action("maps deleteall") target("`workspace' (`ok'/`N' deleted)") http("")
        local fx ""
        if `fail' > 0 local fx " — `fail' failed (re-run  suso maps list  to see any stragglers)"
        di as txt _n "suso maps: deleted " as res "`ok'" as txt " of `N' map(s) from " as res "`workspace'" as txt "`fx'."
        restore
        return scalar deleted = `ok'
        return scalar failed  = `fail'
        return scalar total   = `N'
        exit
    }
    if inlist("`verb'","assign","unassign") {
        syntax , NAME(string) USER(string) [ WORKSPACE(string) VERBOSE ]
        if "`workspace'"=="" local workspace "$SUSO_WS"
        if `"`workspace'"'=="" {
            di as err "suso maps: no workspace set. Run:  suso config , workspace(<name>)"
            di as err "           or add  workspace(<name>)  to this command."
            exit 198
        }
        if "`verb'"=="assign" {
            local mut  "addUserToMap"
            local prep "to"
        }
        else {
            local mut  "deleteUserFromMap"
            local prep "from"
        }
        _suso_jsonesc `"`name'"'
        local jn  `"`r(js)'"'
        _suso_jsonesc `"`user'"'
        local ju  `"`r(js)'"'
        _suso_jsonesc `"`workspace'"'
        local jws `"`r(js)'"'
        local body `"{"query":"mutation(__DOLLAR__fileName:String!,__DOLLAR__userName:String!,__DOLLAR__workspace:String){`mut'(fileName:__DOLLAR__fileName,userName:__DOLLAR__userName,workspace:__DOLLAR__workspace){fileName}}","variables":{"fileName":"`jn'","userName":"`ju'","workspace":"`jws'"}}"'
        mata: st_global("SUSO_GQL_BODY",       st_local("body"))
        mata: st_global("SUSO_GQL_OPERATIONS", "")
        mata: st_global("SUSO_UP_FILE",        "")
        _suso_gql , `verbose'
        local h = r(http)
        di as txt "suso: map " as res "`name'" as txt " `verb'ed `prep' user " as res "`user'" as txt " (HTTP `h')."
        return scalar http = `h'
        exit
    }
    di as err "suso maps: unknown action '`verb''.  See {help suso}."
    exit 198
end

program _suso_maps_fetch, rclass
    * Load ALL maps in a workspace into memory (paginating with skip), since the
    * server caps a page at ~100. Returns r(nobs) and r(totalcount).
    syntax , WORKSPACE(string) [ PAGESize(integer 100) VERBOSE ]
    _suso_jsonesc `"`workspace'"'
    local jws `"`r(js)'"'
    tempfile acc
    local skip    = 0
    local total   = .
    local haveacc = 0
    local page    = 0
    while 1 {
        local page = `page' + 1
        local body `"{"query":"query(__DOLLAR__workspace:String,__DOLLAR__take:Int,__DOLLAR__skip:Int){maps(workspace:__DOLLAR__workspace,take:__DOLLAR__take,skip:__DOLLAR__skip){totalCount nodes{fileName size shapeType shapesCount wkid importDateUtc uploadedBy}}}","variables":{"workspace":"`jws'","take":`pagesize',"skip":`skip'}}"'
        mata: st_global("SUSO_GQL_BODY",       st_local("body"))
        mata: st_global("SUSO_GQL_OPERATIONS", "")
        mata: st_global("SUSO_UP_FILE",        "")
        _suso_gql , todata nodepath(maps.nodes) `verbose'
        local n = r(nobs)
        if "`r(totalcount)'"!="" & "`r(totalcount)'"!="." local total = r(totalcount)
        if `n'==0 continue, break
        if `haveacc' append using `acc'
        quietly save `acc', replace
        local haveacc = 1
        local skip = `skip' + `n'
        if `total'!=. & `skip' >= `total' continue, break
        if `page' >= 2000 continue, break
    }
    if `haveacc' use `acc', clear
    else clear
    return scalar nobs = _N
    if `total'!=. return scalar totalcount = `total'
end

program _suso_maps_del1, rclass
    * Delete one map (deleteMap GraphQL mutation). No interactive guard — callers
    * (suso maps delete / deleteall) handle confirmation. Returns r(http).
    syntax , WORKSPACE(string) NAME(string) [ VERBOSE ]
    _suso_jsonesc `"`name'"'
    local jn  `"`r(js)'"'
    _suso_jsonesc `"`workspace'"'
    local jws `"`r(js)'"'
    local body `"{"query":"mutation(__DOLLAR__workspace:String,__DOLLAR__fileName:String!){deleteMap(workspace:__DOLLAR__workspace,fileName:__DOLLAR__fileName){fileName}}","variables":{"workspace":"`jws'","fileName":"`jn'"}}"'
    mata: st_global("SUSO_GQL_BODY",       st_local("body"))
    mata: st_global("SUSO_GQL_OPERATIONS", "")
    mata: st_global("SUSO_UP_FILE",        "")
    _suso_gql , `verbose'
    return scalar http = r(http)
end

program _suso_export_get, rclass
    * Start one export, poll to completion, download it. Errors (exit 459) on
    * failure/timeout so callers can wrap in capture. A Completed job with no
    * data file returns r(status)=="NoFile" (not an error). Mirrors the backup
    * notebook's start_export / wait_for_export / download_export chain.
    syntax , TYPE(string) SAVING(string) [ GUID(string) QVER(integer 0)         ///
        ISTATUS(string) FROM(string) TO(string) REDUCED META NOMETA             ///
        POLLSecs(integer 10) JOBTimeout(integer 3600) replace VERBOSE ]
    if "`istatus'"=="" local istatus "All"
    local metaopt = cond("`nometa'"!="","nometa","meta")
    local redopt  = cond("`reduced'"!="","paradatareduced","")
    suso export start , type(`type') guid(`guid') qver(`qver') istatus(`istatus') ///
        from(`from') to(`to') `redopt' `metaopt' `verbose'
    local jid `"`r(jobid)'"'
    if `"`jid'"'=="" {
        di as err "suso: export start returned no JobId."
        exit 459
    }
    local elapsed = 0
    local status  ""
    local hasfile "true"
    while 1 {
        suso export status , id(`jid') `verbose'
        local status  `"`r(exportstatus)'"'
        local hasfile `"`r(hasexportfile)'"'
        if "`status'"=="Completed" continue, break
        if inlist("`status'","Fail","Failed","Canceled","Cancelled") {
            di as err "suso: export job `jid' `status'."
            exit 459
        }
        if `elapsed' >= `jobtimeout' {
            di as err "suso: export job `jid' timed out after `jobtimeout's (status=`status')."
            exit 459
        }
        sleep `=`pollsecs'*1000'
        local elapsed = `elapsed' + `pollsecs'
    }
    * Completed but no data for this type -> nothing to download (not a failure).
    if inlist(lower(`"`hasfile'"'),"false","0","no") {
        return local saved  ""
        return scalar jobid = `jid'
        return local status "NoFile"
        exit
    }
    capture suso export download , id(`jid') saving(`"`saving'"') `replace' `verbose'
    if _rc {
        * the /file endpoint can 403/404 for a beat right after Completed: retry once
        sleep 2000
        suso export download , id(`jid') saving(`"`saving'"') `replace' `verbose'
    }
    return local saved  `"`r(saved)'"'
    return scalar jobid = `jid'
    return local status "`status'"
end

program _suso_backup, rclass
    * Full-workspace backup (mirrors data_backup_SuSo notebook), built entirely
    * on existing suso verbs:
    *   questionnaires/  questionnaires_list.dta + <title>_v<ver>_document.json
    *   exports/         <title>_v<ver>_<TYPE>.zip  (one per questionnaire x type)
    *   workspace/       assignments.dta, supervisors.dta
    version 14.2
    syntax , DIR(string) [ TYPEs(string) ISTATUS(string) NOMETA                  ///
        POLLSecs(integer 10) JOBTimeout(integer 3600)                            ///
        NOExports NOQuestionnaires NOWorkspace VERBOSE ]

    if "$SUSO_BASE"=="" | "$SUSO_WS"=="" {
        di as err "suso backup: configure first.  suso config , server(<url>) workspace(<name>)"
        exit 198
    }
    if `"`types'"'=="" local types "STATA"
    if "`istatus'"=="" local istatus "All"
    local metaopt = cond("`nometa'"!="","nometa","meta")

    local dir = subinstr(`"`dir'"', "\", "/", .)
    if substr(`"`dir'"',-1,1)=="/" local dir = substr(`"`dir'"',1,length(`"`dir'"')-1)
    capture mkdir `"`dir'"'
    capture mkdir `"`dir'/exports"'
    capture mkdir `"`dir'/questionnaires"'
    capture mkdir `"`dir'/workspace"'

    di as txt "{hline 66}"
    di as txt "suso backup:  " as res "$SUSO_BASE/$SUSO_WS" as txt "  ->  " as res `"`dir'"'
    di as txt "{hline 66}"

    preserve
    local nok   = 0
    local nfail = 0
    local nskip = 0

    * ---- questionnaires: list metadata ----
    local haveq = 0
    capture suso questionnaire list , all
    if _rc {
        di as err "  questionnaires: list FAILED (rc=`=_rc') — skipping documents & exports."
        local ++nfail
    }
    else {
        local haveq = 1
        quietly save `"`dir'/questionnaires/questionnaires_list.dta"', replace
        di as txt "  questionnaires: " as res "`=_N'" as txt " version(s)"
    }

    * ---- per-version: document + exports (none of these clobber the dataset) ----
    if `haveq' {
        local nq = _N
        forvalues i = 1/`nq' {
            local guid  = QuestionnaireId[`i']
            local ver   = Version[`i']
            local title = Title[`i']
            local tag = ustrregexra(`"`title'"', "[^A-Za-z0-9._-]+", "_")
            local tag = ustrregexra(`"`tag'"', "^_+|_+$", "")
            if length(`"`tag'"') > 60 local tag = substr(`"`tag'"',1,60)
            local stub "`tag'_v`ver'"

            if "`noquestionnaires'"=="" {
                capture suso questionnaire document , guid(`guid') qver(`ver') saving(`"`dir'/questionnaires/`stub'_document.json"') replace
                if _rc local ++nfail
            }
            if "`noexports'"=="" {
                foreach et of local types {
                    local dest `"`dir'/exports/`stub'_`et'.zip"'
                    di as txt "  export: " as res "`stub' [`et']" as txt " ..."
                    capture _suso_export_get , type(`et') guid(`guid') qver(`ver') ///
                        istatus(`istatus') `metaopt' pollsecs(`pollsecs')          ///
                        jobtimeout(`jobtimeout') saving(`"`dest'"') replace `verbose'
                    if _rc {
                        local ++nfail
                        di as err "    FAILED (rc=`=_rc')"
                    }
                    else if `"`r(status)'"'=="NoFile" {
                        local ++nskip
                        di as txt "    no data — skipped"
                    }
                    else {
                        local ++nok
                        di as txt "    saved " as res `"`r(saved)'"'
                    }
                }
            }
        }
    }

    * ---- workspace objects (these reload the dataset, so do them last) ----
    if "`noworkspace'"=="" {
        capture suso assignment list , all
        if _rc {
            di as err "  assignments: FAILED (rc=`=_rc')"
            local ++nfail
        }
        else {
            quietly save `"`dir'/workspace/assignments.dta"', replace
            di as txt "  assignments: " as res "`=_N'" as txt " saved"
        }
        capture suso supervisor list , all
        if _rc {
            di as err "  supervisors: FAILED (rc=`=_rc')"
            local ++nfail
        }
        else {
            quietly save `"`dir'/workspace/supervisors.dta"', replace
            di as txt "  supervisors: " as res "`=_N'" as txt " saved"
        }
    }

    restore
    di as txt _n "{hline 66}"
    di as txt "suso backup: done.  " as res "`nok'" as txt " export(s) saved, "    ///
        as res "`nskip'" as txt " empty/skipped, " as res "`nfail'" as txt " failed."
    di as txt "Output: " as res `"`dir'"'
    return scalar ok      = `nok'
    return scalar skipped = `nskip'
    return scalar failed  = `nfail'
end

program _suso_jar
    if "$SUSO_JAR"=="" {
        * 1) anywhere on the adopath
        capture findfile suso.jar
        if !_rc global SUSO_JAR "`r(fn)'"
    }
    if "$SUSO_JAR"=="" {
        * 2) right next to suso.ado
        capture findfile suso.ado
        if !_rc {
            local ad = subinstr(`"`r(fn)'"', "\", "/", .)
            local k = strrpos(`"`ad'"', "/")
            if `k'>0 {
                local dir = substr(`"`ad'"', 1, `k')
                foreach c in `"`dir'suso.jar"' `"`dir'jar/suso.jar"' {
                    capture confirm file `"`c'"'
                    if !_rc {
                        global SUSO_JAR `"`c'"'
                        continue, break
                    }
                }
            }
        }
    }
    if "$SUSO_JAR"=="" {
        * 3) standard Stata folders
        foreach w in PERSONAL PLUS SITE OLDPLACE {
            capture local root : sysdir `w'
            if !_rc & `"`root'"'!="" {
                local root = subinstr(`"`root'"', "\", "/", .)
                foreach c in `"`root'suso.jar"' `"`root's/suso.jar"' `"`root'jar/suso.jar"' {
                    capture confirm file `"`c'"'
                    if !_rc {
                        global SUSO_JAR `"`c'"'
                        continue, break
                    }
                }
            }
            if "$SUSO_JAR"!="" continue, break
        }
    }
    if "$SUSO_JAR"=="" {
        di as err "suso: could not locate suso.jar."
        di as err "      Put it next to suso.ado (e.g. in `c(sysdir_plus)'s/) or run:"
        di as err "      suso config , jar(c:/full/path/to/suso.jar)"
        exit 601
    }
    * Normalize Windows backslashes to forward slashes for javacall/Java.
    mata: st_global("SUSO_JAR", subinstr(st_global("SUSO_JAR"), char(92), char(47)))
    capture confirm file "$SUSO_JAR"
    if _rc {
        di as err "suso: jar not found at:  $SUSO_JAR"
        di as err "      Fix with:  suso config , jar(c:/full/path/to/suso.jar)"
        exit 601
    }
end

* The workhorse: set bridge globals, call Java, surface results / errors in r().
* The request BODY (if any) is set by the caller in global SUSO_BODY_REQ.
program _suso_call, rclass
    version 14.2
    syntax , METHOD(string) PATH(string) [ QUERY(string) CType(string)         ///
        ACCept(string) TODATA ARRAYkey(string) SAVEfile(string)                ///
        DESTRUCTIVE ALLOW ROOT VERBOSE ]

    _suso_init
    _suso_jar

    if "$SUSO_BASE"=="" {
        di as err "suso: no server configured.  suso config , server(<url>) workspace(<name>)"
        exit 198
    }
    if "$SUSO_WS"=="" & "`root'"=="" {
        di as err "suso: no workspace configured.  suso config , workspace(<name>)"
        exit 198
    }

    global SUSO_PATH     `"`path'"'
    global SUSO_METHOD   "`method'"
    global SUSO_QUERY    `"`query'"'
    global SUSO_CTYPE    "`ctype'"
    global SUSO_ACCEPT   "`accept'"
    * Resolve a relative save path against Stata's working dir (not the JVM's, which
    * is the bundled-JDK bin folder). Absolute = starts with drive (C:), / or \.
    if `"`savefile'"' != "" {
        local _abs 0
        if substr(`"`savefile'"',2,1)==":"  local _abs 1
        if substr(`"`savefile'"',1,1)=="/"  local _abs 1
        if substr(`"`savefile'"',1,1)=="\"  local _abs 1
        if !`_abs' local savefile `"`c(pwd)'/`savefile'"'
    }
    global SUSO_SAVEFILE `"`savefile'"'
    global SUSO_ARRAYKEY "`arraykey'"
    global SUSO_TODATA   = cond("`todata'"!="","1","0")
    global SUSO_VERBOSE  = cond(("`verbose'"!="" | "$SUSO_DEBUG"=="1"),"1","0")
    global SUSO_DESTRUCTIVE       = cond("`destructive'"!="","1","0")
    global SUSO_ALLOW_DESTRUCTIVE = cond("`allow'"!="","1","0")
    if "`root'"!="" global SUSO_PATHBASE ""
    else            global SUSO_PATHBASE "/$SUSO_WS"
    * SUSO_BODY_REQ is set by the caller (may be empty). Check its length without
    * expanding it inline (the body holds double quotes / $ and would break a "..." compare).
    local _brq : copy global SUSO_BODY_REQ
    if `:length local _brq'==0 global SUSO_BODY_REQ ""

    if "`todata'"!="" clear

    capture noisily javacall org.worldbank.suso.Stata run , classpath("$SUSO_JAR")
    local jrc = _rc

    local rc       "$SUSO_RC"
    local http     "$SUSO_HTTP"
    local msg      `"$SUSO_MSG"'
    local nobs     "$SUSO_NOBS"
    local nvars    "$SUSO_NVARS"
    local total    "$SUSO_TOTALCOUNT"
    local saved    `"$SUSO_SAVED"'
    local bytes    "$SUSO_BYTES"
    local datecols "$SUSO_DATECOLS"
    local fkeys    "$SUSO_FKEYS"
    foreach k of local fkeys {
        local F_`k' `"${SUSO_F_`k'}"'
    }

    if `jrc' {
        _suso_clearbridge
        di as err "suso: the Java call failed (Stata rc=`jrc')."
        di as err "      Check suso.jar and that Stata runs Java 11+ :  suso doctor"
        exit `jrc'
    }
    if "`rc'"=="" {
        _suso_clearbridge
        di as err "suso: no response from the Java backend (it may not have executed)."
        exit 459
    }
    if "`rc'"!="0" {
        _suso_clearbridge
        di as err `"suso: `macval(msg)'"'
        exit 459
    }

    * ---- success ----
    if "`todata'"!="" {
        if "`datecols'"!="" capture _suso_todate `datecols'
        if "`nobs'"!=""  return scalar nobs  = real("`nobs'")
        if "`nvars'"!="" return scalar nvars = real("`nvars'")
        if "`total'"!="" return scalar totalcount = real("`total'")
    }
    if "`savefile'"!="" {
        return local saved `"`saved'"'
        if "`bytes'"!="" return scalar bytes = real("`bytes'")
    }
    foreach k of local fkeys {
        return local `k' `"`F_`k''"'
    }
    return local http "`http'"
    if `"`macval(msg)'"'!="" return local message `"`macval(msg)'"'

    _suso_clearbridge
end

program _suso_clearbridge
    capture macro drop SUSO_PATH SUSO_METHOD SUSO_QUERY SUSO_BODY_REQ SUSO_CTYPE   ///
        SUSO_ACCEPT SUSO_SAVEFILE SUSO_ARRAYKEY SUSO_TODATA SUSO_VERBOSE           ///
        SUSO_DESTRUCTIVE SUSO_ALLOW_DESTRUCTIVE SUSO_PATHBASE SUSO_RC SUSO_HTTP    ///
        SUSO_MSG SUSO_BODY SUSO_NOBS SUSO_NVARS SUSO_TOTALCOUNT SUSO_LIMIT         ///
        SUSO_OFFSET SUSO_SAVED SUSO_BYTES SUSO_DATECOLS SUSO_FKEYS
    local gl : all globals
    foreach g of local gl {
        if substr("`g'", 1, 7)=="SUSO_F_" capture macro drop `g'
    }
end

* Convert ISO-8601 string columns (flagged by the backend) to Stata %tc doubles.
program _suso_todate
    version 14.2
    foreach v of local 0 {
        capture confirm string variable `v'
        if _rc continue
        local lbl : variable label `v'
        tempvar t
        quietly gen double `t' = clock(subinstr(substr(`v',1,19),"T"," ",1), "YMDhms")
        quietly drop `v'
        quietly rename `t' `v'
        format `v' %tcCCYY-NN-DD_HH:MM:SS
        if `"`lbl'"'!="" label variable `v' `"`lbl'"'
    }
end

* Generic paginator. MODE is "rows" (offset=#rows skipped) or "page" (offset/page=page no.).
program _suso_getall, rclass
    version 14.2
    syntax , PATH(string) MODE(string) SIZEparam(string) PAGEparam(string)     ///
        [ BASEQ(string) MAXsize(integer 200) ARRAYkey(string) ROOT VERBOSE     ///
          ALL LIMIT(integer 0) OFFSET(integer -1) PAGE(integer -1) PAGESize(integer 0) ]

    local rootopt = cond("`root'"!="","root","")
    local vopt    = cond("`verbose'"!="","verbose","")

    local size = `pagesize'
    if `size'<=0       local size = `maxsize'
    if `size'>`maxsize' local size = `maxsize'
    if `size'<=0       local size 100

    local single 0
    if (`offset'>=0 | `page'>=0) local single 1
    if "`all'"=="" & `single'==0 local single 1

    if "`mode'"=="rows" local pos = cond(`offset'>=0, `offset', 0)
    else                local pos = cond(`page'>=0, `page', 1)

    local maxrows = real("$SUSO_MAXROWS")
    if `maxrows'<=0 local maxrows 100000

    tempfile acc
    local got 0
    local total .
    local first 1

    while (1) {
        local q "`baseq'"
        if "`q'"!="" local q "`q'&"
        local q "`q'`pageparam'=`pos'&`sizeparam'=`size'"

        _suso_call , method(GET) path(`path') query(`q') todata arraykey(`arraykey') `rootopt' `vopt'
        local n = r(nobs)
        if "`n'"=="" local n 0
        if !missing(r(totalcount)) local total = r(totalcount)

        if `first' {
            quietly save `"`acc'"', replace
            local first 0
        }
        else {
            tempfile pg
            quietly save `"`pg'"', replace
            quietly use `"`acc'"', clear
            capture quietly append using `"`pg'"'
            if _rc {
                di as txt "suso: stopping pagination (column types differ across pages); returning rows so far."
                quietly save `"`acc'"', replace
                continue, break
            }
            quietly save `"`acc'"', replace
        }
        local got = `got' + `n'

        if `single'                                continue, break
        if `n'==0                                  continue, break
        if `limit'>0 & `got'>=`limit'              continue, break
        if `got'>=`maxrows' {
            di as txt "suso: reached safety cap of `maxrows' rows ({bf:SUSO_MAXROWS}). For very large pulls use {bf:suso export}."
            continue, break
        }
        if !missing(`total') & `got'>=`total'      continue, break

        * The server may return fewer rows than requested (it caps the page size).
        * Adopt its real page size so the next page's offset stays aligned (no gaps).
        if `n'>0 & `n'<`size' local size = `n'

        if "`mode'"=="rows" local pos = `pos' + `n'
        else                local pos = `pos' + 1
    }

    quietly use `"`acc'"', clear
    if `limit'>0 & _N>`limit' quietly keep in 1/`limit'

    return scalar nobs = _N
    if !missing(`total') return scalar totalcount = `total'
end

* ---- safety gates --------------------------------------------------------------
program _suso_block
    version 14.2
    syntax , ACTion(string) [ CONFIRM ]
    if "`confirm'"=="" {
        di as err "{hline 64}"
        di as err "DESTRUCTIVE OPERATION — not executed."
        di as err "  `action'"
        di as err " "
        di as err "  Re-run with the  {bf:, confirm}  option to actually perform it."
        di as err "{hline 64}"
        exit 1
    }
end

program _suso_block_ws
    version 14.2
    syntax , NAME(string) [ Iknowthis(string) ]
    if `"`iknowthis'"' != `"`name'"' {
        di as err "{hline 64}"
        di as err "DELETE WORKSPACE — refusing (this permanently removes ALL data in it)."
        di as err "  To proceed you must type the exact workspace name back:"
        di as err "      suso workspace delete , name(`name') iknowthis(`name')"
        di as err "{hline 64}"
        exit 1
    }
end

program _suso_audit
    version 14.2
    syntax , ACTion(string) [ TARGET(string) HTTP(string) ]
    local f "$SUSO_AUDIT"
    if "`f'"=="" local f "`c(sysdir_personal)'suso_audit.log"
    capture file open _sa using `"`f'"', write append text
    if _rc exit
    file write _sa `"`c(current_date)' `c(current_time)' | user=$SUSO_USER | $SUSO_BASE/$SUSO_WS | `action' | target=`target' | http=`http'"' _n
    file close _sa
end

* ---- tiny utilities ------------------------------------------------------------
program _suso_enc, rclass
    gettoken val : 0
    mata: st_local("___enc", suso_urlencode(st_local("val")))
    return local enc `"`___enc'"'
end

program _suso_jsonesc, rclass
    gettoken val : 0
    mata: st_local("___js", suso_jsonesc(st_local("val")))
    return local js `"`___js'"'
end

program _suso_isuuid, rclass
    gettoken val : 0
    local val = trim("`val'")
    if regexm("`val'","^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$") ///
        return scalar isuuid = 1
    else return scalar isuuid = 0
end

* Build "{guid}${version}" without ever putting a literal $ into a macro.
program _suso_qid, rclass
    version 14.2
    syntax , GUID(string) [ QVER(integer 0) ]
    if `qver'>0 return local qid "`guid'__DOLLAR__`qver'"
    else        return local qid "`guid'"
end

* Fill guid/qver in the CALLER from the session defaults ($SUSO_GUID/$SUSO_QVER)
* whenever the user omitted them, so the questionnaire only needs to be set once.
program _suso_gq
    args g q
    if `"`g'"'=="" & "$SUSO_GUID"!="" c_local guid "$SUSO_GUID"
    if (`"`q'"'=="" | `"`q'"'=="0") & "$SUSO_QVER"!="" c_local qver "$SUSO_QVER"
end

* Require a questionnaire (after _suso_gq); friendly message if still missing.
program _suso_needq
    args g
    if `"`g'"'=="" {
        di as err "suso: this needs a questionnaire. Either add  guid(<GUID>) qver(<ver>)  ,"
        di as err "      or set it once for the session:  suso config , guid(<GUID>) qver(<ver>)"
        di as err "      (find the GUID/version with:  suso questionnaire list )"
        exit 198
    }
end

*===============================================================================
* raw — escape hatch to call any endpoint
*===============================================================================
program _suso_raw, rclass
    version 14.2
    syntax anything(name=path id="path"), [ METHOD(string) Query(string)       ///
        CType(string) ACCept(string) TODATA ARRAYkey(string) SAVEfile(string)  ///
        BODY(string) ROOT ALLOWdestructive VERBOSE ]
    if "`method'"=="" local method GET
    if `"`body'"'!="" global SUSO_BODY_REQ `"`body'"'
    local allowopt = cond("`allowdestructive'"!="","allow","")
    local destopt  = cond("`allowdestructive'"!="","destructive","")
    local rootopt  = cond("`root'"!="","root","")
    local vopt     = cond("`verbose'"!="","verbose","")
    local todopt   = cond("`todata'"!="","todata","")
    _suso_call , method(`method') path(`path') query(`query') ct(`ctype') acc(`accept') ///
        `todopt' arraykey(`arraykey') savefile(`savefile') `rootopt' `destopt' `allowopt' `vopt'
    return add
end

*===============================================================================
* Assignments
*===============================================================================
program _suso_assignment, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="list" {
        syntax [, SEARCHby(string) GUID(string) QVER(integer 0) RESPonsible(string) ///
            SUPervisor(string) ORDer(string) ARCHIVEd ALL LIMIT(integer 0)          ///
            OFFSET(integer -1) PAGESize(integer 0) VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        local q ""
        if "`searchby'"!="" {
            _suso_enc `"`searchby'"'
            local q "`q'&SearchBy=`r(enc)'"
        }
        if "`guid'"!="" {
            _suso_qid , guid(`guid') qver(`qver')
            _suso_enc `"`r(qid)'"'
            local q "`q'&QuestionnaireId=`r(enc)'"
        }
        if "`responsible'"!="" {
            _suso_enc `"`responsible'"'
            local q "`q'&Responsible=`r(enc)'"
        }
        if "`supervisor'"!=""  {
            _suso_enc `"`supervisor'"'
            local q "`q'&SupervisorId=`r(enc)'"
        }
        if "`order'"!=""       {
            _suso_enc `"`order'"'
            local q "`q'&Order=`r(enc)'"
        }
        if "`archived'"!=""    local q "`q'&ShowArchive=true"
        if substr("`q'",1,1)=="&" local q = substr("`q'",2,.)
        local vopt = cond("`verbose'"!="","verbose","")
        _suso_getall , path(/api/v1/assignments) mode(rows) sizeparam(Limit) pageparam(Offset) ///
            maxsize(200) arraykey(Assignments) baseq(`q') `all' limit(`limit') offset(`offset') ///
            pagesize(`pagesize') `vopt'
        di as txt "suso: fetched " as res "`=r(nobs)'" as txt " assignment(s)" ///
            cond(!missing(r(totalcount))," of `=r(totalcount)' on server","")
        return add
        exit
    }

    if "`verb'"=="get" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(GET) path(/api/v1/assignments/`id') `verbose'
        di as txt "Assignment " as res "`id'" as txt ":  responsible=" as res `"`r(responsiblename)'"' ///
            as txt "  quantity=" as res `"`r(quantity)'"' as txt "  done=" as res `"`r(interviewscount)'"' ///
            as txt "  archived=" as res `"`r(archived)'"'
        return add
        exit
    }

    if "`verb'"=="history" {
        syntax , ID(string) [ START(integer 0) LENGTH(integer 1000) VERBOSE ]
        _suso_call , method(GET) path(/api/v1/assignments/`id'/history)            ///
            query(start=`start'&length=`length') todata arraykey(History) `verbose'
        di as txt "suso: " as res "`=r(nobs)'" as txt " history record(s) for assignment `id'."
        return add
        exit
    }

    if "`verb'"=="quantitysettings" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(GET) path(/api/v1/assignments/`id'/assignmentQuantitySettings) `verbose'
        di as txt "Assignment `id': CanChangeQuantity=" as res `"`r(canchangequantity)'"'
        return add
        exit
    }

    if "`verb'"=="create" {
        syntax , RESPonsible(string) [ GUID(string) QVER(integer 0)             ///
            QUANTity(string) EMAIL(string) PASSword(string) WEBmode             ///
            AUDIO COMMents(string) TARGETarea(string) IDENTifying(string) VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        _suso_needq "`guid'"
        _suso_qid , guid(`guid') qver(`qver')
        local qid "`r(qid)'"
        _suso_jsonesc `"`responsible'"'
        local resp "`r(js)'"
        local body `"{"Responsible":"`resp'","QuestionnaireId":"`qid'""'
        if "`quantity'"!=""   local body `"`body',"Quantity":`quantity'"'
        if "`email'"!="" {
            _suso_jsonesc `"`email'"'
            local body `"`body',"Email":"`r(js)'""'
        }
        if "`password'"!="" {
            _suso_jsonesc `"`password'"'
            local body `"`body',"Password":"`r(js)'""'
        }
        if "`webmode'"!=""    local body `"`body',"WebMode":true"'
        if "`audio'"!=""      local body `"`body',"IsAudioRecordingEnabled":true"'
        if "`comments'"!="" {
            _suso_jsonesc `"`comments'"'
            local body `"`body',"Comments":"`r(js)'""'
        }
        if "`targetarea'"!="" {
            _suso_jsonesc `"`targetarea'"'
            local body `"`body',"TargetArea":"`r(js)'""'
        }
        if `"`identifying'"'!="" local body `"`body',"IdentifyingData":`identifying'"'
        else                     local body `"`body',"IdentifyingData":[]"'
        local body `"`body'}"'
        global SUSO_BODY_REQ `"`body'"'
        _suso_call , method(POST) path(/api/v1/assignments) `verbose'
        di as txt "suso: assignment created (HTTP " as res "`r(http)'" as txt ")."
        return add
        exit
    }

    if "`verb'"=="assign" {
        syntax , ID(string) RESPonsible(string) [ VERBOSE ]
        _suso_jsonesc `"`responsible'"'
        local r "`r(js)'"
        global SUSO_BODY_REQ `"{"Responsible":"`r'"}"'
        _suso_call , method(PATCH) path(/api/v1/assignments/`id'/assign) `verbose'
        di as txt "suso: assignment `id' reassigned (HTTP " as res "`r(http)'" as txt ")."
        return add
        exit
    }

    if "`verb'"=="quantity" {
        syntax , ID(string) N(string) [ VERBOSE ]
        if !regexm("`n'","^-?[0-9]+$") {
            di as err "suso: -n()- must be an integer (use -1 for unlimited)."
            exit 198
        }
        global SUSO_BODY_REQ "`n'"
        _suso_call , method(PATCH) path(/api/v1/assignments/`id'/changeQuantity) `verbose'
        di as txt "suso: assignment `id' quantity set to " as res "`n'" as txt " (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="close" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(PATCH) path(/api/v1/assignments/`id'/close) `verbose'
        di as txt "suso: assignment `id' closed (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="archive" {
        syntax , ID(string) [ CONFIRM VERBOSE ]
        _suso_block , action("Archive assignment `id' in workspace $SUSO_WS") `confirm'
        _suso_call , method(PATCH) path(/api/v1/assignments/`id'/archive) destructive allow `verbose'
        _suso_audit , action("assignment archive") target("`id'") http("`r(http)'")
        di as txt "suso: assignment `id' archived (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="unarchive" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(PATCH) path(/api/v1/assignments/`id'/unarchive) `verbose'
        di as txt "suso: assignment `id' unarchived (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="audio" {
        syntax , ID(string) [ ON OFF VERBOSE ]
        if "`on'"=="" & "`off'"=="" {
            di as err "suso: specify -on- or -off-."
            exit 198
        }
        local en = cond("`on'"!="","true","false")
        global SUSO_BODY_REQ `"{"Enabled":`en'}"'
        _suso_call , method(PATCH) path(/api/v1/assignments/`id'/recordAudio) `verbose'
        di as txt "suso: assignment `id' audio recording = " as res "`en'" as txt " (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="targetarea" {
        syntax , ID(string) AREA(string) [ VERBOSE ]
        _suso_jsonesc `"`area'"'
        local a "`r(js)'"
        global SUSO_BODY_REQ `""`a'""'
        _suso_call , method(POST) path(/api/v1/assignments/`id'/changeTargetArea) `verbose'
        di as txt "suso: assignment `id' target area updated (HTTP `r(http)')."
        return add
        exit
    }

    di as err "suso assignment: unknown action '`verb''.  See {help suso}."
    exit 198
end

*===============================================================================
* Interviews
*===============================================================================
program _suso_interview, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="list" {
        syntax [, GUID(string) QVER(integer 0) STATUS(string) ID(string)        ///
            ALL LIMIT(integer 0) PAGE(integer -1) PAGESize(integer 0) VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        local q ""
        if "`guid'"!=""   local q "`q'&questionnaireId=`guid'"
        if `qver'>0       local q "`q'&questionnaireVersion=`qver'"
        if "`status'"!="" local q "`q'&status=`status'"
        if "`id'"!=""     local q "`q'&interviewId=`id'"
        if substr("`q'",1,1)=="&" local q = substr("`q'",2,.)
        local vopt = cond("`verbose'"!="","verbose","")
        _suso_getall , path(/api/v1/interviews) mode(page) sizeparam(pageSize) pageparam(page) ///
            maxsize(100) arraykey(Interviews) baseq(`q') `all' limit(`limit') page(`page')      ///
            pagesize(`pagesize') `vopt'
        di as txt "suso: fetched " as res "`=r(nobs)'" as txt " interview(s)" ///
            cond(!missing(r(totalcount))," of `=r(totalcount)' on server","")
        return add
        exit
    }

    if "`verb'"=="get" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(GET) path(/api/v1/interviews/`id') todata arraykey(Answers) `verbose'
        di as txt "suso: " as res "`=r(nobs)'" as txt " answer rows for interview `id'."
        return add
        exit
    }

    if "`verb'"=="stats" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(GET) path(/api/v1/interviews/`id'/stats) `verbose'
        di as txt "Interview `id': answered=" as res `"`r(answered)'"' as txt "  invalid=" ///
            as res `"`r(invalid)'"' as txt "  withcomments=" as res `"`r(withcomments)'"' ///
            as txt "  status=" as res `"`r(status)'"'
        return add
        exit
    }

    if "`verb'"=="history" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(GET) path(/api/v1/interviews/`id'/history) todata arraykey(Records) `verbose'
        di as txt "suso: " as res "`=r(nobs)'" as txt " history record(s) for interview `id'."
        return add
        exit
    }

    if "`verb'"=="pdf" {
        syntax , ID(string) SAVING(string) [ replace VERBOSE ]
        if "`replace'"=="" {
            capture confirm new file `"`saving'"'
            if _rc {
                di as err "suso: file already exists. Use -replace-."
                exit 602
            }
        }
        _suso_call , method(GET) path(/api/v1/interviews/`id'/pdf) savefile(`saving') accept(application/pdf) `verbose'
        di as txt "suso: saved interview PDF to " as res `"`r(saved)'"' as txt " (`r(bytes)' bytes)."
        return add
        exit
    }

    if inlist("`verb'","approve","hqapprove","hqunapprove") {
        syntax , ID(string) [ COMMENT(string) VERBOSE ]
        local q ""
        if "`comment'"!="" {
            _suso_enc `"`comment'"'
            local q "comment=`r(enc)'"
        }
        _suso_call , method(PATCH) path(/api/v1/interviews/`id'/`verb') query(`q') `verbose'
        di as txt "suso: interview `id' `verb' OK (HTTP `r(http)')."
        return add
        exit
    }

    if inlist("`verb'","reject","hqreject") {
        syntax , ID(string) [ COMMENT(string) RESPonsible(string) VERBOSE ]
        local q ""
        if "`comment'"!=""     {
            _suso_enc `"`comment'"'
            local q "comment=`r(enc)'"
        }
        if "`responsible'"!="" {
            _suso_enc `"`responsible'"'
            local q "`q'&responsibleId=`r(enc)'"
        }
        if substr("`q'",1,1)=="&" local q = substr("`q'",2,.)
        _suso_call , method(PATCH) path(/api/v1/interviews/`id'/`verb') query(`q') `verbose'
        di as txt "suso: interview `id' `verb' OK (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="assign" | "`verb'"=="assignsupervisor" {
        syntax , ID(string) [ RESPonsible(string) RESPONSIBLEID(string) RESPONSIBLEName(string) VERBOSE ]
        local rid "`responsibleid'"
        local rnm "`responsiblename'"
        if "`responsible'"!="" {
            _suso_isuuid `"`responsible'"'
            if r(isuuid) local rid "`responsible'"
            else         local rnm "`responsible'"
        }
        if "`rid'"=="" & "`rnm'"=="" {
            di as err "suso: specify responsible(), responsibleid() or responsiblename()."
            exit 198
        }
        if "`rid'"!="" global SUSO_BODY_REQ `"{"ResponsibleId":"`rid'"}"'
        else {
            _suso_jsonesc `"`rnm'"' ; global SUSO_BODY_REQ `"{"ResponsibleName":"`r(js)'"}"'
        }
        _suso_call , method(PATCH) path(/api/v1/interviews/`id'/`verb') `verbose'
        di as txt "suso: interview `id' `verb' OK (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="comment" {
        syntax , ID(string) QUESTION(string) COMMENT(string) [ VERBOSE ]
        _suso_enc `"`comment'"'
        local q "comment=`r(enc)'"
        _suso_call , method(POST) path(/api/v1/interviews/`id'/comment/`question') query(`q') `verbose'
        di as txt "suso: comment added to interview `id' (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="commentbyvar" {
        syntax , ID(string) VARiable(string) COMMENT(string) [ ROSTERvector(numlist) VERBOSE ]
        _suso_enc `"`comment'"'
        local q "comment=`r(enc)'"
        foreach rv of numlist `rostervector' {
            local q "`q'&rosterVector=`rv'"
        }
        _suso_call , method(POST) path(/api/v1/interviews/`id'/comment-by-variable/`variable') query(`q') `verbose'
        di as txt "suso: comment added to interview `id', variable `variable' (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="delete" {
        syntax , ID(string) [ CONFIRM VERBOSE ]
        _suso_block , action("DELETE interview `id' in workspace $SUSO_WS (irreversible)") `confirm'
        _suso_call , method(DELETE) path(/api/v1/interviews/`id') destructive allow `verbose'
        _suso_audit , action("interview delete") target("`id'") http("`r(http)'")
        di as txt "suso: interview `id' deleted (HTTP `r(http)')."
        return add
        exit
    }

    di as err "suso interview: unknown action '`verb''.  See {help suso}."
    exit 198
end

*===============================================================================
* Questionnaires
*===============================================================================
program _suso_questionnaire, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="list" {
        syntax [, ALL LIMIT(integer 0) OFFSET(integer -1) PAGESize(integer 0) VERBOSE ]
        local vopt = cond("`verbose'"!="","verbose","")
        _suso_getall , path(/api/v1/questionnaires) mode(page) sizeparam(limit) pageparam(offset) ///
            maxsize(40) arraykey(Questionnaires) `all' limit(`limit') offset(`offset')             ///
            pagesize(`pagesize') `vopt'
        di as txt "suso: fetched " as res "`=r(nobs)'" as txt " questionnaire(s)" ///
            cond(!missing(r(totalcount))," of `=r(totalcount)' on server","")
        return add
        exit
    }

    if "`verb'"=="get" {
        syntax [, GUID(string) QVER(integer 0) VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        _suso_needq "`guid'"
        if `qver'>0 {
            _suso_call , method(GET) path(/api/v1/questionnaires/`guid'/`qver') `verbose'
            di as txt "Questionnaire " as res `"`r(title)'"' as txt " (v`qver'), variable=" ///
                as res `"`r(variable)'"'
        }
        else {
            _suso_call , method(GET) path(/api/v1/questionnaires/`guid') todata arraykey(Questionnaires) `verbose'
            di as txt "suso: " as res "`=r(nobs)'" as txt " version(s) of questionnaire `guid'."
        }
        return add
        exit
    }

    if "`verb'"=="document" {
        syntax , SAVING(string) [ GUID(string) QVER(integer 0) replace VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        _suso_needq "`guid'"
        if `qver'<=0 {
            di as err "suso: questionnaire document needs a version: qver(<n>) (or set it via suso config)."
            exit 198
        }
        if "`replace'"=="" {
            capture confirm new file `"`saving'"'
            if _rc {
                di as err "suso: file already exists. Use -replace-."
                exit 602
            }
        }
        _suso_call , method(GET) path(/api/v1/questionnaires/`guid'/`qver'/document) savefile(`saving') `verbose'
        di as txt "suso: saved questionnaire document to " as res `"`r(saved)'"' as txt " (`r(bytes)' bytes)."
        return add
        exit
    }

    if "`verb'"=="interviews" {
        syntax [, GUID(string) QVER(integer 0) ALL LIMIT(integer 0) OFFSET(integer -1) PAGESize(integer 0) VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        _suso_needq "`guid'"
        if `qver'<=0 {
            di as err "suso: questionnaire interviews needs a version: qver(<n>) (or set it via suso config)."
            exit 198
        }
        local vopt = cond("`verbose'"!="","verbose","")
        _suso_getall , path(/api/v1/questionnaires/`guid'/`qver'/interviews) mode(page)         ///
            sizeparam(limit) pageparam(offset) maxsize(200) arraykey(Interviews) `all'           ///
            limit(`limit') offset(`offset') pagesize(`pagesize') `vopt'
        di as txt "suso: fetched " as res "`=r(nobs)'" as txt " interview(s) for questionnaire `guid' v`qver'."
        return add
        exit
    }

    if "`verb'"=="audio" {
        syntax [, GUID(string) QVER(integer 0) GET ON OFF VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        _suso_needq "`guid'"
        if `qver'<=0 {
            di as err "suso: questionnaire audio needs a version: qver(<n>) (or set it via suso config)."
            exit 198
        }
        if "`get'"!="" | ("`on'"=="" & "`off'"=="") {
            _suso_call , method(GET) path(/api/v1/questionnaires/`guid'/`qver'/recordAudio) `verbose'
            di as txt "Questionnaire `guid' v`qver': audio recording Enabled=" as res `"`r(enabled)'"'
        }
        else {
            local en = cond("`on'"!="","true","false")
            global SUSO_BODY_REQ `"{"Enabled":`en'}"'
            _suso_call , method(POST) path(/api/v1/questionnaires/`guid'/`qver'/recordAudio) `verbose'
            di as txt "suso: questionnaire `guid' v`qver' audio recording set to " as res "`en'" as txt " (HTTP `r(http)')."
        }
        return add
        exit
    }

    if "`verb'"=="criticality" {
        syntax [, GUID(string) QVER(integer 0) GET LEVEL(string) VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        _suso_needq "`guid'"
        if `qver'<=0 {
            di as err "suso: questionnaire criticality needs a version: qver(<n>) (or set it via suso config)."
            exit 198
        }
        if "`get'"!="" | "`level'"=="" {
            _suso_call , method(GET) path(/api/v1/questionnaires/`guid'/`qver'/criticalityLevel) `verbose'
            di as txt "Questionnaire `guid' v`qver': criticality Enabled=" as res `"`r(enabled)'"'
        }
        else {
            if !inlist(strproper("`level'"),"Unknown","Ignore","Warn","Block") {
                di as err "suso: level() must be one of Unknown, Ignore, Warn, Block."
                exit 198
            }
            global SUSO_BODY_REQ `"{"CriticalityLevel":"`=strproper("`level'")'"}"'
            _suso_call , method(POST) path(/api/v1/questionnaires/`guid'/`qver'/criticalityLevel) `verbose'
            di as txt "suso: questionnaire `guid' v`qver' criticality set to " as res "`level'" as txt " (HTTP `r(http)')."
        }
        return add
        exit
    }

    di as err "suso questionnaire: unknown action '`verb''.  See {help suso}."
    exit 198
end

*===============================================================================
* Export
*===============================================================================
program _suso_export, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="list" {
        syntax [, TYPE(string) ISTATUS(string) GUID(string) QVER(integer 0)     ///
            ESTATUS(string) HASfile ALL LIMIT(integer 0) OFFSET(integer -1)     ///
            PAGESize(integer 0) VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        local q ""
        if "`type'"!=""    local q "`q'&exportType=`type'"
        if "`istatus'"!="" local q "`q'&interviewStatus=`istatus'"
        if "`guid'"!="" {
            _suso_qid , guid(`guid') qver(`qver')
            _suso_enc `"`r(qid)'"'
            local q "`q'&questionnaireIdentity=`r(enc)'"
        }
        if "`estatus'"!="" local q "`q'&exportStatus=`estatus'"
        if "`hasfile'"!="" local q "`q'&hasFile=true"
        if substr("`q'",1,1)=="&" local q = substr("`q'",2,.)
        local vopt = cond("`verbose'"!="","verbose","")
        _suso_getall , path(/api/v2/export) mode(rows) sizeparam(limit) pageparam(offset) ///
            maxsize(200) arraykey() baseq(`q') `all' limit(`limit') offset(`offset')       ///
            pagesize(`pagesize') `vopt'
        di as txt "suso: fetched " as res "`=r(nobs)'" as txt " export job(s)."
        return add
        exit
    }

    if "`verb'"=="start" {
        syntax , TYPE(string) [ ISTATUS(string) GUID(string) QVER(integer 0)    ///
            FROM(string) TO(string) META NOMETA PARADATAReduced VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        _suso_needq "`guid'"
        if `qver'<=0 {
            di as err "suso: export needs a questionnaire VERSION. Add qver(<n>) ,"
            di as err "      or set it once:  suso config , guid(<GUID>) qver(<n>)"
            exit 198
        }
        if "`istatus'"=="" local istatus All
        _suso_qid , guid(`guid') qver(`qver')
        local qid "`r(qid)'"
        local body `"{"ExportType":"`type'","QuestionnaireId":"`qid'","InterviewStatus":"`istatus'""'
        if "`from'"!="" {
            _suso_jsonesc `"`from'"'
            local body `"`body',"From":"`r(js)'""'
        }
        if "`to'"!="" {
            _suso_jsonesc `"`to'"'
            local body `"`body',"To":"`r(js)'""'
        }
        if "`meta'"!=""   local body `"`body',"IncludeMeta":true"'
        if "`nometa'"!="" local body `"`body',"IncludeMeta":false"'
        if "`paradatareduced'"!="" local body `"`body',"ParadataReduced":true"'
        local body `"`body'}"'
        global SUSO_BODY_REQ `"`body'"'
        _suso_call , method(POST) path(/api/v2/export) `verbose'
        di as txt "suso: export started — JobId=" as res `"`r(jobid)'"' as txt "  status=" ///
            as res `"`r(exportstatus)'"' as txt " (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="status" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(GET) path(/api/v2/export/`id') `verbose'
        di as txt "Export `id': status=" as res `"`r(exportstatus)'"' as txt "  progress=" ///
            as res `"`r(progress)'"' as txt "%  hasFile=" as res `"`r(hasexportfile)'"'
        return add
        exit
    }

    if "`verb'"=="get" {
        * one-shot convenience: start -> poll -> download [-> unzip]
        syntax , TYPE(string) SAVING(string) [ GUID(string) QVER(integer 0)     ///
            ISTATUS(string) FROM(string) TO(string) PARADATAReduced META NOMETA ///
            POLLSecs(integer 10) JOBTimeout(integer 3600) replace               ///
            UNZIP UNZIPW(string) UNZIPto(string) VERBOSE ]
        local redopt = cond("`paradatareduced'"!="","reduced","")
        _suso_export_get , type(`type') saving(`"`saving'"') guid(`guid')       ///
            qver(`qver') istatus(`istatus') from(`from') to(`to') `redopt'      ///
            `meta' `nometa' pollsecs(`pollsecs') jobtimeout(`jobtimeout')       ///
            `replace' `verbose'
        local gstatus `"`r(status)'"'
        local gsaved  `"`r(saved)'"'
        return add
        if "`gstatus'"=="NoFile" {
            di as txt "suso: job completed with no data file for this type/filter — nothing to download."
            exit
        }
        di as txt "suso: downloaded export to " as res `"`gsaved'"'
        if "`unzip'"!="" | `"`unzipw'"'!="" | `"`unzipto'"'!="" {
            if `"`unzipw'"'=="" local unzipw `"$SUSO_EXPORTPWD"'
            _suso_unzip , file(`"`gsaved'"') dir(`"`unzipto'"') pwd(`"`unzipw'"')
            return local unzipdir `"`r(unzipdir)'"'
            return scalar unzipped = r(nfiles)
        }
        exit
    }

    if "`verb'"=="download" {
        syntax , ID(string) SAVING(string) [ replace UNZIP UNZIPW(string) UNZIPto(string) VERBOSE ]
        if "`replace'"=="" {
            capture confirm new file `"`saving'"'
            if _rc {
                di as err "suso: file already exists. Use -replace-."
                exit 602
            }
        }
        _suso_call , method(GET) path(/api/v2/export/`id'/file) savefile(`saving') accept(application/zip) `verbose'
        di as txt "suso: downloaded export to " as res `"`r(saved)'"' as txt " (`r(bytes)' bytes)."
        local zsaved `"`r(saved)'"'
        local zhttp = r(http)
        return add
        if "`unzip'"!="" | `"`unzipw'"'!="" {
            if `"`unzipw'"'=="" local unzipw `"$SUSO_EXPORTPWD"'
            _suso_unzip , file(`"`zsaved'"') dir(`"`unzipto'"') pwd(`"`unzipw'"')
            return local unzipdir `"`r(unzipdir)'"'
            return scalar unzipped = r(nfiles)
            return scalar http = `zhttp'
        }
        exit
    }

    if "`verb'"=="cancel" {
        syntax , ID(string) [ CONFIRM VERBOSE ]
        _suso_block , action("Cancel/delete export job `id' in workspace $SUSO_WS") `confirm'
        _suso_call , method(DELETE) path(/api/v2/export/`id') destructive allow `verbose'
        _suso_audit , action("export cancel") target("`id'") http("`r(http)'")
        di as txt "suso: export job `id' cancelled (HTTP `r(http)')."
        return add
        exit
    }

    di as err "suso export: unknown action '`verb''.  See {help suso}."
    exit 198
end

*===============================================================================
* Users / Supervisors / Interviewers
*===============================================================================
program _suso_user, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="get" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(GET) path(/api/v1/users/`id') `verbose'
        di as txt "User " as res `"`r(username)'"' as txt ":  role=" as res `"`r(role)'"' ///
            as txt "  locked=" as res `"`r(islocked)'"' as txt "  archived=" as res `"`r(isarchived)'"'
        return add
        exit
    }

    if "`verb'"=="create" {
        syntax , ROLE(string) Username(string) Password(string) [ FULLname(string) ///
            PHONE(string) EMAIL(string) SUPERVISOR(string) VERBOSE ]
        if !inlist(strproper("`role'"),"Supervisor","Interviewer","Headquarter","Observer","Apiuser") {
            di as err "suso: role() must be Supervisor, Interviewer, Headquarter, Observer, or ApiUser."
            exit 198
        }
        local role = cond(strlower("`role'")=="apiuser","ApiUser",strproper("`role'"))
        _suso_jsonesc `"`username'"'
        local un "`r(js)'"
        _suso_jsonesc `"`password'"'
        local pw "`r(js)'"
        local body `"{"Role":"`role'","UserName":"`un'","Password":"`pw'""'
        if "`fullname'"!="" {
            _suso_jsonesc `"`fullname'"'
            local body `"`body',"FullName":"`r(js)'""'
        }
        if "`phone'"!="" {
            _suso_jsonesc `"`phone'"'
            local body `"`body',"PhoneNumber":"`r(js)'""'
        }
        if "`email'"!="" {
            _suso_jsonesc `"`email'"'
            local body `"`body',"Email":"`r(js)'""'
        }
        if "`supervisor'"!="" {
            _suso_jsonesc `"`supervisor'"'
            local body `"`body',"Supervisor":"`r(js)'""'
        }
        local body `"`body'}"'
        global SUSO_BODY_REQ `"`body'"'
        _suso_call , method(POST) path(/api/v1/users) `verbose'
        di as txt "suso: user '`username'' created (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="archive" {
        syntax , ID(string) [ CONFIRM VERBOSE ]
        _suso_block , action("Archive user `id' AND ALL of their interviewers in workspace $SUSO_WS") `confirm'
        _suso_call , method(PATCH) path(/api/v1/users/`id'/archive) destructive allow `verbose'
        _suso_audit , action("user archive") target("`id'") http("`r(http)'")
        di as txt "suso: user `id' archived (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="unarchive" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(PATCH) path(/api/v1/users/`id'/unarchive) `verbose'
        di as txt "suso: user `id' unarchived (HTTP `r(http)')."
        return add
        exit
    }

    di as err "suso user: unknown action '`verb''.  See {help suso}."
    exit 198
end

program _suso_supervisor, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="list" {
        syntax [, ALL LIMIT(integer 0) OFFSET(integer -1) PAGESize(integer 0) VERBOSE ]
        local vopt = cond("`verbose'"!="","verbose","")
        _suso_getall , path(/api/v1/supervisors) mode(page) sizeparam(limit) pageparam(offset) ///
            maxsize(200) arraykey(Users) `all' limit(`limit') offset(`offset')                  ///
            pagesize(`pagesize') `vopt'
        di as txt "suso: fetched " as res "`=r(nobs)'" as txt " supervisor(s)."
        return add
        exit
    }
    if "`verb'"=="get" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(GET) path(/api/v1/supervisors/`id') `verbose'
        di as txt "Supervisor " as res `"`r(username)'"' as txt ":  archived=" as res `"`r(isarchived)'"'
        return add
        exit
    }
    if "`verb'"=="interviewers" {
        syntax , ID(string) [ ALL LIMIT(integer 0) OFFSET(integer -1) PAGESize(integer 0) VERBOSE ]
        local vopt = cond("`verbose'"!="","verbose","")
        _suso_getall , path(/api/v1/supervisors/`id'/interviewers) mode(page) sizeparam(limit) ///
            pageparam(offset) maxsize(200) arraykey(Users) `all' limit(`limit') offset(`offset') ///
            pagesize(`pagesize') `vopt'
        di as txt "suso: fetched " as res "`=r(nobs)'" as txt " interviewer(s) under supervisor `id'."
        return add
        exit
    }
    di as err "suso supervisor: unknown action '`verb''.  See {help suso}."
    exit 198
end

program _suso_interviewer, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="get" {
        syntax , ID(string) [ VERBOSE ]
        _suso_call , method(GET) path(/api/v1/interviewers/`id') `verbose'
        di as txt "Interviewer " as res `"`r(username)'"' as txt ":  supervisor=" as res `"`r(supervisorname)'"' ///
            as txt "  locked=" as res `"`r(islocked)'"' as txt "  archived=" as res `"`r(isarchived)'"'
        return add
        exit
    }
    if "`verb'"=="actionslog" {
        syntax , ID(string) [ START(string) END(string) VERBOSE ]
        local q ""
        if "`start'"!="" {
            _suso_enc `"`start'"'
            local q "`q'&start=`r(enc)'"
        }
        if "`end'"!=""   {
            _suso_enc `"`end'"'
            local q "`q'&end=`r(enc)'"
        }
        if substr("`q'",1,1)=="&" local q = substr("`q'",2,.)
        _suso_call , method(GET) path(/api/v1/interviewers/`id'/actions-log) query(`q') todata arraykey() `verbose'
        di as txt "suso: " as res "`=r(nobs)'" as txt " action-log record(s) for interviewer `id'."
        return add
        exit
    }
    di as err "suso interviewer: unknown action '`verb''.  See {help suso}."
    exit 198
end

*===============================================================================
* Workspaces  (server-level; default to server root, override with -usews-)
*===============================================================================
program _suso_workspace, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="list" {
        syntax [, INCLUDEDISabled USEWS VERBOSE ]
        local rootopt = cond("`usews'"=="","root","")
        local q "Start=0&Length=1000"
        if "`includedisabled'"!="" local q "`q'&IncludeDisabled=true"
        _suso_call , method(GET) path(/api/v1/workspaces) query(`q') todata arraykey() `rootopt' `verbose'
        di as txt "suso: fetched " as res "`=r(nobs)'" as txt " workspace(s)."
        return add
        exit
    }

    if "`verb'"=="get" {
        syntax , NAME(string) [ USEWS VERBOSE ]
        local rootopt = cond("`usews'"=="","root","")
        _suso_call , method(GET) path(/api/v1/workspaces/`name') `rootopt' `verbose'
        di as txt "Workspace " as res `"`r(name)'"' as txt " — " as res `"`r(displayname)'"'
        return add
        exit
    }

    if "`verb'"=="status" {
        syntax , NAME(string) [ USEWS VERBOSE ]
        local rootopt = cond("`usews'"=="","root","")
        _suso_call , method(GET) path(/api/v1/workspaces/status/`name') `rootopt' `verbose'
        di as txt _n "Workspace status: " as res `"`name'"'
        di as txt "  can be deleted    : " as res `"`r(canbedeleted)'"'
        di as txt "  questionnaires    : " as res `"`r(existingquestionnairescount)'"'
        di as txt "  supervisors       : " as res `"`r(supervisorscount)'"'
        di as txt "  interviewers      : " as res `"`r(interviewerscount)'"'
        di as txt "  maps              : " as res `"`r(mapscount)'"'
        return add
        exit
    }

    if "`verb'"=="create" {
        syntax , NAME(string) DISPLAYname(string) [ USEWS VERBOSE ]
        if !regexm("`name'","^[0-9a-z,]+$") | length("`name'")>12 {
            di as err "suso: workspace name must match ^[0-9,a-z]+$ and be <= 12 chars."
            exit 198
        }
        local rootopt = cond("`usews'"=="","root","")
        _suso_jsonesc `"`displayname'"'
        local dn "`r(js)'"
        global SUSO_BODY_REQ `"{"Name":"`name'","DisplayName":"`dn'"}"'
        _suso_call , method(POST) path(/api/v1/workspaces) `rootopt' `verbose'
        di as txt "suso: workspace '`name'' created (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="update" {
        syntax , NAME(string) DISPLAYname(string) [ USEWS VERBOSE ]
        local rootopt = cond("`usews'"=="","root","")
        _suso_jsonesc `"`displayname'"'
        local dn "`r(js)'"
        global SUSO_BODY_REQ `"{"DisplayName":"`dn'"}"'
        _suso_call , method(PATCH) path(/api/v1/workspaces/`name') `rootopt' `verbose'
        di as txt "suso: workspace '`name'' updated (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="enable" {
        syntax , NAME(string) [ USEWS VERBOSE ]
        local rootopt = cond("`usews'"=="","root","")
        _suso_call , method(POST) path(/api/v1/workspaces/`name'/enable) `rootopt' `verbose'
        di as txt "suso: workspace '`name'' enabled (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="disable" {
        syntax , NAME(string) [ CONFIRM USEWS VERBOSE ]
        _suso_block , action("Disable workspace '`name'' (users can no longer use it)") `confirm'
        local rootopt = cond("`usews'"=="","root","")
        _suso_call , method(POST) path(/api/v1/workspaces/`name'/disable) destructive allow `rootopt' `verbose'
        _suso_audit , action("workspace disable") target("`name'") http("`r(http)'")
        di as txt "suso: workspace '`name'' disabled (HTTP `r(http)')."
        return add
        exit
    }

    if "`verb'"=="delete" {
        syntax , NAME(string) [ Iknowthis(string) FORCE USEWS VERBOSE ]
        local rootopt = cond("`usews'"=="","root","")

        * 1) typed-name confirmation
        _suso_block_ws , name(`name') iknowthis(`iknowthis')

        * 2) status pre-check
        _suso_call , method(GET) path(/api/v1/workspaces/status/`name') `rootopt'
        local can = strlower(`"`r(canbedeleted)'"')
        di as txt _n "About to DELETE workspace '" as res "`name'" as txt "':"
        di as txt "    questionnaires=" as res `"`r(existingquestionnairescount)'"' as txt ///
                  "  supervisors=" as res `"`r(supervisorscount)'"' as txt ///
                  "  interviewers=" as res `"`r(interviewerscount)'"' as txt ///
                  "  maps=" as res `"`r(mapscount)'"' as txt "  canBeDeleted=" as res "`can'"
        if "`can'"!="true" & "`can'"!="1" & "`force'"=="" {
            di as err "suso: the server reports this workspace CANNOT be safely deleted (CanBeDeleted=`can')."
            di as err "      It still contains data/users. Disable it instead, or override with -force- if you are certain."
            exit 1
        }

        * 3) execute
        _suso_call , method(DELETE) path(/api/v1/workspaces/`name') destructive allow `rootopt' `verbose'
        _suso_audit , action("workspace DELETE") target("`name'") http("`r(http)'")
        di as txt "suso: workspace '`name'' deleted (HTTP " as res "`r(http)'" as txt ").  Success=" as res `"`r(success)'"'
        return add
        exit
    }

    if "`verb'"=="assign" {
        syntax , USERIDS(string) WORKSpaces(string) [ MODE(string) SUPERVISOR(string) USEWS VERBOSE ]
        local rootopt = cond("`usews'"=="","root","")
        if "`mode'"=="" local mode Assign
        if !inlist(strproper("`mode'"),"Assign","Add","Remove") {
            di as err "suso: mode() must be Assign, Add or Remove."
            exit 198
        }
        * UserIds array
        local uids ""
        foreach u of local userids {
            local uids `"`uids',"`u'""'
        }
        local uids = substr(`"`uids'"',2,.)
        * Workspaces array
        local wss ""
        foreach w of local workspaces {
            if "`supervisor'"!="" local wss `"`wss',{"Workspace":"`w'","SupervisorId":"`supervisor'"}"'
            else                  local wss `"`wss',{"Workspace":"`w'"}"'
        }
        local wss = substr(`"`wss'"',2,.)
        global SUSO_BODY_REQ `"{"UserIds":[`uids'],"Workspaces":[`wss'],"Mode":"`=strproper("`mode'")'"}"'
        _suso_call , method(POST) path(/api/v1/workspaces/assign) `rootopt' `verbose'
        di as txt "suso: workspace assignment updated (HTTP `r(http)')."
        return add
        exit
    }

    di as err "suso workspace: unknown action '`verb''.  See {help suso}."
    exit 198
end

*===============================================================================
* Settings
*===============================================================================
program _suso_settings, rclass
    version 14.2
    gettoken what 0 : 0
    local what = strlower("`what'")
    if "`what'"!="globalnotice" {
        di as err "suso settings: only 'globalnotice' is supported.  See {help suso}."
        exit 198
    }
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="get" {
        syntax [, VERBOSE]
        _suso_call , method(GET) path(/api/v1/settings/globalnotice) `verbose'
        di as txt "Global notice: " as res `"`r(message)'"'
        return add
        exit
    }
    if "`verb'"=="set" {
        syntax , MESSAGE(string) [ VERBOSE ]
        _suso_jsonesc `"`message'"'
        local m "`r(js)'"
        global SUSO_BODY_REQ `"{"Message":"`m'"}"'
        _suso_call , method(PUT) path(/api/v1/settings/globalnotice) `verbose'
        di as txt "suso: global notice set (HTTP `r(http)')."
        return add
        exit
    }
    if "`verb'"=="clear" {
        syntax [, VERBOSE]
        _suso_call , method(DELETE) path(/api/v1/settings/globalnotice) `verbose'
        di as txt "suso: global notice cleared (HTTP `r(http)')."
        return add
        exit
    }
    di as err "suso settings globalnotice: action must be get, set or clear."
    exit 198
end

*===============================================================================
* Statistics
*===============================================================================
program _suso_statistics, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")

    if "`verb'"=="questionnaires" {
        syntax [, VERBOSE]
        _suso_call , method(GET) path(/api/v1/statistics/questionnaires) todata arraykey() `verbose'
        di as txt "suso: " as res "`=r(nobs)'" as txt " questionnaire(s) with data."
        return add
        exit
    }

    if "`verb'"=="questions" {
        syntax [, GUID(string) QVER(integer 0) VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        _suso_needq "`guid'"
        local q "questionnaireId=`guid'"
        if `qver'>0 local q "`q'&version=`qver'"
        _suso_call , method(GET) path(/api/v1/statistics/questions) query(`q') todata arraykey() `verbose'
        di as txt "suso: " as res "`=r(nobs)'" as txt " question(s) with data."
        return add
        exit
    }

    if "`verb'"=="report" {
        syntax , QUESTION(string) [ GUID(string) QVER(integer 0) EXPORTtype(string) ///
            SAVING(string) replace Query(string) VERBOSE ]
        _suso_gq "`guid'" "`qver'"
        _suso_needq "`guid'"
        local q "QuestionnaireId=`guid'&Question=`question'"
        if `qver'>0          local q "`q'&Version=`qver'"
        if "`exporttype'"!="" local q "`q'&exportType=`exporttype'"
        if `"`query'"'!=""   local q `"`q'&`query'"'
        if "`saving'"!="" {
            if "`replace'"=="" {
                capture confirm new file `"`saving'"'
                if _rc {
                    di as err "suso: file already exists. Use -replace-."
                    exit 602
                }
            }
            _suso_call , method(GET) path(/api/v1/statistics) query(`q') savefile(`saving') `verbose'
            di as txt "suso: saved statistics report to " as res `"`r(saved)'"' as txt " (`r(bytes)' bytes)."
        }
        else {
            _suso_call , method(GET) path(/api/v1/statistics) query(`q') todata arraykey() `verbose'
            di as txt "suso: loaded statistics report (" as res "`=r(nobs)'" as txt " rows)."
        }
        return add
        exit
    }

    di as err "suso statistics: action must be report, questions or questionnaires."
    exit 198
end

*===============================================================================
* Paradata — download / load the SuSo paradata export and analyse timing and
* interviewer behaviour (speeding, night work, answer churn, duration outliers).
*
*   suso paradata get      start->poll->download type(Paradata), unzip, load
*   suso paradata load     load a local paradata .zip / .tab (offline)
*   suso paradata timing   event data -> per-interview / question / interviewer
*   suso paradata flags    per-interview red flags + interviewer league table
*   suso paradata skips    gate flips: skip-triggered answer-removal cascades
*   suso paradata report   one-page self-contained HTML QC report with figures
*   suso paradata qx       parse the exported questionnaire HTML (text, skips, validations)
*   suso paradata check    evaluate the skip logic + option values against exported data
*
* Design notes (kept deliberately vectorised: one import, 2 sorts, 1 collapse):
*   - Works with both paradata layouts: v21.01+ (event, timestamp_utc, tz_offset)
*     and legacy (action, timestamp [device-local], offset).
*   - Durations use UTC when available; device-local time is used only for the
*     night-work metric. Negative gaps (device clock skew) are floored at 0.
*   - "Active" time caps every inter-event gap at gapmins() (default 30) and
*     zeroes Paused->next-event gaps, the standard SuSo paradata convention.
*   - Timing metrics use Interviewer-role events when the role column identifies
*     them (approve/reject traffic is excluded); event COUNTS (rejections etc.)
*     always use all rows. Override with -allroles-.
*===============================================================================
program _suso_paradata, rclass
    version 14.2
    gettoken verb 0 : 0, parse(" ,")
    local verb = strlower("`verb'")
    if inlist("`verb'","fetch","download")                    local verb get
    if inlist("`verb'","import","read")                       local verb load
    if inlist("`verb'","time","timings","durations")          local verb timing
    if inlist("`verb'","flag","check","quality","anomalies")  local verb flags
    if inlist("`verb'","skip","skipcheck","gates","cascades") local verb skips
    if inlist("`verb'","html","dashboard","qc")               local verb report
    if inlist("`verb'","questionnaire","instrument")           local verb qx
    if inlist("`verb'","skiplogic","datacheck","codebook")      local verb check

    if "`verb'"=="get" {
        _suso_para_get `macval(0)'
        return add
        exit
    }
    if "`verb'"=="load" {
        _suso_para_load `macval(0)'
        return add
        exit
    }
    if "`verb'"=="timing" {
        _suso_para_timing `macval(0)'
        return add
        exit
    }
    if "`verb'"=="flags" {
        _suso_para_flags `macval(0)'
        return add
        exit
    }
    if "`verb'"=="skips" {
        _suso_para_skips `macval(0)'
        return add
        exit
    }
    if "`verb'"=="report" {
        _suso_para_report `macval(0)'
        return add
        exit
    }
    if "`verb'"=="qx" {
        _suso_para_qxload `macval(0)'
        return add
        exit
    }
    if "`verb'"=="check" {
        _suso_para_check `macval(0)'
        return add
        exit
    }
    di as err "suso paradata: action must be get, load, timing, flags, skips, report, qx or check.  See {help suso##paradata:help suso}."
    exit 198
end

* ---- get: export type(Paradata) from the server, unzip, load ------------------
program _suso_para_get, rclass
    version 14.2
    syntax [, SAVing(string) DIR(string) GUID(string) QVER(integer 0)          ///
        ISTATUS(string) FROM(string) TO(string) REDUCED PWD(string)            ///
        UNZIPW(string) POLLSecs(integer 10) JOBTimeout(integer 3600)           ///
        replace VERBOSE ]
    if `"`unzipw'"'!="" local pwd `"`unzipw'"'    // unzipw() = house synonym for pwd()
    if `"`pwd'"'==""    local pwd `"$SUSO_EXPORTPWD"'   // default from suso config , exportpw()

    if `"`saving'"'=="" {
        local stamp : di %tcCCYYNNDD-HHMMSS ///
            clock("`c(current_date)' `c(current_time)'", "DMYhms")
        local stamp = trim("`stamp'")
        local saving "suso_paradata_`stamp'.zip"
    }
    else if "`replace'"=="" {
        capture confirm new file `"`saving'"'
        if _rc {
            di as err "suso: file already exists. Use -replace-."
            exit 602
        }
    }
    local redopt = cond("`reduced'"!="","reduced","")

    di as txt "suso paradata: requesting a Paradata export (this can take a while on large surveys) ..."
    _suso_export_get , type(Paradata) saving(`"`saving'"') guid(`guid')        ///
        qver(`qver') istatus(`istatus') from(`from') to(`to') `redopt'         ///
        pollsecs(`pollsecs') jobtimeout(`jobtimeout') replace `verbose'
    if "`r(status)'"=="NoFile" {
        di as txt "suso paradata: the server reports no paradata for this questionnaire/filter — nothing to load."
        return local status "NoFile"
        exit
    }
    local zip `"`r(saved)'"'
    return local saved `"`zip'"'

    capture noisily _suso_unzip , file(`"`zip'"') dir(`"`dir'"') pwd(`"`pwd'"')
    if _rc {
        local rc = _rc
        di as err _n "suso paradata: could not extract the downloaded archive."
        if `"`pwd'"'=="" {
            di as err "  Your server may password-protect exports (Export Encryption). The"
            di as err "  download itself succeeded and is kept — no need to re-export. Retry:"
        }
        else {
            di as err "  A password was supplied but extraction still failed — wrong password,"
            di as err "  or a corrupt download. The archive is kept; retry without re-exporting:"
        }
        di as err `"      suso paradata load , file("`zip'") unzipw("<export password>")"'
        di as err `"  or set it once per session:   suso config , exportpw("<export password>")"'
        exit `rc'
    }
    local xdir `"`r(unzipdir)'"'
    return local unzipdir `"`xdir'"'

    _suso_para_load , dir(`"`xdir'"')
    return add
    di as txt "suso paradata: archive kept at " as res `"`zip'"'
    di as txt "               reload offline anytime:  {bf:suso paradata load , file(...)}"
end

* ---- load: local .tab / .zip / extracted folder --------------------------------
program _suso_para_load, rclass
    version 14.2
    syntax [, FILE(string) DIR(string) PWD(string) UNZIPW(string) ]
    if `"`unzipw'"'!="" local pwd `"`unzipw'"'    // unzipw() = house synonym for pwd()
    if `"`pwd'"'==""    local pwd `"$SUSO_EXPORTPWD"'   // default from suso config , exportpw()

    if `"`file'"'=="" & `"`dir'"'=="" {
        di as err "suso paradata load: specify the downloaded export,  file(<paradata .zip or .tab>)."
        exit 198
    }

    * a .zip is extracted first (Java backend: handles SuSo's ZipCrypto passwords)
    if `"`file'"'!="" {
        capture confirm file `"`file'"'
        if _rc {
            di as err `"suso paradata: file not found:  `file'"'
            exit 601
        }
        local k = strrpos(`"`file'"', ".")
        local ext = cond(`k'>0, lower(substr(`"`file'"', `k', .)), "")
        if "`ext'"==".zip" {
            capture noisily _suso_unzip , file(`"`file'"') pwd(`"`pwd'"')
            if _rc {
                local rc = _rc
                di as err _n "suso paradata: could not extract the archive."
                if `"`pwd'"'=="" di as err `"  If your server password-protects exports, add unzipw() or set:  suso config , exportpw("...")"'
                else            di as err "  A password was supplied but extraction failed — check the password."
                exit `rc'
            }
            local dir `"`r(unzipdir)'"'
            local file ""
        }
        else if !inlist("`ext'",".tab",".txt",".tsv") {
            di as err "suso paradata: expected a .zip (SuSo export) or the tab-delimited paradata file."
            exit 198
        }
    }

    * locate the paradata tab file inside an extracted folder
    if `"`file'"'=="" {
        local dnorm = subinstr(`"`dir'"', "\", "/", .)
        if substr(`"`dnorm'"',-1,1)=="/" local dnorm = substr(`"`dnorm'"',1,length(`"`dnorm'"')-1)
        local cands : dir `"`dnorm'"' files "*.tab"
        local pick ""
        foreach f of local cands {
            if lower(`"`f'"')=="paradata.tab" local pick `"`f'"'
        }
        if `"`pick'"'=="" {
            foreach f of local cands {
                if `"`pick'"'=="" local pick `"`f'"'
            }
        }
        if `"`pick'"'=="" {
            di as err `"suso paradata: no .tab file found in  `dnorm'"'
            di as err "               (a Paradata export contains paradata.tab — is this the right archive?)"
            exit 601
        }
        local file `"`dnorm'/`pick'"'
    }

    di as txt "suso paradata: importing " as res `"`file'"' as txt " ..."
    import delimited using `"`file'"', delimiter(tab) varnames(1)              ///
        stringcols(_all) bindquote(nobind) encoding(utf-8) clear

    _suso_para_prep

    * summary (one sort; leaves the data ordered iid/event-order)
    tempvar f1
    quietly bysort interview__id (para_ord para_seq): gen byte `f1' = (_n==1)
    quietly count if `f1'
    local nint = r(N)
    quietly summarize para_tsu
    if r(N)>0 {
        local d0 : di %tcCCYY-NN-DD r(min)
        local d1 : di %tcCCYY-NN-DD r(max)
        local period `", `d0' to `d1'"'
    }
    else local period ""

    di as txt "suso paradata: loaded " as res "`=_N'" as txt " event(s) from " ///
        as res "`nint'" as txt " interview(s)`period'."
    di as txt _n "  what next:"
    di as txt "    {bf:suso paradata report}   one-page QC report with figures (recommended first look)"
    di as txt "    {bf:suso paradata flags}    behaviour red flags per interview + interviewer league"
    di as txt "    {bf:suso paradata timing}   durations & answer speed (by interview / question / interviewer)"
    di as txt "    {bf:suso paradata skips}    gate flips that wiped answers (skip abuse / bad filters)"
    di as txt "  tip: timing/flags/skips replace the loaded events — {bf:save events.dta} first if you plan"
    di as txt "       to iterate on thresholds; {bf:report} takes care of this by itself."
    return scalar nevents = _N
    return scalar nints   = `nint'
    return local  tabfile `"`file'"'
end

* ---- prep: harmonise columns across SuSo versions, parse times, mark events ----
program _suso_para_prep
    version 14.2
    if `"`: char _dta[suso_paradata]'"'=="events" exit    // already prepared

    capture confirm variable interview__id
    if _rc {
        di as err "suso paradata: no interview__id column — this does not look like a Survey Solutions paradata file."
        exit 459
    }
    * legacy column names
    capture confirm variable event
    if _rc {
        capture confirm variable action
        if !_rc rename action event
    }
    capture confirm string variable event
    if _rc {
        di as err "suso paradata: no (string) event/action column found."
        exit 459
    }

    * numeric within-interview sequence (order), with file order as tiebreaker
    quietly gen double para_seq = _n
    capture confirm variable order
    if !_rc {
        capture confirm string variable order
        if !_rc quietly gen double para_ord = real(order)
        else    quietly gen double para_ord = order
    }
    else quietly gen double para_ord = _n
    label variable para_seq "paradata: file row (tiebreak)"
    label variable para_ord "paradata: event order within interview"

    * timestamps: v21.01+ = timestamp_utc (+ tz_offset); legacy = timestamp local (+ offset)
    local tsvar ""
    capture confirm variable timestamp_utc
    if !_rc local tsvar timestamp_utc
    else {
        capture confirm variable timestamp
        if !_rc local tsvar timestamp
    }
    if "`tsvar'"=="" {
        di as err "suso paradata: no timestamp_utc/timestamp column — cannot compute timings."
        exit 459
    }
    capture confirm string variable `tsvar'
    if !_rc {
        quietly gen double para_ts = clock(subinstr(substr(`tsvar',1,19),"T"," ",1), "YMDhms")
        quietly count if missing(para_ts) & `tsvar'!=""
        if r(N)>0 di as txt "suso paradata: note — " as res "`=r(N)'" as txt " event(s) had unparseable timestamps (left missing)."
    }
    else quietly gen double para_ts = `tsvar'      // already numeric (%tc)

    * timezone offset -> milliseconds (formats like +05:30:00 / -04:00:00 / 05:30:00)
    local tzvar ""
    capture confirm string variable tz_offset
    if !_rc local tzvar tz_offset
    else {
        capture confirm string variable offset
        if !_rc local tzvar offset
    }
    if "`tzvar'"!="" {
        tempvar sgn body kp
        quietly gen byte `sgn'  = 1 - 2*(substr(`tzvar',1,1)=="-")
        quietly gen `body' = cond(inlist(substr(`tzvar',1,1),"+","-"), substr(`tzvar',2,.), `tzvar')
        quietly gen long `kp'   = strpos(`body', ":")
        quietly gen double para_off = `sgn' * (3600000*real(substr(`body',1,`kp'-1)) ///
                                     +   60000*real(substr(`body',`kp'+1,2))) if `kp'>0
        quietly replace para_off = 0 if missing(para_off)
    }
    else quietly gen double para_off = 0

    * UTC clock for durations, device-local clock for time-of-day
    if "`tsvar'"=="timestamp_utc" {
        quietly gen double para_tsu = para_ts
        quietly gen double para_tsl = para_ts + para_off
    }
    else {   // legacy: timestamp is device-local
        quietly gen double para_tsl = para_ts
        quietly gen double para_tsu = para_ts - para_off
    }
    format para_tsu para_tsl %tcCCYY-NN-DD_HH:MM:SS
    label variable para_tsu "paradata: event time (UTC)"
    label variable para_tsl "paradata: event time (device local)"
    quietly drop para_ts

    * normalised event name + indicators (names vary slightly across versions)
    quietly gen para_ev = lower(strtrim(event))
    quietly gen byte para_ans = (para_ev=="answerset")
    quietly gen byte para_rem = (para_ev=="answerremoved")
    quietly gen byte para_inv = (strpos(para_ev,"declaredinvalid")>0)
    quietly gen byte para_cmp = (para_ev=="completed")
    quietly gen byte para_rst = (para_ev=="restarted")
    quietly gen byte para_rej = (strpos(para_ev,"rejectedby")==1)
    quietly gen byte para_pau = (para_ev=="paused")
    label variable para_ev  "paradata: event (lowercase)"
    label variable para_ans "AnswerSet"
    label variable para_rem "AnswerRemoved"
    label variable para_inv "declared invalid"
    label variable para_cmp "Completed"
    label variable para_rst "Restarted"
    label variable para_rej "Rejected (SV/HQ)"
    label variable para_pau "Paused"

    * question variable name = first ||-token of parameters (answers/comments only)
    capture confirm string variable parameters
    if !_rc {
        tempvar pp
        quietly gen long `pp' = strpos(parameters, "||")
        quietly gen para_var = cond(`pp'>0, substr(parameters,1,`pp'-1), parameters) ///
            if para_ans | para_rem | para_ev=="commentset"
        * SuSo quotes the parameters field when answers contain special characters;
        * with bindquote(nobind) the opening quote sticks to the variable name
        quietly replace para_var = substr(para_var,2,.) if substr(para_var,1,1)==char(34)
        label variable para_var "paradata: question variable"
    }

    char _dta[suso_paradata] events
end

* ---- guard: the current dataset must be prepared paradata of the given kind ----
program _suso_para_need
    version 14.2
    args kind
    if `"`: char _dta[suso_paradata]'"'!="`kind'" {
        if "`kind'"=="events" {
            di as err "suso paradata: no paradata events in memory."
            di as err "      Load them first:   suso paradata get   |   suso paradata load , file(...)"
        }
        else {
            di as err "suso paradata: no paradata `kind' table in memory."
        }
        exit 459
    }
end

* ---- derive: shared event-level derivations (roles, gaps, sessions) ------------
program _suso_para_derive, rclass
    version 14.2
    syntax [, GAPMins(real 30) FASTsecs(real 2) ALLRoles ]
    if `gapmins'<=0 | `fastsecs'<=0 {
        di as err "suso paradata: gapmins() and fastsecs() must be positive."
        exit 198
    }
    local gapsecs = `gapmins'*60
    capture drop para_role
    * derived columns from a previous (possibly interrupted) run
    capture drop para_ivw para_resp para_gap para_prevp para_brk para_act        ///
        para_ansgap para_fast para_night para_tivw para_one

    * Interviewer-role detection. SuSo writes role either as text ("Interviewer")
    * or as a numeric code that varies by version. If no text match, infer the
    * interviewer code empirically: interviews are Completed on the tablet, so
    * the modal role on Completed events identifies the interviewer role.
    local rolenote "all roles (no role column)"
    quietly gen byte para_ivw = 1
    capture confirm variable role
    if !_rc & "`allroles'"=="" {
        capture confirm string variable role
        if !_rc quietly gen para_role = lower(strtrim(role))
        else    quietly gen para_role = strofreal(role)
        quietly count if para_role=="interviewer"
        if r(N)>0 {
            quietly replace para_ivw = (para_role=="interviewer")
            local rolenote "Interviewer-role events"
        }
        else {
            local rcode ""
            quietly count if para_cmp
            if r(N)>0 {
                preserve
                quietly keep if para_cmp & para_role!=""
                if _N>0 {
                    quietly contract para_role
                    gsort -_freq para_role
                    local rcode = para_role[1]
                }
                restore
            }
            quietly count if para_role!="" & para_role!="`rcode'"
            if "`rcode'"!="" & r(N)>0 {
                quietly replace para_ivw = (para_role=="`rcode'")
                local rolenote `"interviewer role inferred as code `rcode' (modal role on Completed events)"'
            }
            else if "`rcode'"!="" local rolenote "all roles (role column has a single value)"
            else local rolenote "all roles (no Completed events to infer the interviewer role)"
        }
    }
    if "`allroles'"!="" local rolenote "all roles (allroles)"

    * responsible: at the last answer event, else at the last event
    quietly gen para_resp = ""
    capture confirm string variable responsible
    if !_rc {
        tempvar isa
        quietly gen byte `isa' = para_ans & para_ivw
        quietly bysort interview__id (`isa' para_ord para_seq): replace para_resp = responsible[_N]
    }

    * gaps within the interviewer-role event stream of each interview
    quietly bysort interview__id para_ivw (para_ord para_seq): ///
        gen double para_gap = (para_tsu - para_tsu[_n-1])/1000 if para_ivw & _n>1
    quietly replace para_gap = 0 if para_gap<0                       // clock skew
    quietly bysort interview__id para_ivw (para_ord para_seq): ///
        gen byte para_prevp = (para_pau[_n-1]==1) if para_ivw & _n>1
    quietly replace para_prevp = 0 if missing(para_prevp)

    quietly gen byte   para_brk = para_ivw & !missing(para_gap) & (para_prevp | para_gap>`gapsecs')
    quietly gen double para_act = cond(para_ivw & !missing(para_gap), ///
                                       cond(para_prevp, 0, min(para_gap,`gapsecs')), 0)
    quietly gen double para_ansgap = para_gap if para_ans & para_ivw & !para_brk & !missing(para_gap)
    quietly gen byte   para_fast   = (para_ansgap<`fastsecs') if !missing(para_ansgap)
    quietly gen byte   para_night  = para_ans & para_ivw & !missing(para_tsl) & ///
                                     (hh(para_tsl)>=22 | hh(para_tsl)<6)
    quietly gen double para_tivw   = para_tsu if para_ivw
    quietly gen byte   para_one    = 1
    return local rolenote `"`rolenote'"'
end

* ---- timing: events in memory  ->  one row per interview / question / interviewer
program _suso_para_timing, rclass
    version 14.2
    syntax [, BY(string) GAPMins(real 30) FASTsecs(real 2) ALLRoles ]
    _suso_para_need events

    if "`by'"=="" local by interview
    if !inlist("`by'","interview","question","interviewer") {
        di as err "suso paradata timing: by() must be interview, question or interviewer."
        exit 198
    }
    if `gapmins'<=0 | `fastsecs'<=0 {
        di as err "suso paradata timing: gapmins() and fastsecs() must be positive."
        exit 198
    }
    _suso_para_derive , gapmins(`gapmins') fastsecs(`fastsecs') `allroles'
    local rolenote `"`r(rolenote)'"'


    * ---------------- by(question): median seconds per question -----------------
    if "`by'"=="question" {
        capture confirm variable para_var
        if _rc {
            di as err "suso paradata timing: no parameters column in this paradata (reduced export?) — cannot time questions."
            exit 459
        }
        quietly keep if para_ans & para_ivw & para_var!=""
        if _N==0 {
            di as err "suso paradata timing: no AnswerSet events to time."
            exit 2000
        }
        tempvar tag
        quietly bysort para_var interview__id: gen byte `tag' = (_n==1)
        collapse (sum) n_set=para_one n_interviews=`tag' n_fast=para_fast          ///
            (count) n_timed=para_ansgap                                            ///
            (p50) med_s=para_ansgap (p90) p90_s=para_ansgap, by(para_var) fast
        rename para_var variable
        quietly gen double fast_share = n_fast/n_timed if n_timed>0
        label variable variable     "question variable"
        label variable n_set        "answers set"
        label variable n_interviews "interviews answering"
        label variable n_timed      "answers with a timed gap"
        label variable med_s        "median sec to answer"
        label variable p90_s        "p90 sec to answer"
        label variable fast_share   "share answered < `fastsecs' sec"
        format med_s p90_s %9.1f
        format fast_share %5.2f
        gsort -med_s
        char _dta[suso_paradata] qtiming
        di as txt "suso paradata: question timing for " as res "`=_N'" as txt ///
            " variable(s) (`rolenote'); sorted slowest first."
        return scalar nvars = _N
        exit
    }

    * ---------------- by(interviewer): pooled per-interviewer -------------------
    if "`by'"=="interviewer" {
        quietly keep if para_ivw
        if _N==0 {
            di as err "suso paradata timing: no interviewer-role events found."
            exit 2000
        }
        capture confirm variable responsible
        if _rc {
            di as err "suso paradata timing: no responsible column — cannot group by interviewer."
            exit 459
        }
        tempvar tag
        quietly bysort responsible interview__id: gen byte `tag' = (_n==1)
        collapse (sum) n_interviews=`tag' n_events=para_one n_answers=para_ans       ///
            n_removed=para_rem active_s=para_act n_fast=para_fast n_night=para_night ///
            (count) n_timed=para_ansgap (p50) ans_med_s=para_ansgap                  ///
            (p90) ans_p90_s=para_ansgap, by(responsible) fast
        quietly gen double active_hr   = active_s/3600
        quietly gen double fast_share  = n_fast/n_timed    if n_timed>0
        quietly gen double night_share = n_night/n_answers if n_answers>0
        quietly gen double churn       = n_removed/max(n_answers,1)
        quietly drop active_s
        label variable n_interviews "interviews worked"
        label variable active_hr    "active hours (gap-capped)"
        label variable ans_med_s    "median sec to answer"
        label variable ans_p90_s    "p90 sec to answer"
        label variable fast_share   "share answers < `fastsecs' sec"
        label variable night_share  "share answers 22:00-05:59"
        label variable churn        "AnswerRemoved / AnswerSet"
        format active_hr ans_med_s ans_p90_s %9.1f
        format fast_share night_share churn %5.2f
        sort ans_med_s
        char _dta[suso_paradata] ivtiming
        di as txt "suso paradata: interviewer timing for " as res "`=_N'" as txt ///
            " interviewer(s) (`rolenote'); sorted fastest first."
        return scalar nivw = _N
        exit
    }

    * ---------------- by(interview): the canonical QC table ---------------------
    collapse (sum) n_events=para_one n_answers=para_ans n_removed=para_rem          ///
        n_invalid=para_inv n_completed=para_cmp n_restarted=para_rst                ///
        n_rejected=para_rej n_breaks=para_brk active_s=para_act                     ///
        n_fast=para_fast n_night=para_night                                         ///
        (count) n_timed=para_ansgap                                                 ///
        (p50) ans_med_s=para_ansgap (p90) ans_p90_s=para_ansgap                     ///
        (min) t_first=para_tsu ti0=para_tivw (max) t_last=para_tsu ti1=para_tivw    ///
        (first) responsible=para_resp, by(interview__id) fast

    quietly gen double active_min  = active_s/60
    quietly gen double span_min    = cond(!missing(ti0), (ti1-ti0)/60000, (t_last-t_first)/60000)
    quietly gen double sessions    = n_breaks + 1
    quietly gen double fast_share  = n_fast/n_timed    if n_timed>0
    quietly gen double night_share = n_night/n_answers if n_answers>0
    quietly gen double churn       = n_removed/max(n_answers,1)
    quietly gen double pace_apm    = n_answers/active_min if active_min>0
    quietly gen byte   started     = (n_timed>0 | n_completed>0 | active_min>0)
    quietly drop active_s ti0 ti1 n_breaks n_fast n_night

    format t_first t_last %tcCCYY-NN-DD_HH:MM:SS
    format active_min span_min ans_med_s ans_p90_s pace_apm %9.1f
    format fast_share night_share churn %5.2f
    label variable interview__id "interview id"
    label variable responsible   "interviewer (at last answer)"
    label variable n_events      "paradata events"
    label variable n_answers     "AnswerSet events"
    label variable n_removed     "AnswerRemoved events"
    label variable n_invalid     "validation-error events"
    label variable n_completed   "Completed events"
    label variable n_restarted   "Restarted events"
    label variable n_rejected    "rejections (SV+HQ)"
    label variable n_timed       "answers with a timed gap"
    label variable sessions      "work sessions"
    label variable span_min      "first-to-last event, min"
    label variable active_min    "active time, min (gap-capped)"
    label variable ans_med_s     "median sec to answer"
    label variable ans_p90_s     "p90 sec to answer"
    label variable fast_share    "share answers < `fastsecs' sec"
    label variable night_share   "share answers 22:00-05:59"
    label variable churn         "AnswerRemoved / AnswerSet"
    label variable pace_apm      "answers per active minute"
    label variable started       "fieldwork started (any interviewer activity)"
    order interview__id responsible started n_events n_answers n_removed n_invalid          ///
        n_completed n_restarted n_rejected sessions span_min active_min             ///
        ans_med_s ans_p90_s fast_share night_share churn pace_apm t_first t_last
    sort interview__id

    char _dta[suso_paradata]      timing
    char _dta[suso_para_gapmins]  `gapmins'
    char _dta[suso_para_fastsecs] `fastsecs'

    quietly summarize active_min, detail
    local medact : di %9.1f r(p50)
    local tothr  : di %9.1f r(sum)/60
    quietly summarize ans_med_s, detail
    local medans : di %9.1f r(p50)
    di as txt "suso paradata: timing built for " as res "`=_N'" as txt " interview(s)  (`rolenote')."
    di as txt "  median active time " as res trim("`medact'") as txt " min   |   median sec/answer " ///
        as res trim("`medans'") as txt "   |   total interviewer time " as res trim("`tothr'") as txt " hr"
    di as txt "  gaps capped at " as res "`gapmins'" as txt " min; fast answer = < " ///
        as res "`fastsecs'" as txt " sec.   Next:  {bf:suso paradata flags}"
    di as txt "  how to read: {bf:active_min} = hands-on time; a median {bf:ans_med_s} under ~2s or"
    di as txt "  {bf:fast_share} above ~0.3 in a completed interview suggests speeding — see {bf:flags}."
    return scalar nints     = _N
    return scalar medactive = real("`medact'")
    return scalar medans    = real("`medans'")
end

* ---- flags: per-interview red flags + interviewer league table -----------------
program _suso_para_flags, rclass
    version 14.2
    syntax [, GAPMins(real 30) FASTsecs(real 2) ALLRoles MINactive(real 10)     ///
        BURSTshare(real 0.33) NIGHTshare(real 0.25) CHURN(real 0.20)            ///
        Zcut(real 3.5) TOP(integer 15) SAVing(string) replace ]

    local kind : char _dta[suso_paradata]
    if "`kind'"=="events" {
        quietly _suso_para_timing , by(interview) gapmins(`gapmins') fastsecs(`fastsecs') `allroles'
    }
    else if "`kind'"!="timing" {
        _suso_para_need events    // prints the friendly "load first" error
    }
    local gapused  : char _dta[suso_para_gapmins]
    if "`gapused'"=="" local gapused `gapmins'

    capture drop f_speed f_burst f_short f_night f_churn f_outlier n_flags z_active

    * absolute-threshold flags (missing-safe: a missing metric never flags)
    quietly gen byte f_speed = !missing(ans_med_s)  & ans_med_s  < `fastsecs'
    quietly gen byte f_burst = !missing(fast_share) & fast_share > `burstshare'
    quietly gen byte f_short = n_completed>0 & active_min < `minactive'
    quietly gen byte f_night = !missing(night_share) & night_share > `nightshare' & n_timed>=10
    quietly gen byte f_churn = !missing(churn) & churn > `churn' & n_timed>=10

    * robust two-sided outlier on log active time (modified z, Iglewicz-Hoaglin)
    quietly gen byte f_outlier = 0
    quietly gen double z_active = .
    tempvar lx dev
    quietly gen double `lx' = ln(active_min) if active_min>0
    quietly summarize `lx', detail
    if r(N)>=10 {
        local medlx = r(p50)
        quietly gen double `dev' = abs(`lx'-`medlx')
        quietly summarize `dev', detail
        if r(p50)>0 {
            quietly replace z_active  = 0.6745*(`lx'-`medlx')/r(p50)
            quietly replace f_outlier = abs(z_active)>`zcut' & !missing(z_active)
        }
    }
    label variable z_active "robust z of ln(active_min)"

    quietly gen byte n_flags = f_speed+f_burst+f_short+f_night+f_churn+f_outlier
    label variable f_speed   "median sec/answer < `fastsecs'"
    label variable f_burst   "fast-answer share > `burstshare'"
    label variable f_short   "completed with active < `minactive' min"
    label variable f_night   "night share > `nightshare'"
    label variable f_churn   "answer churn > `churn'"
    label variable f_outlier "robust |z| active time > `zcut'"
    label variable n_flags   "number of flags raised"
    char _dta[suso_paradata] timing

    * ---- summary ----
    local nints = _N
    quietly count if n_flags>0
    local nflag = r(N)
    local pflag : di %4.1f 100*`nflag'/max(`nints',1)
    foreach f in speed burst short night churn outlier {
        quietly count if f_`f'
        local c_`f' = r(N)
    }
    di as txt _n "{hline 72}"
    di as res "  suso paradata flags" as txt "   (`nints' interviews; gaps capped at `gapused' min)"
    di as txt "{hline 72}"
    di as txt "  flagged interviews : " as res "`nflag'" as txt "  (" as res trim("`pflag'") as txt "%)"
    di as txt "    S  sustained speeding   median sec/answer < `fastsecs'        : " as res "`c_speed'"
    di as txt "    B  answer bursts        fast-answer share > `burstshare'      : " as res "`c_burst'"
    di as txt "    T  too short            completed, active < `minactive' min       : " as res "`c_short'"
    di as txt "    N  night work           night share > `nightshare' (10+ timed ans): " as res "`c_night'"
    di as txt "    C  answer churn         removed/set > `churn' (10+ timed ans)     : " as res "`c_churn'"
    di as txt "    Z  duration outlier     robust |z| > `zcut'                   : " as res "`c_outlier'"

    * ---- top flagged interviews ----
    if `nflag'>0 {
        gsort -n_flags ans_med_s interview__id
        local k = min(`top', `nflag')
        di as txt _n "  top `k' flagged interview(s):"
        di as txt "  {ul:interview}  {ul:interviewer }  {ul:flags }  {ul: act.min}  {ul:sec/ans}  {ul:fast}  {ul:night}"
        forvalues i = 1/`k' {
            local id8 = substr(interview__id[`i'],1,8)
            local rsp : di %-12s abbrev(responsible[`i'],12)
            local pat = cond(f_speed[`i'],"S","-") + cond(f_burst[`i'],"B","-")   ///
                      + cond(f_short[`i'],"T","-") + cond(f_night[`i'],"N","-")   ///
                      + cond(f_churn[`i'],"C","-") + cond(f_outlier[`i'],"Z","-")
            local am : di %8.1f active_min[`i']
            local ms : di %7.1f ans_med_s[`i']
            local fs : di %4.2f fast_share[`i']
            local ns : di %5.2f night_share[`i']
            di as txt "  " as res "`id8'" as txt "   `rsp'" as txt " " as res "`pat'" ///
                as txt " `am'  `ms'  `fs'  `ns'"
        }
        sort interview__id
    }

    * ---- interviewer league table (share of their interviews flagged) ----
    quietly count if responsible!=""
    if r(N)>0 {
        preserve
        quietly gen byte __any = n_flags>0
        collapse (count) n_ints=n_flags (sum) n_flagged=__any                    ///
            (p50) ans_med_s active_min (mean) fast_share night_share, by(responsible) fast
        quietly drop if responsible==""
        quietly gen double flag_share = n_flagged/n_ints
        gsort -flag_share -n_flagged responsible
        local k = min(10, _N)
        di as txt _n "  interviewers, by share of interviews flagged (top `k'):"
        di as txt "  {ul:interviewer     }  {ul:ints}  {ul:flagged}  {ul:share}  {ul:med act.min}  {ul:med sec/ans}"
        forvalues i = 1/`k' {
            local rsp : di %-16s abbrev(responsible[`i'],16)
            local ni  : di %4.0f n_ints[`i']
            local nf  : di %5.0f n_flagged[`i']
            local sh  : di %5.2f flag_share[`i']
            local am  : di %9.1f active_min[`i']
            local ms  : di %9.1f ans_med_s[`i']
            di as txt "  `rsp'  `ni'   `nf'   " as res "`sh'" as txt "    `am'      `ms'"
        }
        restore
    }
    di as txt _n "  data in memory = one row per interview with f_* flags (see {bf:describe})."
    di as txt "{hline 72}"

    if `"`saving'"'!="" {
        if "`replace'"=="" {
            capture confirm new file `"`saving'"'
            if _rc {
                di as err "suso: file already exists. Use -replace-."
                exit 602
            }
        }
        quietly save `"`saving'"', `replace'
        di as txt "suso paradata: flag table saved to " as res `"`saving'"'
    }

    return scalar nints    = `nints'
    return scalar nflagged = `nflag'
    foreach f in speed burst short night churn outlier {
        return scalar n_`f' = `c_`f''
    }
end

* ---- skips: gate flips & skip-triggered answer-removal cascades ----------------
* A "cascade" = a run of >= cascade() consecutive AnswerRemoved events that
* starts within window() seconds of an AnswerSet (the trigger). This is the
* paradata signature of a skip flip: the interviewer changes a gate/filter
* answer and Survey Solutions wipes the section it disables. The engine
* enforces enablement at capture time, so this — not "answered while
* disabled" — is the skip check that paradata supports.
program _suso_para_skips, rclass
    version 14.2
    syntax [, CASCade(integer 3) WINdow(real 60) TOP(integer 15) SAVing(string) replace ///
        QX(string) MESSages(string) HTML(string) DETail(string) ]
    _suso_para_need events
    if `cascade'<2 {
        di as err "suso paradata skips: cascade() is the minimum run of AnswerRemoved events; use 2 or more."
        exit 198
    }
    if `window'<=0 {
        di as err "suso paradata skips: window() must be positive (seconds)."
        exit 198
    }

    * parse the questionnaire HTML first (question wording for the messages)
    local hasqx 0
    tempfile QXT
    if `"`qx'"'!="" {
        preserve
        _suso_para_qxload , file(`"`qx'"')
        quietly keep qx_var qx_text qx_section qx_enable
        quietly rename qx_var trigger
        quietly bysort trigger: keep if _n==1
        quietly save `"`QXT'"'
        restore
        local hasqx 1
    }

    local hasvar 0
    capture confirm variable para_var
    if !_rc local hasvar 1
    if !`hasvar' di as txt "suso paradata skips: note — no parameters column (reduced export?); cascades are detected but trigger variables cannot be named."

    capture drop sk_*

    * responsible (same rule as timing: at the last answer, else at the last event)
    quietly gen sk_resp = ""
    capture confirm string variable responsible
    if !_rc {
        tempvar isa
        quietly gen byte `isa' = para_ans
        quietly bysort interview__id (`isa' para_ord para_seq): replace sk_resp = responsible[_N]
    }

    * carry the most recent AnswerSet (variable + time + value) forward through the stream
    if `hasvar' quietly gen sk_lastvar = para_var if para_ans
    else        quietly gen sk_lastvar = "(unnamed)" if para_ans
    quietly gen double sk_lastts = para_tsu if para_ans
    quietly gen sk_lastval = ""
    if `hasvar' {
        capture confirm variable parameters
        if !_rc {
            tempvar pr p2
            quietly gen strL `pr' = substr(parameters, strpos(parameters,"||")+2, .) ///
                if para_ans & strpos(parameters,"||")>0
            quietly gen long `p2' = strpos(`pr',"||")
            quietly replace sk_lastval = substr(cond(`p2'>0, substr(`pr',1,`p2'-1), `pr'), 1, 60) if para_ans
        }
    }
    quietly gen sk_actor = ""
    capture confirm string variable responsible
    if !_rc quietly replace sk_actor = responsible
    quietly bysort interview__id (para_ord para_seq): ///
        replace sk_lastvar = sk_lastvar[_n-1] if sk_lastvar=="" & _n>1
    quietly by interview__id: replace sk_lastts = sk_lastts[_n-1] if missing(sk_lastts) & _n>1
    quietly by interview__id: replace sk_lastval = sk_lastval[_n-1] if sk_lastval=="" & _n>1

    * runs of consecutive AnswerRemoved events
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

    * ---- cascade-level detail: who, when, trigger value, and the erased variables --
    local hasdet 0
    tempfile skdet
    if `ncasc'>0 {
        local hasdet 1
        preserve
        quietly keep if sk_casc
        quietly gen sk_val = sk_lastval
        sort interview__id sk_run para_ord para_seq
        quietly by interview__id sk_run: gen long sk_k = _n
        quietly gen strL sk_wl = ""
        if `hasvar' {
            quietly by interview__id sk_run: replace sk_wl =                     ///
                cond(sk_k==1, para_var, cond(sk_k<=8, sk_wl[_n-1]+", "+para_var, sk_wl[_n-1]))
        }
        collapse (last) wl=sk_wl (count) nrem=sk_k (min) ts0=para_tsu            ///
            (first) trigger=sk_trig trigval=sk_val actor=sk_actor resp=sk_resp,  ///
            by(interview__id sk_run) fast
        if `hasqx' {
            quietly merge m:1 trigger using `"`QXT'"', keep(master match) nogenerate
        }
        quietly save `"`skdet'"'
        if `"`detail'"'!="" quietly copy `"`skdet'"' `"`detail'"', replace
        restore
    }

    * ---- stage 1: collapse to (interview x trigger) — everything below is small,
    *      so the multi-million-row events are copied/sorted exactly once ----
    collapse (sum) n_answers=para_ans n_removed=para_rem n_cascades=sk_casc1     ///
        casc_removed=sk_casc (first) responsible=sk_resp,                        ///
        by(interview__id sk_trig) fast
    tempfile sk1
    quietly save `"`sk1'"'

    di as txt _n "{hline 72}"
    di as res "  suso paradata skips" as txt "   (cascade = >=`cascade' removals within `window's of an answer)"
    di as txt "{hline 72}"

    * ---- survey-level: which gate variables get flipped? ----
    if `hasvar' & `ncasc'>0 {
        quietly keep if sk_trig!=""
        collapse (sum) n_flips=n_cascades wiped=casc_removed                     ///
            (count) n_ints=n_cascades, by(sk_trig) fast
        gsort -wiped -n_flips sk_trig
        local k = min(10, _N)
        tempname SKT
        matrix `SKT' = J(`k', 3, 0)
        local trigret ""
        di as txt "  trigger variables wiping the most answers (top `k'):"
        di as txt "  {ul:variable                }  {ul:flips}  {ul:interviews}  {ul:answers wiped}"
        forvalues i = 1/`k' {
            local vv : di %-24s abbrev(sk_trig[`i'],24)
            local nf : di %5.0f n_flips[`i']
            local ni : di %10.0f n_ints[`i']
            local wp : di %13.0f wiped[`i']
            di as txt "  " as res "`vv'" as txt "  `nf'  `ni'  `wp'"
            local trigret `"`trigret' `=sk_trig[`i']'"'
            matrix `SKT'[`i',1] = n_flips[`i']
            matrix `SKT'[`i',2] = n_ints[`i']
            matrix `SKT'[`i',3] = wiped[`i']
        }
        return local triggers `"`trigret'"'
        return matrix triggers_stats = `SKT'
        quietly use `"`sk1'"', clear
    }

    * ---- stage 2: one row per interview ----
    quietly gen byte sk_tg = (sk_trig!="")
    collapse (sum) n_answers n_removed n_cascades casc_removed n_triggers=sk_tg  ///
        (first) responsible, by(interview__id) fast
    quietly gen double wipe_share = casc_removed/max(n_answers,1)
    label variable interview__id "interview id"
    label variable responsible   "interviewer (at last answer)"
    label variable n_answers     "AnswerSet events"
    label variable n_removed     "AnswerRemoved events (all)"
    label variable n_cascades    "skip cascades (gate flips)"
    label variable casc_removed  "answers wiped by cascades"
    label variable n_triggers    "distinct gate variables flipped"
    label variable wipe_share    "wiped / answers set"
    format wipe_share %5.2f
    sort interview__id
    char _dta[suso_paradata] skips

    quietly count if n_cascades>0
    local naff = r(N)
    local nints = _N
    di as txt "  cascades " as res "`ncasc'" as txt "  |  answers wiped " as res "`nwiped'" ///
        as txt "  |  interviews affected " as res "`naff'" as txt " of " as res "`nints'"

    * ---- top interviews ----
    if `naff'>0 {
        gsort -casc_removed -n_cascades interview__id
        local k = min(`top', `naff')
        di as txt _n "  interviews wiping the most answers (top `k'):"
        di as txt "  {ul:interview}  {ul:interviewer }  {ul:cascades}  {ul:wiped}  {ul:gates}  {ul:wiped/set}"
        forvalues i = 1/`k' {
            local id8 = substr(interview__id[`i'],1,8)
            local rsp : di %-12s abbrev(responsible[`i'],12)
            local nc : di %8.0f n_cascades[`i']
            local wp : di %5.0f casc_removed[`i']
            local ng : di %5.0f n_triggers[`i']
            local ws : di %9.2f wipe_share[`i']
            di as txt "  " as res "`id8'" as txt "   `rsp'" as txt "`nc'  `wp'  `ng'  `ws'"
        }
        sort interview__id

        * ---- interviewer league (share of interviews with any cascade) ----
        quietly count if responsible!=""
        if r(N)>0 {
            preserve
            tempvar anyc
            quietly gen byte `anyc' = n_cascades>0
            collapse (count) n_ints=n_cascades (sum) n_casc=`anyc'                ///
                flips=n_cascades wiped=casc_removed, by(responsible) fast
            quietly drop if responsible==""
            quietly gen double casc_share = n_casc/n_ints
            gsort -casc_share -wiped responsible
            local k = min(10, _N)
            di as txt _n "  interviewers, by share of interviews with a cascade (top `k'):"
            di as txt "  {ul:interviewer     }  {ul:ints}  {ul:w/ cascade}  {ul:share}  {ul:flips}  {ul:wiped}"
            forvalues i = 1/`k' {
                local rsp : di %-16s abbrev(responsible[`i'],16)
                local ni : di %4.0f n_ints[`i']
                local nc : di %10.0f n_casc[`i']
                local sh : di %5.2f casc_share[`i']
                local nf : di %5.0f flips[`i']
                local wp : di %5.0f wiped[`i']
                di as txt "  `rsp'  `ni'  `nc'  " as res "`sh'" as txt "  `nf'  `wp'"
            }
            restore
        }
    }
    di as txt _n "  A cascade can be a legitimate correction; systematic patterns by the"
    di as txt "  same interviewer or the same gate variable are what warrant review."
    di as txt "  data in memory = one row per interview; merge on interview__id with"
    di as txt "  the {bf:suso paradata flags} table for a combined QC file."
    di as txt "{hline 72}"

    * ---- supervisor action list: one clear message per cascade -------------------
    * Every line is built in expression-land (never through macros): answer values
    * and question wording can contain quotes/backticks/dollars that would break
    * macro expansion, so data only ever reaches the screen/file via (exp).
    if `hasdet' {
        preserve
        quietly use `"`skdet'"', clear
        gsort -nrem interview__id sk_run
        local hasqxt 0
        capture confirm variable qx_text
        if !_rc local hasqxt 1
        quietly gen strL m_head = "CASE " + strofreal(_n) + " of `ncasc'.  Interview " ///
            + interview__id + ".  Enumerator: " + cond(actor!="", actor, resp)          ///
            + ".  On " + string(ts0/86400000, "%tdDD_Mon_CCYY") + " at "                ///
            + string(ts0, "%tcHH:MM") + " UTC."
        quietly gen strL m_what = "WHAT HAPPENED: the answer to [" + trigger + "] was changed"
        quietly replace m_what = m_what + " to " + char(34) + trigval + char(34) if trigval!=""
        quietly replace m_what = m_what + " after " + strofreal(nrem)                   ///
            + " later answer(s) had already been recorded. The skip logic then ERASED those " ///
            + strofreal(nrem) + " answer(s)."
        quietly gen strL m_q = ""
        quietly gen strL m_s = ""
        quietly gen strL m_e = ""
        if `hasqxt' {
            quietly replace m_q = "QUESTION [" + trigger + "]: " + char(34)             ///
                + substr(qx_text,1,160) + char(34) if qx_text!=""
            quietly replace m_s = "SECTION: " + substr(qx_section,1,60) if qx_section!=""
            quietly replace m_e = "This question is itself asked only when: "           ///
                + substr(qx_enable,1,120) if qx_enable!=""
        }
        quietly gen strL m_w = ""
        quietly replace m_w = "ERASED ANSWERS: " + substr(wl,1,300) if wl!=""
        quietly replace m_w = m_w + " ... and " + strofreal(nrem-8) + " more" if wl!="" & nrem>8
        local k = min(`top', _N)
        local mh 0
        if `"`messages'"'!="" {
            if "`replace'"=="" {
                capture confirm new file `"`messages'"'
                if _rc {
                    di as err "suso: messages() file already exists. Use -replace-."
                    exit 602
                }
            }
            tempname mf
            quietly file open `mf' using `"`messages'"', write replace text
            local mh 1
            file write `mf' "PARADATA SKIP-VIOLATION REVIEW" _n
            file write `mf' "Generated `c(current_date)' `c(current_time)' by suso paradata skips (suso v1.7.0)" _n
            file write `mf' "Definition: a case is `cascade' or more answers erased by the skip logic within `window' seconds of an answer being changed." _n
            file write `mf' "`ncasc' case(s) found, `nwiped' answers erased in total. The `k' largest are listed below." _n
        }
        di as txt _n "  {hline 70}"
        di as res "  ACTION LIST — what to tell the field supervisor (top `k' of `ncasc')"
        di as txt "  {hline 70}"
        if !`hasqxt' di as txt "  tip: add qx(questionnaire.html) to include the question wording below."
        forvalues i = 1/`k' {
            di as txt ""
            di as res "  " m_head[`i']
            di as txt "  " m_what[`i']
            if `mh' {
                file write `mf' _n "----------------------------------------------------------------------" _n
                file write `mf' (m_head[`i']) _n
                file write `mf' (m_what[`i']) _n
            }
            foreach mv in m_q m_s m_e m_w {
                if `mv'[`i']!="" {
                    di as txt "  " `mv'[`i']
                    if `mh' file write `mf' (`mv'[`i']) _n
                }
            }
            di as txt "  ACTION: 1. Open this interview in Headquarters and check the changed question."
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
        }
        if `mh' {
            file write `mf' _n "----------------------------------------------------------------------" _n
            file write `mf' "General note: occasional cases are honest corrections. The pattern to challenge is the same gate variable erased across many interviews, or one enumerator producing many cases." _n
            file close `mf'
            di as txt _n "  vendor/supervisor message file written: " as res `"`messages'"'
        }

        * ---- shareable Skip Violation Review page (self-contained, printable) ------
        if `"`html'"'!="" {
            if "`replace'"=="" {
                capture confirm new file `"`html'"'
                if _rc {
                    di as err "suso: html() file already exists. Use -replace-."
                    exit 602
                }
            }
            tempfile DET1 DET2 GSUM
            quietly save `"`DET1'"'
            tempvar i1 g1
            quietly bysort interview__id: gen byte `i1' = _n==1
            quietly count if `i1'
            local nintaff = r(N)
            quietly bysort trigger: gen byte `g1' = _n==1
            quietly count if `g1' & trigger!=""
            local ngates = r(N)
            quietly gen long __w = nrem
            collapse (count) flips=__w (sum) wiped=__w, by(trigger) fast
            quietly drop if trigger==""
            gsort -wiped -flips trigger
            quietly keep in 1/`=min(10,_N)'
            quietly save `"`GSUM'"'
            quietly use `"`DET1'"', clear
            gsort -nrem interview__id sk_run
            * pre-built display columns: data reaches the file only via (exp)
            quietly gen strL h_ac = cond(actor!="", actor, resp)
            quietly gen strL h_tg = trigger
            quietly gen strL h_tv0 = trigval
            quietly gen strL h_qt = ""
            quietly gen strL h_sc = ""
            quietly gen strL h_en = ""
            if `hasqxt' {
                quietly replace h_qt = substr(qx_text,1,300)
                quietly replace h_sc = substr(qx_section,1,80)
                quietly replace h_en = substr(qx_enable,1,200)
            }
            quietly gen strL h_wl = substr(wl,1,400)
            foreach v in h_ac h_tg h_tv0 h_qt h_sc h_en h_wl {
                quietly replace `v' = subinstr(subinstr(subinstr(`v',"&","&amp;",.),"<","&lt;",.),">","&gt;",.)
            }
            quietly gen strL h_open = "<div class=" + char(34) + "case" + cond(nrem>=5, " big", "") + char(34) + ">"
            quietly gen strL h_chip = "<div class=" + char(34) + "chip" + char(34) + ">" + strofreal(nrem) + " erased</div>"
            quietly gen strL h_l1 = "<div class=" + char(34) + "c1" + char(34) + "><span class=" + char(34) + "mono" + char(34) + ">" ///
                + interview__id + "</span> &nbsp;&middot;&nbsp; <b>" + h_ac + "</b> &nbsp;&middot;&nbsp; " ///
                + string(ts0/86400000, "%tdDD_Mon_CCYY") + " " + string(ts0, "%tcHH:MM") + " UTC</div>"
            quietly gen strL h_l2 = "<div class=" + char(34) + "c2" + char(34) + ">The answer to <b class=" + char(34) + "mono" + char(34) + ">" + h_tg + "</b> was changed"
            quietly replace h_l2 = h_l2 + " to &quot;" + h_tv0 + "&quot;" if h_tv0!=""
            quietly replace h_l2 = h_l2 + " after <b>" + strofreal(nrem) + "</b> later answers were recorded - the skip logic erased them.</div>"
            quietly gen strL h_l3 = ""
            quietly replace h_l3 = "<blockquote>" + h_tg + ": &quot;" + h_qt + "&quot;</blockquote>" if h_qt!=""
            quietly gen strL h_l4 = ""
            quietly replace h_l4 = "Section: " + h_sc if h_sc!=""
            quietly replace h_l4 = h_l4 + cond(h_l4!="", " &nbsp;&middot;&nbsp; ", "") + "Asked only when: <span class=" + char(34) + "mono" + char(34) + ">" + h_en + "</span>" if h_en!=""
            quietly replace h_l4 = "<div class=" + char(34) + "meta" + char(34) + ">" + h_l4 + "</div>" if h_l4!=""
            quietly gen strL h_l5 = ""
            quietly replace h_l5 = "<div class=" + char(34) + "meta" + char(34) + ">Erased: <span class=" + char(34) + "mono" + char(34) + ">" + h_wl ///
                + cond(nrem>8, " ... and " + strofreal(nrem-8) + " more", "") + "</span></div>" if h_wl!=""
            local now = trim("`c(current_date)' `c(current_time)'")
            local wst ""
            if "$SUSO_WS"!="" local wst " — $SUSO_WS"
            tempname hf
            quietly file open `hf' using `"`html'"', write replace text
            file write `hf' `"<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Skip Violation Review</title><style>"' _n
            file write `hf' `"body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:#f4f5f7;color:#1a1a1a}"' _n
            file write `hf' `".logobar{background:#fff;padding:10px 28px;border-bottom:1px solid #e0e0e0}"' _n
            file write `hf' `".logobar .wbtxt{font-size:13px;letter-spacing:.06em;color:#002244;font-weight:600}.logobar .wbtxt span{color:#8a8a8a;font-weight:400}"' _n
            file write `hf' `".mast{background:#002244;color:#fff;padding:18px 28px}.mast h1{margin:0;font-size:21px;font-weight:600}.mast .sub{color:#c9d4e0;font-size:12.5px;margin-top:5px}"' _n
            file write `hf' `".wrap{max-width:900px;margin:0 auto;padding:16px 28px 40px}"' _n
            file write `hf' `".cards{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0}"' _n
            file write `hf' `".card{flex:1 1 140px;background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:10px 13px;border-top:3px solid #002244}"' _n
            file write `hf' `".card .v{font-size:20px;font-weight:700;color:#002244}.card .k{font-size:11px;color:#666;margin-top:2px;text-transform:uppercase;letter-spacing:.04em}"' _n
            file write `hf' `".how{background:#fdf6e3;border:1px solid #ecd9a0;border-radius:8px;padding:12px 16px;font-size:13px;line-height:1.55;margin:12px 0}"' _n
            file write `hf' `"h2{font-size:15px;color:#002244;border-bottom:2px solid #C9A227;padding-bottom:4px;margin:22px 0 8px}"' _n
            file write `hf' `"table{border-collapse:collapse;width:100%;font-size:12.5px;background:#fff}"' _n
            file write `hf' `"th{background:#002244;color:#fff;text-align:left;padding:6px 8px;font-weight:600}td{padding:5px 8px;border-bottom:1px solid #eef0f2}td.r,th.r{text-align:right}"' _n
            file write `hf' `".case{background:#fff;border:1px solid #e3e6ea;border-left:4px solid #002244;border-radius:8px;padding:12px 16px;margin:10px 0;position:relative;page-break-inside:avoid}"' _n
            file write `hf' `".case.big{border-left-color:#C9A227}"' _n
            file write `hf' `".chip{position:absolute;top:10px;right:12px;background:#002244;color:#fff;border-radius:12px;font-size:11px;padding:3px 10px}"' _n
            file write `hf' `".case.big .chip{background:#C9A227;color:#002244;font-weight:700}"' _n
            file write `hf' `".c1{font-size:12.5px;color:#444;margin-right:90px}.c2{font-size:13.5px;margin-top:6px}"' _n
            file write `hf' `"blockquote{margin:8px 0;padding:8px 12px;background:#f7f8fa;border-left:3px solid #c9cfd6;font-size:12.5px;color:#333}"' _n
            file write `hf' `".meta{font-size:11.5px;color:#666;margin-top:4px}.mono{font-family:Consolas,monospace}"' _n
            file write `hf' `".foot{font-size:11px;color:#777;margin-top:24px;line-height:1.5}"' _n
            file write `hf' `"@media print{body{background:#fff}.case{border:1px solid #bbb;border-left-width:4px}}"' _n
            file write `hf' `"</style></head><body>"' _n
            file write `hf' `"<div class="logobar"><!-- wbLogo slot: replace content with the base64 banner img -->"' _n
            file write `hf' `"<span class="wbtxt">THE WORLD BANK <span>| Development Economics - Policy Indicators</span> &nbsp;-&nbsp; ENTERPRISE SURVEYS <span>- What Businesses Experience</span></span></div>"' _n
            file write `hf' `"<div class="mast"><h1>Skip Violation Review`wst'</h1>"' _n
            file write `hf' `"<div class="sub">Generated `now' &nbsp;-&nbsp; a case is `cascade'+ answers erased by the skip logic within `window's of an answer being changed</div></div>"' _n
            file write `hf' `"<div class="wrap">"' _n
            file write `hf' `"<div class="cards">"' _n
            file write `hf' `"<div class="card"><div class="v">`ncasc'</div><div class="k">cases</div></div>"' _n
            file write `hf' `"<div class="card"><div class="v">`nwiped'</div><div class="k">answers erased</div></div>"' _n
            file write `hf' `"<div class="card"><div class="v">`nintaff'</div><div class="k">interviews affected</div></div>"' _n
            file write `hf' `"<div class="card"><div class="v">`ngates'</div><div class="k">gate questions involved</div></div>"' _n
            file write `hf' `"</div>"' _n
            file write `hf' `"<div class="how"><b>How to handle every case below:</b> open the interview in Headquarters and check the changed question; ask the enumerator why it changed after the later questions were done; if the NEW value is correct, <b>reject the interview</b> so the erased questions are asked again (they are empty now); if the OLD value was correct, restore it and verify the answers below it. Occasional cases are honest corrections - the pattern to challenge is the same gate erased across many interviews, or one enumerator producing many cases.</div>"' _n
            quietly save `"`DET2'"'
            quietly use `"`GSUM'"', clear
            file write `hf' `"<h2>Gate questions flipped most</h2>"' _n
            file write `hf' `"<table><tr><th>variable</th><th class="r">cases</th><th class="r">answers erased</th></tr>"' _n
            forvalues i = 1/`=_N' {
                file write `hf' `"<tr><td class="mono">"' (trigger[`i']) `"</td><td class="r">"' (strofreal(flips[`i'])) `"</td><td class="r">"' (strofreal(wiped[`i'])) `"</td></tr>"' _n
            }
            file write `hf' `"</table>"' _n
            quietly use `"`DET2'"', clear
            file write `hf' `"<h2>Cases, largest first</h2>"' _n
            local kk = min(_N, 200)
            forvalues i = 1/`kk' {
                file write `hf' (h_open[`i']) _n
                file write `hf' (h_chip[`i']) _n
                file write `hf' (h_l1[`i']) _n
                file write `hf' (h_l2[`i']) _n
                if h_l3[`i']!="" file write `hf' (h_l3[`i']) _n
                if h_l4[`i']!="" file write `hf' (h_l4[`i']) _n
                if h_l5[`i']!="" file write `hf' (h_l5[`i']) _n
                file write `hf' `"</div>"' _n
            }
            if _N>`kk' file write `hf' `"<div class="meta">Showing the `kk' largest of `ncasc' cases.</div>"' _n
            file write `hf' `"<div class="foot">Produced by suso paradata skips (suso v1.7.0). Cases are screening signals from the paradata event stream, not proof of misconduct.</div>"' _n
            file write `hf' `"</div></body></html>"' _n
            file close `hf'
            di as txt "  shareable review page written: " as res `"`html'"'
        }
        restore
    }

    if `"`saving'"'!="" {
        if "`replace'"=="" {
            capture confirm new file `"`saving'"'
            if _rc {
                di as err "suso: file already exists. Use -replace-."
                exit 602
            }
        }
        quietly save `"`saving'"', `replace'
        di as txt "suso paradata: skip table saved to " as res `"`saving'"'
    }

    return scalar nints     = `nints'
    return scalar ncascades = `ncasc'
    return scalar nwiped    = `nwiped'
    return scalar naffected = `naff'
end

* ---- report: dynamic self-contained HTML QC report ------------------------------
* All data is embedded as JSON; vanilla JS (no CDN, works offline) recomputes
* every figure and table live as the user filters by enumerator, searches
* questions, or moves the flag thresholds / night window.
program _suso_para_report, rclass
    version 14.2
    syntax [, SAVing(string) replace TITle(string) QX(string)                    ///
        GAPMins(real 30) FASTsecs(real 2) ALLRoles                               ///
        CASCade(integer 3) WINdow(real 60) LITEcap(integer 15000) ]
    _suso_para_need events

    if `"`saving'"'=="" local saving "suso_paradata_qc.html"
    if "`replace'"=="" {
        capture confirm new file `"`saving'"'
        if _rc {
            di as err "suso: file already exists. Use -replace-."
            exit 602
        }
    }
    if `"`title'"'=="" {
        local title "Paradata QC report"
        if "$SUSO_WS"!="" local title "Paradata QC report — $SUSO_WS"
    }
    _suso_para_hesc `"`title'"'
    local htitle `"`r(out)'"'

    di as txt "suso paradata: building the interactive QC report ..."
    tempfile EV EVD SK QT DAILY HHF GGF MERGED RSD
    quietly save `"`EV'"'
    local nevents = _N

    _suso_para_derive , gapmins(`gapmins') fastsecs(`fastsecs') `allroles'
    local rolenote `"`r(rolenote)'"'
    quietly save `"`EVD'"'

    * ---- question timing table --------------------------------------------------
    local hasq 0
    capture confirm variable para_var
    if !_rc {
        quietly keep if para_ans & para_ivw & para_var!=""
        if _N>0 {
            local hasq 1
            tempvar tag
            quietly bysort para_var interview__id: gen byte `tag' = _n==1
            collapse (sum) qn=para_one qni=`tag' qnf=para_fast (count) qnt=para_ansgap ///
                (p50) qmed=para_ansgap (p90) qp90=para_ansgap, by(para_var) fast
            quietly gen double qfsh = qnf/qnt if qnt>0
            gsort -qmed para_var
            quietly save `"`QT'"'
        }
    }

    * ---- interviewer-day volume + lite decision ----------------------------------
    quietly use `"`EVD'"', clear
    quietly keep if para_ans & para_ivw & !missing(para_tsu)
    if _N==0 {
        di as err "suso paradata report: no interviewer answer events — nothing to report on."
        exit 2000
    }
    tempvar f1
    quietly bysort interview__id: gen byte `f1' = _n==1
    quietly count if `f1'
    local lite = cond(r(N)>`litecap', 1, 0)
    capture confirm string variable responsible
    if _rc quietly gen responsible = para_resp
    tempvar ddv
    quietly gen long `ddv' = dofc(para_tsu)
    quietly contract responsible `ddv', freq(__pc)
    quietly drop if missing(`ddv')
    local dbucket 0
    if _N>2500 {
        local dbucket 1
        quietly replace `ddv' = `ddv' - mod(`ddv', 7)
        collapse (sum) __pc, by(responsible `ddv') fast
    }
    quietly gen long __dd = `ddv'
    quietly save `"`DAILY'"'
    local dnote = cond(`dbucket', "7-day blocks", "per day")

    * ---- per-interview hour and answer-gap vectors (skipped for huge surveys) ----
    if !`lite' {
        quietly use `"`EVD'"', clear
        quietly keep if para_ans & para_ivw & !missing(para_tsl)
        quietly gen byte __hh = hh(para_tsl)
        quietly contract interview__id __hh, freq(__pc)
        forvalues h = 0/23 {
            quietly gen long h`h' = cond(__hh==`h', __pc, 0)
        }
        collapse (sum) h0-h23, by(interview__id) fast
        quietly save `"`HHF'"'
        quietly use `"`EVD'"', clear
        quietly keep if !missing(para_ansgap)
        if _N>0 {
            quietly gen byte __g = min(floor(para_ansgap), 20)
            quietly contract interview__id __g, freq(__pc)
            forvalues g = 0/20 {
                quietly gen long g`g' = cond(__g==`g', __pc, 0)
            }
            collapse (sum) g0-g20, by(interview__id) fast
            quietly save `"`GGF'"'
        }
        else local lite 1
    }

    * ---- skip cascades ------------------------------------------------------------
    quietly use `"`EV'"', clear
    quietly _suso_para_skips , cascade(`cascade') window(`window') qx(`"`qx'"') detail(`"`RSD'"')
    local ncasc = r(ncascades)
    local nwiped = r(nwiped)
    local trignames `"`r(triggers)'"'
    tempname RT
    capture matrix `RT' = r(triggers_stats)
    quietly keep interview__id n_cascades casc_removed n_triggers
    quietly save `"`SK'"'

    * ---- timing + flags (defaults; live thresholds are client-side) ---------------
    quietly use `"`EVD'"', clear
    quietly _suso_para_timing , by(interview) gapmins(`gapmins') fastsecs(`fastsecs') `allroles'
    quietly _suso_para_flags
    quietly merge 1:1 interview__id using `"`SK'"', nogenerate
    foreach v in n_cascades casc_removed n_triggers {
        quietly replace `v' = 0 if missing(`v')
    }
    if !`lite' {
        quietly merge 1:1 interview__id using `"`HHF'"', nogenerate
        quietly merge 1:1 interview__id using `"`GGF'"', nogenerate
        forvalues h = 0/23 {
            quietly replace h`h' = 0 if missing(h`h')
        }
        forvalues g = 0/20 {
            quietly replace g`g' = 0 if missing(g`g')
        }
    }
    char _dta[suso_paradata] timing
    local nints = _N
    quietly count if started
    local nstarted = r(N)
    quietly count if n_completed>0
    local ncompleted = r(N)
    local nuntouched = `nints' - `nstarted'
    quietly summarize active_min
    local tothrc : di %12.0fc r(sum)/60
    local tothrc = trim("`tothrc'")
    local nintsc : di %12.0fc `nints'
    local nintsc = trim("`nintsc'")
    local nstartedc : di %12.0fc `nstarted'
    local nstartedc = trim("`nstartedc'")
    local ncompletedc : di %12.0fc `ncompleted'
    local ncompletedc = trim("`ncompletedc'")
    local nuntouchedc : di %12.0fc `nuntouched'
    local nuntouchedc = trim("`nuntouchedc'")
    local warnc = cond(`ncasc'>0, "warn", "dim")
    quietly save `"`MERGED'"'

    * ---- write the HTML -----------------------------------------------------------
    local now = trim("`c(current_date)' `c(current_time)'")
    tempname fh
    quietly file open `fh' using `"`saving'"', write replace text
    file write `fh' `"<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">"' _n
    file write `fh' `"<title>`htitle'</title><style>"' _n
    file write `fh' `"body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:#f4f5f7;color:#1a1a1a}"' _n
    file write `fh' `".logobar{background:#fff;padding:10px 28px;border-bottom:1px solid #e0e0e0}"' _n
    file write `fh' `".logobar .wbtxt{font-size:13px;letter-spacing:.06em;color:#002244;font-weight:600}"' _n
    file write `fh' `".logobar .wbtxt span{color:#8a8a8a;font-weight:400}"' _n
    file write `fh' `".mast{background:#002244;color:#fff;padding:18px 28px}"' _n
    file write `fh' `".mast h1{margin:0;font-size:22px;font-weight:600}"' _n
    file write `fh' `".mast .sub{color:#c9d4e0;font-size:12.5px;margin-top:5px}"' _n
    file write `fh' `".wrap{max-width:1040px;margin:0 auto;padding:16px 28px 40px}"' _n
    file write `fh' `".cards{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0 4px}"' _n
    file write `fh' `".card{flex:1 1 130px;background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:10px 13px;border-top:3px solid #002244}"' _n
    file write `fh' `".card.dim{border-top-color:#9aa7b5}.card.warn{border-top-color:#C9A227}"' _n
    file write `fh' `".card .v{font-size:20px;font-weight:700;color:#002244}"' _n
    file write `fh' `".card .k{font-size:11px;color:#666;margin-top:2px;text-transform:uppercase;letter-spacing:.04em}"' _n
    file write `fh' `".panel{background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:12px 16px;margin:12px 0;display:flex;flex-wrap:wrap;gap:14px;align-items:flex-end;position:sticky;top:0;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.06)}"' _n
    file write `fh' `".ctrl{display:flex;flex-direction:column;gap:3px}"' _n
    file write `fh' `".ctrl label{font-size:10.5px;color:#555;text-transform:uppercase;letter-spacing:.03em}"' _n
    file write `fh' `".ctrl input,.ctrl select{font-size:13px;padding:4px 6px;border:1px solid #c9cfd6;border-radius:5px;min-width:64px}"' _n
    file write `fh' `"#c_resp{min-width:220px}"' _n
    file write `fh' `"#c_reset{background:#002244;color:#fff;border:0;border-radius:5px;padding:7px 14px;font-size:12.5px;cursor:pointer}"' _n
    file write `fh' `".verdict{margin:10px 0;padding:10px 14px;border-radius:8px;font-size:13.5px;font-weight:600}"' _n
    file write `fh' `".verdict.ok{background:#eaf5ec;color:#1e6b34;border:1px solid #bfe0c8}"' _n
    file write `fh' `".verdict.warn{background:#fdf6e3;color:#7a5b00;border:1px solid #ecd9a0}"' _n
    file write `fh' `"h2{font-size:15px;color:#002244;border-bottom:2px solid #C9A227;padding-bottom:4px;margin:24px 0 4px}"' _n
    file write `fh' `".note{font-size:12px;color:#555;margin:2px 0 8px}"' _n
    file write `fh' `"section{background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:8px 16px 14px;margin-top:8px}"' _n
    file write `fh' `"table{border-collapse:collapse;width:100%;font-size:12.5px}"' _n
    file write `fh' `"th{background:#002244;color:#fff;text-align:left;padding:6px 8px;font-weight:600}"' _n
    file write `fh' `"th.srt{cursor:pointer}th.srt:hover{background:#0a3560}"' _n
    file write `fh' `"td{padding:5px 8px;border-bottom:1px solid #eef0f2}tr:nth-child(even) td{background:#fafbfc}"' _n
    file write `fh' `"td.r,th.r{text-align:right}tr.hot td{background:#fdf6e3}"' _n
    file write `fh' `".mono{font-family:Consolas,monospace}"' _n
    file write `fh' `".bar{display:inline-block;height:9px;background:#C9A227;border-radius:2px;vertical-align:middle}"' _n
    file write `fh' `".nodata{color:#888;font-size:12px}"' _n
    file write `fh' `".foot{font-size:11px;color:#777;margin-top:26px;line-height:1.5}"' _n
    file write `fh' `"#lite_note,#q_more,#l_more,#w_none,#n_act{font-size:11.5px;color:#8a6d00}"' _n
    file write `fh' `"</style></head><body>"' _n
    file write `fh' `"<div class="logobar"><!-- wbLogo slot: replace content with the base64 banner img -->"' _n
    file write `fh' `"<span class="wbtxt">THE WORLD BANK <span>| Development Economics - Policy Indicators</span> &nbsp;-&nbsp; ENTERPRISE SURVEYS <span>- What Businesses Experience</span></span></div>"' _n
    file write `fh' `"<div class="mast"><h1>`htitle'</h1>"' _n
    local sub "Generated `now'"
    if "$SUSO_BASE"!="" local sub "`sub' &nbsp;-&nbsp; $SUSO_BASE"
    if "$SUSO_GUID"!="" local sub "`sub' &nbsp;-&nbsp; questionnaire $SUSO_GUID v$SUSO_QVER"
    file write `fh' `"<div class="sub">`sub' &nbsp;-&nbsp; `nevents' paradata events</div></div>"' _n
    file write `fh' `"<div class="wrap">"' _n
    file write `fh' `"<div class="cards">"' _n
    file write `fh' `"<div class="card dim"><div class="v">`nintsc'</div><div class="k">records in paradata</div></div>"' _n
    file write `fh' `"<div class="card"><div class="v">`nstartedc'</div><div class="k">fieldwork started</div></div>"' _n
    file write `fh' `"<div class="card"><div class="v">`ncompletedc'</div><div class="k">completed</div></div>"' _n
    file write `fh' `"<div class="card dim"><div class="v">`nuntouchedc'</div><div class="k">never started (preload only)</div></div>"' _n
    file write `fh' `"<div class="card"><div class="v">`tothrc'</div><div class="k">interviewer hours</div></div>"' _n
    file write `fh' `"<div class="card `warnc'"><div class="v">`ncasc'</div><div class="k">skip cascades (`nwiped' wiped)</div></div>"' _n
    file write `fh' `"</div>"' _n
    file write `fh' `"<div class="panel">"' _n
    file write `fh' `"<div class="ctrl"><label>Enumerator</label><select id="c_resp"></select></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Fast answer &lt; sec</label><input id="c_fs" type="number" min="1" max="10" step="1"></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Burst share %</label><input id="c_burst" type="number" min="5" max="90" step="1" value="33"></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Min active min</label><input id="c_minact" type="number" min="1" max="240" step="1" value="10"></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Night from</label><select id="c_n1"></select></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Night to</label><select id="c_n2"></select></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Night share %</label><input id="c_nshare" type="number" min="1" max="100" step="1" value="25"></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Churn %</label><input id="c_churn" type="number" min="1" max="100" step="1" value="20"></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Outlier z</label><input id="c_z" type="number" min="2" max="6" step="0.5" value="3.5"></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Show top</label><input id="c_top" type="number" min="5" max="100" step="5" value="15"></div>"' _n
    file write `fh' `"<button id="c_reset">Reset</button>"' _n
    file write `fh' `"<span id="lite_note"></span>"' _n
    file write `fh' `"</div>"' _n
    file write `fh' `"<div class="cards">"' _n
    file write `fh' `"<div class="card"><div class="v" id="k_started">-</div><div class="k">interviews in view</div></div>"' _n
    file write `fh' `"<div class="card warn"><div class="v" id="k_flagged">-</div><div class="k">flagged</div></div>"' _n
    file write `fh' `"<div class="card"><div class="v" id="k_medact">-</div><div class="k">median active min</div></div>"' _n
    file write `fh' `"<div class="card"><div class="v" id="k_medans">-</div><div class="k">median sec / answer</div></div>"' _n
    file write `fh' `"</div>"' _n
    file write `fh' `"<div id="verdict" class="verdict"></div>"' _n
    file write `fh' `"<h2>Behaviour flags</h2>"' _n
    file write `fh' `"<div class="note">Screening signals, not proof. Adjust the thresholds in the panel above; everything on this page recomputes instantly. Only interviews with actual fieldwork are analysed; API-preloaded grid records are set aside.</div>"' _n
    file write `fh' `"<section id="ch_flags"></section>"' _n
    file write `fh' `"<h2>How long do interviews take?</h2>"' _n
    file write `fh' `"<div class="note">Active interviewer time per interview: gaps over `gapmins' min and pauses excluded. <span id="n_act"></span></div>"' _n
    file write `fh' `"<section id="ch_act"></section>"' _n
    file write `fh' `"<h2>How fast are answers?</h2>"' _n
    file write `fh' `"<div class="note">Each interview gets one number: the typical (median) time the interviewer took to answer one question. The bar above 5 counts interviews where a typical question took about 5 seconds; the last bar groups 20 seconds or more. A real interview needs time to ask, listen and type - so an interview answered at a sustained 1-2 seconds per question was probably filled in without talking to anyone. <span id="n_med"></span></div>"' _n
    file write `fh' `"<section id="ch_med"></section>"' _n
    file write `fh' `"<h2>When is the work happening?</h2>"' _n
    file write `fh' `"<div class="note">Interviewer answers by hour of day (device-local time). Gold bars mark the night window set in the panel - night answering on establishment surveys usually means desk work, not fieldwork.</div>"' _n
    file write `fh' `"<section id="ch_hour"></section>"' _n
    file write `fh' `"<h2>Fieldwork over time</h2>"' _n
    file write `fh' `"<div class="note">Interviewer answers recorded per day (`dnote'). Responds to the enumerator filter.</div>"' _n
    file write `fh' `"<section id="ch_daily"></section>"' _n
    file write `fh' `"<h2>Enumerators</h2>"' _n
    file write `fh' `"<div class="note">Compare within the team: someone whose answer speed or night share stands well apart from colleagues on the same instrument is the one to review first. Gold rows have at least one flagged interview. <span id="l_more"></span></div>"' _n
    file write `fh' `"<section><table id="t_league"></table></section>"' _n
    file write `fh' `"<h2>Interviews to review first</h2>"' _n
    file write `fh' `"<div class="note">Sorted by flags raised, then answers wiped, then speed. Flag pattern S B T N C Z as above. Interview ids are full and copyable for lookup in Headquarters. <span id="w_none"></span></div>"' _n
    file write `fh' `"<section><table id="t_worst"></table></section>"' _n
    file write `fh' `"<h2>Question timing</h2>"' _n
    file write `fh' `"<div class="note">Median seconds to answer each question, across interviews with fieldwork. Type to filter; click a column header to sort. Slow questions are usually hard questions - candidates for rewording or interviewer training. <span id="q_more"></span></div>"' _n
    file write `fh' `"<section><div class="ctrl" style="max-width:280px;margin-bottom:8px"><label>Filter questions</label><input id="c_q" type="text" placeholder="variable name contains..."></div><table id="t_q"></table></section>"' _n
    * static skip-trigger table
    if `ncasc'>0 & `"`trignames'"'!="" {
        file write `fh' `"<h2>Gate variables wiping answers</h2>"' _n
        file write `fh' `"<div class="note">A cascade is `cascade'+ consecutive answer removals within `window' seconds of an answer (a gate/filter flip). Occasional cascades are honest corrections; the same gate flipped across many interviews is skip abuse or a badly worded filter. These are computed at build time.</div>"' _n
        file write `fh' `"<section><table><tr><th>variable</th><th class="r">flips</th><th class="r">interviews</th><th class="r">answers wiped</th></tr>"' _n
        local i = 0
        foreach t of local trignames {
            local ++i
            _suso_para_hesc `t'
            file write `fh' `"<tr><td class="mono">`r(out)'</td><td class="r">`=`RT'[`i',1]'</td><td class="r">`=`RT'[`i',2]'</td><td class="r">`=`RT'[`i',3]'</td></tr>"' _n
        }
        file write `fh' `"</table></section>"' _n
    }
    capture confirm file `"`RSD'"'
    if !_rc & `ncasc'>0 {
        preserve
        quietly use `"`RSD'"', clear
        gsort -nrem interview__id sk_run
        local hasqxt 0
        capture confirm variable qx_text
        if !_rc local hasqxt 1
        * escaped display columns: data reaches the file only via (exp), never macros
        quietly gen strL e_ac = cond(actor!="", actor, resp)
        quietly gen strL e_tg = trigger
        quietly gen strL e_tv0 = trigval
        quietly gen strL e_qt = ""
        if `hasqxt' quietly replace e_qt = substr(qx_text,1,160)
        quietly gen strL e_wl = substr(wl,1,300)
        foreach v in e_ac e_tg e_tv0 e_qt e_wl {
            quietly replace `v' = subinstr(subinstr(subinstr(`v',"&","&amp;",.),"<","&lt;",.),">","&gt;",.)
        }
        quietly gen strL e_tv = ""
        quietly replace e_tv = " to &quot;" + e_tv0 + "&quot;" if e_tv0!=""
        quietly gen strL e_mr = ""
        quietly replace e_mr = " ... and " + strofreal(nrem-8) + " more" if nrem>8 & e_wl!=""
        quietly gen str24 e_dt = string(ts0/86400000, "%tdDD_Mon_CCYY")
        file write `fh' `"<h2>Actions for the field supervisor</h2>"' _n
        file write `fh' `"<div class="note">One entry per skip violation, largest first. If the new gate value is right, the interview should be rejected so the erased questions are re-asked; if the old value was right, restore it and verify the section. For an email-ready version run: suso paradata skips , qx(questionnaire.html) messages(review.txt)</div>"' _n
        file write `fh' `"<section>"' _n
        local kk = min(15, _N)
        forvalues i = 1/`kk' {
            file write `fh' `"<div style="border-bottom:1px solid #eef0f2;padding:9px 0">"' _n
            file write `fh' `"<div style="font-size:13px"><span class="mono"><b>"' (interview__id[`i']) `"</b></span> &nbsp; enumerator <b>"' (e_ac[`i']) `"</b> &nbsp; "' (e_dt[`i']) `"</div>"' _n
            file write `fh' `"<div style="font-size:12.5px;margin-top:3px">The answer to <b class="mono">"' (e_tg[`i']) `"</b> was changed"' (e_tv[`i']) `" after <b>"' (strofreal(nrem[`i'])) `"</b> later answers were recorded - the skip logic erased them.</div>"' _n
            if e_qt[`i']!="" {
                file write `fh' `"<div class="note" style="margin:2px 0 0"><span class="mono">"' (e_tg[`i']) `"</span>: &quot;"' (e_qt[`i']) `"&quot;</div>"' _n
            }
            if e_wl[`i']!="" {
                file write `fh' `"<div class="note" style="margin:2px 0 0">Erased: <span class="mono">"' (e_wl[`i']) (e_mr[`i']) `"</span></div>"' _n
            }
            file write `fh' `"</div>"' _n
        }
        file write `fh' `"</section>"' _n
        restore
    }
    _suso_para_hesc `"`rolenote'"'
    local rnesc `"`r(out)'"'
    file write `fh' `"<div class="foot"><b>Method.</b> Timing uses `rnesc'. Active time sums inter-event gaps within each interview, capping every gap at `gapmins' minutes and zeroing Paused-to-Resumed intervals. Answer speed is the gap preceding each AnswerSet within a session. Night uses device-local time. Duration outliers use a robust (median/MAD) z on log active time. Records with no interviewer activity (`nuntouchedc' of `nintsc' here, typically API-preloaded grid points) are excluded from all figures. Flags are screening signals for review, not evidence of fabrication.<br><b>Produced by</b> suso paradata report (suso v1.7.0) on `now'. Thresholds shown in the control panel are live and local to this page.</div>"' _n
    file write `fh' `"</div>"' _n

    * ---- embedded data ------------------------------------------------------------
    file write `fh' `"<script>"' _n
    file write `fh' `"var D={"meta":{"fastsecs":`fastsecs',"gapmins":`gapmins',"lite":`lite'},"' _n
    file write `fh' `""rows":["' _n
    quietly use `"`MERGED'"', clear
    quietly keep if started
    forvalues i = 1/`=_N' {
        _suso_jsonesc `"`=responsible[`i']'"'
        local rj `"`r(js)'"'
        local med = cond(missing(ans_med_s[`i']), "null", string(ans_med_s[`i'],"%12.2f"))
        local fsh = cond(missing(fast_share[`i']), "null", string(fast_share[`i'],"%12.3f"))
        local nsh = cond(missing(night_share[`i']), "null", string(night_share[`i'],"%12.3f"))
        local vecs ""
        if !`lite' {
            local hv "`=h0[`i']'"
            forvalues h = 1/23 {
                local hv "`hv',`=h`h'[`i']'"
            }
            local gv "`=g0[`i']'"
            forvalues g = 1/20 {
                local gv "`gv',`=g`g'[`i']'"
            }
            local vecs `","h":[`hv'],"g":[`gv']"'
        }
        local sep = cond(`i'==1, "", ",")
        file write `fh' `"`sep'{"id":"`=interview__id[`i']'","r":"`rj'","nt":`=n_timed[`i']',"nc":`=n_completed[`i']',"act":`=string(active_min[`i'],"%12.2f")',"med":`med',"fsh":`fsh',"nsh":`nsh',"ch":`=string(churn[`i'],"%12.3f")',"cas":`=n_cascades[`i']',"wip":`=casc_removed[`i']'`vecs'}"' _n
    }
    file write `fh' `"],"' _n
    file write `fh' `""q":["' _n
    if `hasq' {
        quietly use `"`QT'"', clear
        forvalues i = 1/`=_N' {
            _suso_jsonesc `"`=para_var[`i']'"'
            local vj `"`r(js)'"'
            local med = cond(missing(qmed[`i']), "null", string(qmed[`i'],"%12.1f"))
            local p90 = cond(missing(qp90[`i']), "null", string(qp90[`i'],"%12.1f"))
            local fsh = cond(missing(qfsh[`i']), "null", string(qfsh[`i'],"%12.3f"))
            local sep = cond(`i'==1, "", ",")
            file write `fh' `"`sep'{"v":"`vj'","n":`=qn[`i']',"ni":`=qni[`i']',"med":`med',"p90":`p90',"fsh":`fsh'}"' _n
        }
    }
    file write `fh' `"],"' _n
    file write `fh' `""daily":["' _n
    quietly use `"`DAILY'"', clear
    forvalues i = 1/`=_N' {
        _suso_jsonesc `"`=responsible[`i']'"'
        local rj `"`r(js)'"'
        local dl : di %tdCCYY-NN-DD __dd[`i']
        local sep = cond(`i'==1, "", ",")
        file write `fh' `"`sep'{"r":"`rj'","d":"`=trim("`dl'")'","c":`=__pc[`i']'}"' _n
    }
    file write `fh' `"]};"' _n
    file write `fh' `"/* suso paradata report - dynamic engine. Pure compute core in P (node-testable), DOM layer below. */"' _n
    file write `fh' `"var P = {"' _n
    file write `fh' `"  sum: function(a){ var s=0,i; for(i=0;i<a.length;i++) s+=a[i]; return s; },"' _n
    file write `fh' `"  inWindow: function(h,n1,n2){ if(n1===n2) return false; if(n1<n2) return h>=n1&&h<n2; return h>=n1||h<n2; },"' _n
    file write `fh' `"  fastShare: function(row,fs){"' _n
    file write `fh' `"    if(!row.g) return row.fsh;"' _n
    file write `fh' `"    var t=P.sum(row.g); if(t<=0) return null;"' _n
    file write `fh' `"    var f=0,i; for(i=0;i<row.g.length&&i<fs;i++) f+=row.g[i];"' _n
    file write `fh' `"    return f/t;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  nightShare: function(row,n1,n2){"' _n
    file write `fh' `"    if(!row.h) return row.nsh;"' _n
    file write `fh' `"    var t=P.sum(row.h); if(t<=0) return null;"' _n
    file write `fh' `"    var s=0,i; for(i=0;i<24;i++) if(P.inWindow(i,n1,n2)) s+=row.h[i];"' _n
    file write `fh' `"    return s/t;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  median: function(a){"' _n
    file write `fh' `"    if(!a.length) return null;"' _n
    file write `fh' `"    var b=a.slice().sort(function(x,y){return x-y;});"' _n
    file write `fh' `"    var m=Math.floor(b.length/2);"' _n
    file write `fh' `"    return b.length%2 ? b[m] : (b[m-1]+b[m])/2;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  zctx: function(rows){"' _n
    file write `fh' `"    var lx=[],i;"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++) if(rows[i].act>0) lx.push(Math.log(rows[i].act));"' _n
    file write `fh' `"    if(lx.length<10) return null;"' _n
    file write `fh' `"    var med=P.median(lx), dev=[],j;"' _n
    file write `fh' `"    for(j=0;j<lx.length;j++) dev.push(Math.abs(lx[j]-med));"' _n
    file write `fh' `"    var mad=P.median(dev);"' _n
    file write `fh' `"    if(!(mad>0)) return null;"' _n
    file write `fh' `"    return {med:med, mad:mad};"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  zval: function(row,ctx){"' _n
    file write `fh' `"    if(!ctx||!(row.act>0)) return null;"' _n
    file write `fh' `"    return 0.6745*(Math.log(row.act)-ctx.med)/ctx.mad;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  flagsFor: function(row,S,ctx){"' _n
    file write `fh' `"    var fsh=P.fastShare(row,S.fs), nsh=P.nightShare(row,S.n1,S.n2), z=P.zval(row,ctx);"' _n
    file write `fh' `"    return ["' _n
    file write `fh' `"      row.med!==null && row.med<S.fs,"' _n
    file write `fh' `"      fsh!==null && fsh>S.burst,"' _n
    file write `fh' `"      row.nc>0 && row.act<S.minact,"' _n
    file write `fh' `"      nsh!==null && nsh>S.nshare && row.nt>=10,"' _n
    file write `fh' `"      row.ch!==null && row.ch>S.churn && row.nt>=10,"' _n
    file write `fh' `"      z!==null && Math.abs(z)>S.z"' _n
    file write `fh' `"    ];"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  filterRows: function(rows,resp){"' _n
    file write `fh' `"    if(!resp) return rows.slice();"' _n
    file write `fh' `"    var out=[],i;"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++) if(rows[i].r===resp) out.push(rows[i]);"' _n
    file write `fh' `"    return out;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  aggregate: function(rows,S){"' _n
    file write `fh' `"    var ctx=P.zctx(rows), tot=[0,0,0,0,0,0], flagged=[], i,j;"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++){"' _n
    file write `fh' `"      var f=P.flagsFor(rows[i],S,ctx), n=0;"' _n
    file write `fh' `"      for(j=0;j<6;j++){ if(f[j]){tot[j]++;n++;} }"' _n
    file write `fh' `"      rows[i]._f=f; rows[i]._n=n;"' _n
    file write `fh' `"      if(n>0||rows[i].cas>0) flagged.push(rows[i]);"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    flagged.sort(function(a,b){"' _n
    file write `fh' `"      if(b._n!==a._n) return b._n-a._n;"' _n
    file write `fh' `"      if(b.wip!==a.wip) return b.wip-a.wip;"' _n
    file write `fh' `"      var am=a.med===null?1e9:a.med, bm=b.med===null?1e9:b.med;"' _n
    file write `fh' `"      return am-bm;"' _n
    file write `fh' `"    });"' _n
    file write `fh' `"    var nfl=0;"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++) if(rows[i]._n>0) nfl++;"' _n
    file write `fh' `"    return {tot:tot, flagged:flagged, nflagged:nfl, n:rows.length};"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  niceBin: function(p99){"' _n
    file write `fh' `"    var c=[1,2,5,10,15,30,60,120,240,480], i, b=1;"' _n
    file write `fh' `"    for(i=0;i<c.length;i++){ b=c[i]; if(c[i]*20>=p99) break; }"' _n
    file write `fh' `"    return b;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  binsActive: function(rows){"' _n
    file write `fh' `"    var act=[],i;"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++) act.push(rows[i].act);"' _n
    file write `fh' `"    if(!act.length) return {w:1,c:[]};"' _n
    file write `fh' `"    var s=act.slice().sort(function(x,y){return x-y;});"' _n
    file write `fh' `"    var p99=Math.max(s[Math.min(s.length-1,Math.floor(0.99*s.length))],1);"' _n
    file write `fh' `"    var w=P.niceBin(p99), c=[],k;"' _n
    file write `fh' `"    for(k=0;k<20;k++) c.push(0);"' _n
    file write `fh' `"    for(i=0;i<act.length;i++) c[Math.min(Math.floor(act[i]/w),19)]++;"' _n
    file write `fh' `"    return {w:w,c:c};"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  binsMed: function(rows){"' _n
    file write `fh' `"    var c=[],k,i;"' _n
    file write `fh' `"    for(k=0;k<21;k++) c.push(0);"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++) if(rows[i].med!==null) c[Math.min(Math.floor(rows[i].med),20)]++;"' _n
    file write `fh' `"    return c;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  hourTotals: function(rows){"' _n
    file write `fh' `"    var t=[],k,i,j;"' _n
    file write `fh' `"    for(k=0;k<24;k++) t.push(0);"' _n
    file write `fh' `"    var any=false;"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++){"' _n
    file write `fh' `"      if(!rows[i].h) continue;"' _n
    file write `fh' `"      any=true;"' _n
    file write `fh' `"      for(j=0;j<24;j++) t[j]+=rows[i].h[j];"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    return any?t:null;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  dailyTotals: function(daily,resp){"' _n
    file write `fh' `"    var m={},i,k;"' _n
    file write `fh' `"    for(i=0;i<daily.length;i++){"' _n
    file write `fh' `"      if(resp&&daily[i].r!==resp) continue;"' _n
    file write `fh' `"      k=daily[i].d;"' _n
    file write `fh' `"      m[k]=(m[k]||0)+daily[i].c;"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    var keys=Object.keys(m).sort(), out=[];"' _n
    file write `fh' `"    for(i=0;i<keys.length;i++) out.push({d:keys[i],c:m[keys[i]]});"' _n
    file write `fh' `"    return out;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  league: function(rows,S){"' _n
    file write `fh' `"    var ctx=P.zctx(rows), m={}, i, r;"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++){"' _n
    file write `fh' `"      r=rows[i];"' _n
    file write `fh' `"      if(!m[r.r]) m[r.r]={r:r.r,n:0,fl:0,act:[],med:[],fsh:[],nsh:[]};"' _n
    file write `fh' `"      var g=m[r.r], f=P.flagsFor(r,S,ctx), any=false, j;"' _n
    file write `fh' `"      for(j=0;j<6;j++) if(f[j]) any=true;"' _n
    file write `fh' `"      g.n++; if(any||r.cas>0) g.fl++;"' _n
    file write `fh' `"      g.act.push(r.act);"' _n
    file write `fh' `"      if(r.med!==null) g.med.push(r.med);"' _n
    file write `fh' `"      var fs=P.fastShare(r,S.fs); if(fs!==null) g.fsh.push(fs);"' _n
    file write `fh' `"      var ns=P.nightShare(r,S.n1,S.n2); if(ns!==null) g.nsh.push(ns);"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    var out=[],k;"' _n
    file write `fh' `"    for(k in m){ if(m.hasOwnProperty(k)) out.push(m[k]); }"' _n
    file write `fh' `"    for(i=0;i<out.length;i++){"' _n
    file write `fh' `"      out[i].medact=P.median(out[i].act);"' _n
    file write `fh' `"      out[i].medmed=P.median(out[i].med);"' _n
    file write `fh' `"      out[i].mfsh=out[i].fsh.length?P.sum(out[i].fsh)/out[i].fsh.length:null;"' _n
    file write `fh' `"      out[i].mnsh=out[i].nsh.length?P.sum(out[i].nsh)/out[i].nsh.length:null;"' _n
    file write `fh' `"      out[i].share=out[i].fl/out[i].n;"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    out.sort(function(a,b){ return b.n-a.n; });"' _n
    file write `fh' `"    return out;"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"};"' _n
    file write `fh' `"if (typeof module!=='undefined' && module.exports) module.exports=P;"' _n
    file write `fh' _n
    file write `fh' `"/* ---------------- DOM layer (browser only) ---------------- */"' _n
    file write `fh' `"if (typeof document!=='undefined') {"' _n
    file write `fh' _n
    file write `fh' `"function el(id){ return document.getElementById(id); }"' _n
    file write `fh' `"function fmt(x,d){"' _n
    file write `fh' `"  if(x===null||x===undefined||isNaN(x)) return '.';"' _n
    file write `fh' `"  var s=x.toFixed(d===undefined?1:d);"' _n
    file write `fh' `"  return s;"' _n
    file write `fh' `"}"' _n
    file write `fh' `"function fmtc(x){"' _n
    file write `fh' `"  if(x===null||x===undefined) return '.';"' _n
    file write `fh' `"  var s=String(Math.round(x)), out='', c=0, i;"' _n
    file write `fh' `"  for(i=s.length-1;i>=0;i--){ out=s.charAt(i)+out; c++; if(c%3===0&&i>0) out=','+out; }"' _n
    file write `fh' `"  return out;"' _n
    file write `fh' `"}"' _n
    file write `fh' `"function esc(s){"' _n
    file write `fh' `"  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"function svgBars(counts,labels,hi,opts){"' _n
    file write `fh' `"  opts=opts||{};"' _n
    file write `fh' `"  var Q=String.fromCharCode(34);"' _n
    file write `fh' `"  function at(n,v){ return ' '+n+'='+Q+v+Q; }"' _n
    file write `fh' `"  var w=opts.w||940, hgt=opts.hgt||170, lstep=opts.lstep||1, showv=opts.vals||false;"' _n
    file write `fh' `"  var k=counts.length, maxc=0, i;"' _n
    file write `fh' `"  for(i=0;i<k;i++) if(counts[i]>maxc) maxc=counts[i];"' _n
    file write `fh' `"  if(maxc<=0||k===0) return '<p class="nodata">Nothing to plot for this selection.</p>';"' _n
    file write `fh' `"  var plotw=w-16, ploth=hgt-34, step=plotw/k, barw=Math.max(Math.floor(step)-2,1);"' _n
    file write `fh' `"  var s='<svg'+at('viewBox','0 0 '+w+' '+hgt)+at('width','100%')+at('xmlns','http://www.w3.org/2000/svg')+'>';"' _n
    file write `fh' `"  s+='<text'+at('x',8)+at('y',12)+at('font-size',10)+at('fill','#888')+'>max '+fmtc(maxc)+'</text>';"' _n
    file write `fh' `"  s+='<line'+at('x1',8)+at('y1',hgt-22)+at('x2',w-8)+at('y2',hgt-22)+at('stroke','#d5d9de')+'></line>';"' _n
    file write `fh' `"  for(i=0;i<k;i++){"' _n
    file write `fh' `"    var c=counts[i], hb=Math.round(c/maxc*(ploth-16));"' _n
    file write `fh' `"    if(c>0&&hb<2) hb=2;"' _n
    file write `fh' `"    var x=Math.round(8+i*step), y=hgt-22-hb;"' _n
    file write `fh' `"    var col=(hi&&hi.indexOf(i)>=0)?'#C9A227':'#002244';"' _n
    file write `fh' `"    if(c>0) s+='<rect'+at('x',x)+at('y',y)+at('width',barw)+at('height',hb)+at('fill',col)+'><title>'+fmtc(c)+'</title></rect>';"' _n
    file write `fh' `"    if(showv&&c>0) s+='<text'+at('x',x+Math.floor(barw/2))+at('y',y-4)+at('font-size',10)+at('fill','#333')+at('text-anchor','middle')+'>'+fmtc(c)+'</text>';"' _n
    file write `fh' `"    if(i%lstep===0&&labels[i]) s+='<text'+at('x',x+Math.floor(barw/2))+at('y',hgt-9)+at('font-size',9.5)+at('fill','#666')+at('text-anchor','middle')+'>'+esc(labels[i])+'</text>';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  s+='</svg>';"' _n
    file write `fh' `"  return s;"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"function settings(){"' _n
    file write `fh' `"  return {"' _n
    file write `fh' `"    resp: el('c_resp').value,"' _n
    file write `fh' `"    fs:   Math.max(1,parseInt(el('c_fs').value,10)||2),"' _n
    file write `fh' `"    burst:(parseFloat(el('c_burst').value)||33)/100,"' _n
    file write `fh' `"    minact:parseFloat(el('c_minact').value)||10,"' _n
    file write `fh' `"    n1:   parseInt(el('c_n1').value,10),"' _n
    file write `fh' `"    n2:   parseInt(el('c_n2').value,10),"' _n
    file write `fh' `"    nshare:(parseFloat(el('c_nshare').value)||25)/100,"' _n
    file write `fh' `"    churn:(parseFloat(el('c_churn').value)||20)/100,"' _n
    file write `fh' `"    z:    parseFloat(el('c_z').value)||3.5,"' _n
    file write `fh' `"    top:  Math.max(1,parseInt(el('c_top').value,10)||15)"' _n
    file write `fh' `"  };"' _n
    file write `fh' `"}"' _n
    file write `fh' `"function resetSettings(){"' _n
    file write `fh' `"  el('c_resp').value='';"' _n
    file write `fh' `"  el('c_fs').value=D.meta.fastsecs;"' _n
    file write `fh' `"  el('c_burst').value=33; el('c_minact').value=10;"' _n
    file write `fh' `"  el('c_n1').value=22; el('c_n2').value=6;"' _n
    file write `fh' `"  el('c_nshare').value=25; el('c_churn').value=20;"' _n
    file write `fh' `"  el('c_z').value=3.5; el('c_top').value=15;"' _n
    file write `fh' `"  renderAll();"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"var qSortKey='med', qSortDir=-1;"' _n
    file write `fh' `"function qSort(k){"' _n
    file write `fh' `"  if(qSortKey===k) qSortDir=-qSortDir; else { qSortKey=k; qSortDir=-1; }"' _n
    file write `fh' `"  renderQuestions();"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"function renderQuestions(){"' _n
    file write `fh' `"  var filt=(el('c_q').value||'').toLowerCase();"' _n
    file write `fh' `"  var rows=[],i;"' _n
    file write `fh' `"  for(i=0;i<D.q.length;i++) if(!filt||D.q[i].v.toLowerCase().indexOf(filt)>=0) rows.push(D.q[i]);"' _n
    file write `fh' `"  rows.sort(function(a,b){"' _n
    file write `fh' `"    var av=a[qSortKey], bv=b[qSortKey];"' _n
    file write `fh' `"    if(av===null) av=-1; if(bv===null) bv=-1;"' _n
    file write `fh' `"    if(av===bv) return a.v<b.v?-1:1;"' _n
    file write `fh' `"    return (av<bv?-1:1)*(-qSortDir);"' _n
    file write `fh' `"  });"' _n
    file write `fh' `"  var s='<tr><th class="srt" onclick="qSort(String.fromCharCode(118))">question</th>'+"' _n
    file write `fh' `"        '<th class="r srt" onclick="qSort(String.fromCharCode(110))">answers</th>'+"' _n
    file write `fh' `"        '<th class="r srt" onclick="qSort(String.fromCharCode(110,105))">interviews</th>'+"' _n
    file write `fh' `"        '<th class="r srt" onclick="qSort(String.fromCharCode(109,101,100))">median s</th>'+"' _n
    file write `fh' `"        '<th class="r srt" onclick="qSort(String.fromCharCode(112,57,48))">p90 s</th>'+"' _n
    file write `fh' `"        '<th class="r srt" onclick="qSort(String.fromCharCode(102,115,104))">fast share</th></tr>';"' _n
    file write `fh' `"  var k=Math.min(rows.length,40);"' _n
    file write `fh' `"  for(i=0;i<k;i++){"' _n
    file write `fh' `"    var q=rows[i];"' _n
    file write `fh' `"    s+='<tr><td class="mono">'+esc(q.v)+'</td><td class="r">'+fmtc(q.n)+'</td><td class="r">'+fmtc(q.ni)+"' _n
    file write `fh' `"       '</td><td class="r">'+fmt(q.med)+'</td><td class="r">'+fmt(q.p90)+'</td><td class="r">'+fmt(q.fsh,2)+'</td></tr>';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  el('t_q').innerHTML=s;"' _n
    file write `fh' `"  el('q_more').textContent = rows.length>k ? ('Showing '+k+' of '+rows.length+' questions - refine the search to see others.') : '';"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"function renderAll(){"' _n
    file write `fh' `"  var S=settings();"' _n
    file write `fh' `"  var rows=P.filterRows(D.rows,S.resp);"' _n
    file write `fh' `"  var A=P.aggregate(rows,S);"' _n
    file write `fh' `"  var scope=S.resp?('enumerator '+S.resp):'all enumerators';"' _n
    file write `fh' _n
    file write `fh' `"  el('k_started').textContent=fmtc(A.n);"' _n
    file write `fh' `"  el('k_flagged').textContent=fmtc(A.nflagged)+' ('+fmt(100*A.nflagged/Math.max(A.n,1))+'%)';"' _n
    file write `fh' `"  var acts=[],i;"' _n
    file write `fh' `"  for(i=0;i<rows.length;i++) acts.push(rows[i].act);"' _n
    file write `fh' `"  el('k_medact').textContent=fmt(P.median(acts));"' _n
    file write `fh' `"  var meds=[];"' _n
    file write `fh' `"  for(i=0;i<rows.length;i++) if(rows[i].med!==null) meds.push(rows[i].med);"' _n
    file write `fh' `"  el('k_medans').textContent=fmt(P.median(meds));"' _n
    file write `fh' _n
    file write `fh' `"  var verdict, vc;"' _n
    file write `fh' `"  if(A.nflagged===0){ verdict='No behaviour flags raised for '+scope+' at the current thresholds.'; vc='ok'; }"' _n
    file write `fh' `"  else { verdict=fmtc(A.nflagged)+' of '+fmtc(A.n)+' interviews raise at least one flag for '+scope+' - review the tables below.'; vc='warn'; }"' _n
    file write `fh' `"  el('verdict').textContent=verdict;"' _n
    file write `fh' `"  el('verdict').className='verdict '+vc;"' _n
    file write `fh' _n
    file write `fh' `"  el('ch_flags').innerHTML=svgBars(A.tot,"' _n
    file write `fh' `"    ['S speeding','B bursts','T too short','N night','C churn','Z outlier'],[],"' _n
    file write `fh' `"    {hgt:150,vals:true});"' _n
    file write `fh' _n
    file write `fh' `"  var BA=P.binsActive(rows), labA=[], hiA=[];"' _n
    file write `fh' `"  for(i=0;i<20;i++){ labA.push(String(i*BA.w)); if((i+1)*BA.w<=S.minact) hiA.push(i); }"' _n
    file write `fh' `"  el('ch_act').innerHTML=svgBars(BA.c,labA,hiA,{lstep:2});"' _n
    file write `fh' `"  el('n_act').textContent='Bins of '+BA.w+' min; gold bins fall under the '+S.minact+'-minute floor.';"' _n
    file write `fh' _n
    file write `fh' `"  var BM=P.binsMed(rows), labM=[], hiM=[];"' _n
    file write `fh' `"  for(i=0;i<21;i++){ labM.push(i<20?String(i):'20+'); if(i<S.fs) hiM.push(i); }"' _n
    file write `fh' `"  el('ch_med').innerHTML=svgBars(BM,labM,hiM,{lstep:2});"' _n
    file write `fh' `"  el('n_med').textContent='Gold bars: interviews where a typical question was answered in under '+S.fs+' seconds - too fast for a real conversation.';"' _n
    file write `fh' _n
    file write `fh' `"  var HT=P.hourTotals(rows), labH=[], hiH=[];"' _n
    file write `fh' `"  for(i=0;i<24;i++){ labH.push(String(i)); if(P.inWindow(i,S.n1,S.n2)) hiH.push(i); }"' _n
    file write `fh' `"  if(HT) el('ch_hour').innerHTML=svgBars(HT,labH,hiH,{lstep:2});"' _n
    file write `fh' `"  else el('ch_hour').innerHTML='<p class="nodata">Hour detail not embedded for this survey size.</p>';"' _n
    file write `fh' _n
    file write `fh' `"  var DT=P.dailyTotals(D.daily,S.resp), dc=[], dl=[], dstep=Math.max(1,Math.floor(DT.length/8));"' _n
    file write `fh' `"  for(i=0;i<DT.length;i++){ dc.push(DT[i].c); dl.push(i%dstep===0?DT[i].d.substring(5):''); }"' _n
    file write `fh' `"  el('ch_daily').innerHTML=svgBars(dc,dl,[],{lstep:1});"' _n
    file write `fh' _n
    file write `fh' `"  var L=P.league(rows,S), s='<tr><th>enumerator</th><th class="r">interviews</th><th class="r">med active min</th><th class="r">med sec/ans</th><th class="r">fast share</th><th class="r">night share</th><th class="r">flagged</th><th style="width:110px">flag share</th></tr>';"' _n
    file write `fh' `"  var k=Math.min(L.length,30);"' _n
    file write `fh' `"  for(i=0;i<k;i++){"' _n
    file write `fh' `"    var g=L[i];"' _n
    file write `fh' `"    s+=(g.fl>0?'<tr class="hot">':'<tr>')+'<td>'+esc(g.r)+'</td><td class="r">'+fmtc(g.n)+'</td><td class="r">'+fmt(g.medact)+"' _n
    file write `fh' `"       '</td><td class="r">'+fmt(g.medmed)+'</td><td class="r">'+fmt(g.mfsh,2)+'</td><td class="r">'+fmt(g.mnsh,2)+"' _n
    file write `fh' `"       '</td><td class="r">'+fmtc(g.fl)+'</td><td><span class="bar" style="width:'+Math.round(100*g.share)+'px"></span> '+fmt(100*g.share)+'%</td></tr>';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  el('t_league').innerHTML=s;"' _n
    file write `fh' `"  el('l_more').textContent = L.length>k ? ('Top '+k+' of '+L.length+' enumerators by workload.') : '';"' _n
    file write `fh' _n
    file write `fh' `"  s='<tr><th>interview id</th><th>enumerator</th><th>flags</th><th class="r">active min</th><th class="r">sec/ans</th><th class="r">fast</th><th class="r">night</th><th class="r">cascades</th><th class="r">wiped</th></tr>';"' _n
    file write `fh' `"  var F=A.flagged, kk=Math.min(F.length,S.top), letters=['S','B','T','N','C','Z'];"' _n
    file write `fh' `"  for(i=0;i<kk;i++){"' _n
    file write `fh' `"    var r=F[i], pat='', j;"' _n
    file write `fh' `"    for(j=0;j<6;j++) pat+=r._f[j]?letters[j]:'-';"' _n
    file write `fh' `"    s+='<tr><td class="mono">'+esc(r.id)+'</td><td>'+esc(r.r)+'</td><td class="mono" style="letter-spacing:2px">'+pat+"' _n
    file write `fh' `"       '</td><td class="r">'+fmt(r.act)+'</td><td class="r">'+fmt(r.med)+'</td><td class="r">'+fmt(P.fastShare(r,S.fs),2)+"' _n
    file write `fh' `"       '</td><td class="r">'+fmt(P.nightShare(r,S.n1,S.n2),2)+'</td><td class="r">'+r.cas+'</td><td class="r">'+r.wip+'</td></tr>';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  el('t_worst').innerHTML=s;"' _n
    file write `fh' `"  el('w_none').textContent = F.length===0 ? 'Nothing to review for this selection - no flags and no cascades.' : '';"' _n
    file write `fh' _n
    file write `fh' `"  renderQuestions();"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"function initControls(){"' _n
    file write `fh' `"  var rs={}, i, names=[];"' _n
    file write `fh' `"  for(i=0;i<D.rows.length;i++) rs[D.rows[i].r]=1;"' _n
    file write `fh' `"  for(var k in rs){ if(rs.hasOwnProperty(k)&&k!=='') names.push(k); }"' _n
    file write `fh' `"  names.sort();"' _n
    file write `fh' `"  var s='<option value="">All enumerators ('+names.length+')</option>';"' _n
    file write `fh' `"  for(i=0;i<names.length;i++) s+='<option>'+esc(names[i])+'</option>';"' _n
    file write `fh' `"  el('c_resp').innerHTML=s;"' _n
    file write `fh' `"  var hsel='';"' _n
    file write `fh' `"  for(i=0;i<24;i++) hsel+='<option>'+i+'</option>';"' _n
    file write `fh' `"  el('c_n1').innerHTML=hsel; el('c_n2').innerHTML=hsel;"' _n
    file write `fh' `"  el('c_n1').value=22; el('c_n2').value=6;"' _n
    file write `fh' `"  el('c_fs').value=D.meta.fastsecs;"' _n
    file write `fh' `"  var ids=['c_resp','c_fs','c_burst','c_minact','c_n1','c_n2','c_nshare','c_churn','c_z','c_top'];"' _n
    file write `fh' `"  for(i=0;i<ids.length;i++) el(ids[i]).addEventListener('change',renderAll);"' _n
    file write `fh' `"  el('c_q').addEventListener('input',renderQuestions);"' _n
    file write `fh' `"  el('c_reset').addEventListener('click',resetSettings);"' _n
    file write `fh' `"  if(D.meta.lite===1){"' _n
    file write `fh' `"    el('c_n1').disabled=true; el('c_n2').disabled=true; el('c_fs').disabled=true;"' _n
    file write `fh' `"    el('lite_note').textContent='Large survey: per-interview hour/gap detail was not embedded, so the night window and fast-seconds controls use the values fixed at build time.';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"}"' _n
    file write `fh' `"initControls();"' _n
    file write `fh' `"renderAll();"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"</script></body></html>"' _n
    file close `fh'

    * ---- finish: leave the combined table in memory --------------------------------
    quietly use `"`MERGED'"', clear
    sort interview__id
    local fullp `"`saving'"'
    if strpos(`"`saving'"',"/")==0 & strpos(`"`saving'"',"\")==0 local fullp `"`c(pwd)'/`saving'"'
    di as txt "suso paradata: interactive report written to " as res `"`fullp'"'
    di as txt `"               {browse "`fullp'":Click to open in your browser}"'
    di as txt "  `nstartedc' of `nintsc' records have fieldwork; `nuntouchedc' are untouched (preload-only) and shown separately."
    di as txt "  timing basis: `rolenote'."
    di as txt "  in memory: one row per record (timing + flags at defaults + cascades + started marker)."
    return local  report `"`fullp'"'
    return scalar nints    = `nints'
    return scalar nstarted = `nstarted'
    return scalar ncascades = `ncasc'
end

* ---- helper: escape text for HTML ----------------------------------------------
program _suso_para_hesc, rclass
    version 14.2
    gettoken s : 0
    return local out = subinstr(subinstr(subinstr(`"`s'"', "&", "&amp;", .), "<", "&lt;", .), ">", "&gt;", .)
end

* ---- qx: parse the questionnaire HTML that ships with every data export --------
* Extracts variable name, section, type, question text, enabling condition (the
* skip logic), validation counts/messages and answer options into a dataset.
program _suso_para_qxload, rclass
    version 14.2
    syntax , FILE(string) [ SAVing(string) replace ]
    confirm file `"`file'"'
    di as txt "suso paradata: parsing questionnaire HTML ..."
    clear
    mata: _suso_qx_parse(st_local("file"))
    if _N==0 {
        di as err "suso paradata qx: no questions found — expected the questionnaire HTML that Survey Solutions includes with every data export."
        exit 459
    }
    label variable qx_var     "variable name"
    label variable qx_section "section"
    label variable qx_type    "question type"
    label variable qx_text    "question text"
    label variable qx_enable  "enabling condition (skip logic)"
    label variable qx_nval    "number of validation rules"
    label variable qx_valmsg  "first validation message"
    label variable qx_opts    "answer options (first 8)"
    label variable qx_optvals "answer option values (first 60)"
    label variable qx_nopts   "number of answer options"
    char _dta[suso_paradata] qx
    quietly count if qx_enable!=""
    local ne = r(N)
    quietly count if qx_nval>0
    local nv = r(N)
    di as txt "suso paradata: parsed " as res _N as txt " questions ("             ///
        as res "`ne'" as txt " with skip logic, " as res "`nv'" as txt " with validations)."
    di as txt "  use it: {bf:suso paradata skips , qx(file.html)} names the questions in every violation message."
    if `"`saving'"'!="" {
        if "`replace'"=="" {
            capture confirm new file `"`saving'"'
            if _rc {
                di as err "suso: file already exists. Use -replace-."
                exit 602
            }
        }
        quietly save `"`saving'"', `replace'
        di as txt "  saved: " as res `"`saving'"'
    }
    return scalar nq = _N
end

* ---- check: evaluate skip logic and option values against the exported data ----
* Builds a codebook from the questionnaire HTML (enabling conditions, types,
* option values), translates the C# conditions to Stata where possible, and
* audits the exported microdata: answers present on disabled questions (hard
* skip violations), enabled questions left unanswered (item nonresponse), and
* single-select values outside the option list. Conditions that cannot be
* translated are reported, never guessed. C# treats a null referent as false;
* Stata treats missing as +infinity, so any condition whose numeric referents
* are unanswered is scored "cannot determine" and excluded from both counts.
program _suso_para_check, rclass
    version 14.2
    syntax , QX(string) DATA(string) [ SAVing(string) replace MISScodes(numlist) TOP(integer 10) ]
    confirm file `"`qx'"'
    confirm file `"`data'"'
    if "`misscodes'"=="" local misscodes "-999999999"

    * ---- codebook: parse questionnaire, translate conditions in expression-land --
    _suso_para_qxload , file(`"`qx'"')
    quietly gen strL c_tr = ustrregexra(qx_enable, "//[^\n]*", "")
    quietly replace c_tr = subinstr(c_tr, "&&", " & ", .)
    quietly replace c_tr = subinstr(c_tr, "||", " | ", .)
    quietly replace c_tr = ustrregexra(c_tr, "\btrue\b", "1")
    quietly replace c_tr = ustrregexra(c_tr, "\bfalse\b", "0")
    quietly replace c_tr = ustrregexra(c_tr, "\bself\b", qx_var)
    quietly replace c_tr = ustrregexra(c_tr, "!IsAnswered\(([^)]*)\)", "missing(" + char(36) + "1)")
    quietly replace c_tr = ustrregexra(c_tr, "IsAnswered\(([^)]*)\)", "!missing(" + char(36) + "1)")
    quietly replace c_tr = ustrregexra(c_tr, "([A-Za-z_][A-Za-z0-9_]*)\.Contains\(([0-9-]+)\)", ///
        char(36) + "1__" + char(36) + "2==1")
    quietly replace c_tr = strtrim(stritrim(c_tr))
    local ncb = _N
    forvalues i = 1/`ncb' {
        local v_`i'  = qx_var[`i']
        local c_`i'  = c_tr[`i']
        local t_`i'  = qx_type[`i']
        local ov_`i' = qx_optvals[`i']
        local no_`i' = qx_nopts[`i']
    }

    * ---- data: normalise SuSo sentinels so missing() means unanswered ------------
    di as txt "suso paradata: loading exported data and normalising missing codes ..."
    quietly use `"`data'"', clear
    capture confirm variable interview__id
    if _rc {
        di as err "suso paradata check: data() must be a Survey Solutions main export file (interview__id not found)."
        exit 459
    }
    local nobs = _N
    quietly ds, has(type numeric)
    foreach v of varlist `r(varlist)' {
        foreach mc of numlist `misscodes' {
            quietly replace `v' = . if `v'==`mc'
        }
    }
    quietly ds, has(type string)
    foreach v of varlist `r(varlist)' {
        quietly replace `v' = "" if `v'=="##N/A##"
    }

    * ---- audit every codebook question present in the data -----------------------
    tempname P
    tempfile RES
    postfile `P' str80 qvar str16 qstatus                                        ///
        long n_on long n_off long n_und long n_viol long n_imiss long n_bad using `"`RES'"'
    local k_eval 0
    local k_noev 0
    local k_absent 0
    local k_nocond 0
    local badlist ""
    tempvar en
    forvalues i = 1/`ncb' {
        capture confirm variable `v_`i''
        if _rc {
            local ++k_absent
            post `P' ("`v_`i''") ("not in file") (.) (.) (.) (.) (.) (.)
            continue
        }
        local isnum 1
        capture confirm numeric variable `v_`i''
        if _rc local isnum 0
        local anse = cond(`isnum', "(!missing(`v_`i''))", `"(`v_`i''!="")"')
        local nund 0
        if `"`c_`i''"'=="" {
            local ++k_nocond
            local st "always on"
            quietly count if !`anse'
            local nim = r(N)
            local non = `nobs'
            local nof 0
            local nvl 0
        }
        else {
            capture drop `en'
            capture quietly gen byte `en' = (`c_`i'')
            if _rc {
                local ++k_noev
                if `:list sizeof badlist' < 12 local badlist "`badlist' `v_`i''"
                post `P' ("`v_`i''") ("not evaluable") (.) (.) (.) (.) (.) (.)
                continue
            }
            * C#/Stata null gap: if any numeric variable the condition refers to is
            * unanswered, the condition cannot be scored - mark it undetermined
            local guard ""
            local rest `"`c_`i''"'
            local nids 0
            while (ustrregexm(`"`rest'"', "([A-Za-z_][A-Za-z0-9_]*)") & `nids'<25) {
                local id = ustrregexs(1)
                local rest = ustrregexrf(`"`rest'"', "([A-Za-z_][A-Za-z0-9_]*)", "")
                if inlist("`id'", "missing", "inlist", "inrange", "abs", "int", "floor", "ceil") continue
                if strpos(" `guard' ", " `id' ")>0 continue
                capture confirm numeric variable `id'
                if !_rc {
                    local ++nids
                    local guard "`guard' `id'"
                }
            }
            foreach g of local guard {
                quietly replace `en' = . if missing(`g')
            }
            local ++k_eval
            local st "evaluated"
            quietly count if missing(`en')
            local nund = r(N)
            quietly count if `en'==1
            local non = r(N)
            quietly count if `en'==0
            local nof = r(N)
            quietly count if `en'==0 & `anse'
            local nvl = r(N)
            quietly count if `en'==1 & !`anse'
            local nim = r(N)
        }
        local nbd 0
        if `isnum' & `no_`i''>0 & `no_`i''<=60 & strpos(lower("`t_`i''"),"single-select")>0 {
            local vl : subinstr local ov_`i' " " ",", all
            if "`vl'"!="" {
                capture quietly count if !missing(`v_`i'') & !inlist(`v_`i'', `vl')
                if !_rc local nbd = r(N)
            }
        }
        post `P' ("`v_`i''") ("`st'") (`non') (`nof') (`nund') (`nvl') (`nim') (`nbd')
    }
    postclose `P'
    quietly use `"`RES'"', clear
    quietly gen double imiss_share = n_imiss/n_on if n_on>0

    * ---- report -------------------------------------------------------------------
    quietly summarize n_viol
    local tviol = r(sum)
    quietly summarize n_imiss
    local timiss = r(sum)
    quietly summarize n_bad
    local tbad = r(sum)
    di as txt _n "{hline 72}"
    di as res "  suso paradata check" as txt "   (`nobs' records against `ncb' codebook questions)"
    di as txt "{hline 72}"
    di as txt "  conditions evaluated " as res "`k_eval'" as txt "   always-on " as res "`k_nocond'" ///
        as txt "   not evaluable " as res "`k_noev'" as txt "   not in this file " as res "`k_absent'"
    di as txt "  answers on DISABLED questions (hard skip violations) : " as res "`tviol'"
    di as txt "  enabled questions left unanswered (item nonresponse) : " as res "`timiss'"
    di as txt "  single-select values outside the option list         : " as res "`tbad'"
    tempvar sk
    if `tviol'>0 {
        quietly gen double `sk' = cond(missing(n_viol), -1, n_viol)
        gsort -`sk' qvar
        di as txt _n "  hard skip violations by question (top `top'):"
        di as txt "  {ul:variable                }  {ul:answered while off}  {ul:enabled}  {ul:disabled}"
        forvalues i = 1/`=min(`top',_N)' {
            if n_viol[`i']>0 & !missing(n_viol[`i']) {
                local vv : di %-24s abbrev(qvar[`i'],24)
                di as txt "  " as res "`vv'" as txt "  " %18.0f `=n_viol[`i']' "  " %7.0f `=n_on[`i']' "  " %8.0f `=n_off[`i']'
            }
        }
        di as txt "  these answers survived despite the skip logic (preloads, API writes,"
        di as txt "  or a questionnaire version change) - review before analysis."
        quietly drop `sk'
    }
    else di as txt _n "  no hard skip violations: the exported data respects every evaluated condition."
    quietly count if n_imiss>0 & !missing(n_imiss)
    if r(N)>0 {
        quietly gen double `sk' = cond(missing(imiss_share), -1, imiss_share)
        gsort -`sk' -n_imiss qvar
        di as txt _n "  item nonresponse where the question was enabled (top `top' by share):"
        di as txt "  {ul:variable                }  {ul:unanswered}  {ul:enabled}  {ul:share}"
        forvalues i = 1/`=min(`top',_N)' {
            if n_imiss[`i']>0 & !missing(n_imiss[`i']) {
                local vv : di %-24s abbrev(qvar[`i'],24)
                local sh : di %5.2f imiss_share[`i']
                di as txt "  " as res "`vv'" as txt "  " %10.0f `=n_imiss[`i']' "  " %7.0f `=n_on[`i']' "  `sh'"
            }
        }
        quietly drop `sk'
    }
    if `k_noev'>0 di as txt _n "  not evaluable (C# beyond the translator):`badlist'"
    di as txt _n "  complements {bf:suso paradata skips} - skips catches mid-interview gate"
    di as txt "  flips from the paradata; check audits the final exported data state."
    di as txt "  n_und = records where the condition could not be scored because a"
    di as txt "  referenced numeric question was itself unanswered (excluded from counts)."
    di as txt "  data in memory = one row per codebook question (merge/save as needed)."
    di as txt "{hline 72}"
    sort qvar
    if `"`saving'"'!="" {
        if "`replace'"=="" {
            capture confirm new file `"`saving'"'
            if _rc {
                di as err "suso: file already exists. Use -replace-."
                exit 602
            }
        }
        quietly save `"`saving'"', `replace'
        di as txt "  saved: " as res `"`saving'"'
    }
    return scalar nviol   = `tviol'
    return scalar nimiss  = `timiss'
    return scalar nbadval = `tbad'
    return scalar nevaluated = `k_eval'
    return scalar nnoteval   = `k_noev'
end

*===============================================================================
* examples — copy/paste recipes printed in the Results window
*===============================================================================
program _suso_examples
    di as txt _n "{hline 72}"
    di as res    "  suso — copy / paste recipes"
    di as txt    "  (replace the bits in <...>; clickable links run the safe ones)"
    di as txt    "{hline 72}"

    di as res _n "  1) CONNECT  (once per Stata session)"
    di as txt    "     suso config , server(<url>) workspace(<ws>) user(<apiuser>) password(<pw>)"
    di as txt    "     suso config , guid(<questionnaire-GUID>) qver(<version>)   {txt}// set your survey ONCE"
    di as txt    "     suso ping"
    di as txt    "     {stata suso doctor:suso doctor}        {txt}// check Stata + Java + settings"
    di as txt    "     Tip: set the SUSO_PASSWORD environment variable and omit password()."

    di as res _n "  2) SEE DATA  (replaces the data in memory; preserve first if needed)"
    di as txt    "     suso questionnaire list                 {txt}// find the GUID + Version"
    di as txt    "     suso assignment list , all"
    di as txt    "     suso interview list , status(Completed) all"
    di as txt    "     suso interview list , status(RejectedBySupervisor) all"
    di as txt    "     suso interview list , all                {txt}// uses your saved questionnaire"
    di as txt    "     suso interview stats   , id(<interview-uuid>)"
    di as txt    "     suso interview get     , id(<interview-uuid>)   {txt}// loads the answers"
    di as txt    "     suso interview history , id(<interview-uuid>)"

    di as res _n "  3) REVIEW  (approve / reject / comment)"
    di as txt    `"     suso interview approve , id(<uuid>) comment("looks good")"'
    di as txt    `"     suso interview reject  , id(<uuid>) comment("please revisit the GPS point")"'
    di as txt    "     suso interview hqapprove , id(<uuid>)"
    di as txt    `"     suso interview hqreject  , id(<uuid>) comment("see notes")"'
    di as txt    `"     suso interview commentbyvar , id(<uuid>) variable(d2_sales) comment("confirm units")"'

    di as res _n "  4) EXPORT + DOWNLOAD  (best way to pull large data)"
    di as txt    "     suso export start , type(STATA) istatus(ApprovedBySupervisor)"
    di as txt    "         {txt}// guid/qver come from your saved questionnaire; add guid()/qver() to override"
    local bq = char(96)
    local eq = char(39)
    di as txt    "     suso export status , id(`bq'=r(jobid)`eq')     {txt}// repeat until status=Completed"
    di as txt    `"     suso export download , id(`bq'=r(jobid)`eq') saving("ises.zip") replace"'
    di as txt    `"     suso export get , type(STATA) saving("ises.zip") unzipw("pw") unzipto("data") replace   {txt}// all of the above in one"'

    di as res _n "  5) PARADATA  (timing + behaviour QC: speeding, night work, churn)"
    di as txt    "     suso paradata get                        {txt}// export -> download -> load events"
    di as txt    `"     suso paradata load , file("para.zip")    {txt}// or reload a saved export offline"'
    di as txt    "     suso paradata flags                      {txt}// red-flag report; data = 1 row/interview"
    di as txt    "     suso paradata timing , by(question)      {txt}// slowest questions first"
    di as txt    "     suso paradata skips                      {txt}// gate flips wiping answers (skip abuse)"
    di as txt    `"     suso paradata report , saving("qc.html") replace {txt}// one-page HTML QC report"'

    di as res _n "  6) TEAM"
    di as txt    "     suso supervisor list , all"
    di as txt    "     suso supervisor interviewers , id(<supervisor-uuid>)"
    di as txt    "     suso interviewer actionslog , id(<interviewer-uuid>) start(2026-06-01) end(2026-06-17)"
    di as txt    "     suso assignment assign , id(<assignment-id>) responsible(<interviewer-login>)"

    di as res _n "  7) DANGER  (need confirmation; written to the audit log)"
    di as txt    "     suso interview delete , id(<uuid>) confirm"
    di as txt    "     suso export cancel    , id(<jobid>) confirm"
    di as txt    "     suso workspace status , name(<ws>)"
    di as txt    "     suso workspace delete , name(<ws>) iknowthis(<ws>)"

    di as txt _n "  More: {stata suso endpoints:suso endpoints}   (full command list)   |   {help suso}"
    di as txt    "{hline 72}" _n
end

*===============================================================================
* endpoints — one-screen list of every command
*===============================================================================
program _suso_endpoints
    di as txt _n "{hline 72}"
    di as res    "  suso — all commands   (questionnaires use  guid()+qver() ; ids use  id())"
    di as txt    "{hline 72}"
    di as res _n "  setup     " as txt "config | ping | doctor | examples | endpoints | about | raw"
    di as res _n "  assignment" as txt " list  get  history  quantitysettings  create  assign"
    di as txt    "             quantity  close  archive  unarchive  audio  targetarea"
    di as res _n "  interview " as txt " list  get  stats  history  pdf  approve  reject"
    di as txt    "             hqapprove  hqreject  hqunapprove  assign  assignsupervisor"
    di as txt    "             comment  commentbyvar  delete"
    di as res _n "  questionnaire" as txt " list  get  document  interviews  audio  criticality"
    di as res _n "  export    " as txt " list  start  status  download  get  cancel"
    di as res _n "  paradata  " as txt " get  load  timing  flags  skips  report  qx  check"
    di as res _n "  maps      " as txt " list  upload  delete  deleteall  assign  unassign"
    di as res _n "  user      " as txt " get  create  archive  unarchive"
    di as res    "  supervisor" as txt " list  get  interviewers"
    di as res    "  interviewer" as txt " get  actionslog"
    di as res _n "  workspace " as txt " list  get  status  create  update  enable  disable  delete  assign"
    di as res _n "  settings  " as txt " globalnotice get|set|clear"
    di as res    "  statistics" as txt " questionnaires  questions  report"
    di as res _n "  backup    " as txt " full-workspace archive (questionnaires + exports + assignments/users)"
    di as txt _n "  Recipes you can copy: {stata suso examples:suso examples}     Help: {help suso}"
    di as txt    "{hline 72}" _n
end


*===============================================================================
* Mata: questionnaire HTML parser (used by suso paradata qx / skips qx() / report qx())
*===============================================================================
version 14.2
mata:

string scalar _suso_qx_clean(string scalar t0)
{
    string scalar t
    t = ustrregexra(t0, "<[^>]*>", " ")
    t = subinstr(t, "&quot;", char(34))
    t = subinstr(t, "&#39;", "'")
    t = subinstr(t, "&#xD;", " ")
    t = subinstr(t, "&#xA;", " ")
    t = subinstr(t, "&nbsp;", " ")
    t = subinstr(t, "&lt;", "<")
    t = subinstr(t, "&gt;", ">")
    t = subinstr(t, "&amp;", "&")
    t = subinstr(t, char(10), " ")
    t = subinstr(t, char(9), " ")
    return(strtrim(stritrim(t)))
}

string colvector _suso_qx_split(string scalar s, string scalar sep)
{
    string colvector out
    string scalar rest
    real scalar j, L
    out = J(0,1,"")
    rest = s
    L = strlen(sep)
    while ((j = strpos(rest, sep)) > 0) {
        out = out \ substr(rest, 1, j-1)
        rest = substr(rest, j+L, .)
    }
    out = out \ rest
    return(out)
}

string scalar _suso_qx_lastsec(string scalar t)
{
    string scalar pat, out, rest
    pat = `"(?s)<h2[^>]*id="[0-9a-f]{32}">(.*?)</h2>"'
    out = ""
    rest = t
    while (ustrregexm(rest, pat)) {
        out = _suso_qx_clean(ustrregexs(1))
        rest = ustrregexrf(rest, pat, "")
    }
    return(out)
}

string scalar _suso_qx_resolve(string scalar t, string colvector anum, string colvector atxt)
{
    real scalar i
    string scalar num
    if (ustrregexm(strtrim(t), "^\[([0-9]+)\]$")) {
        num = ustrregexs(1)
        for (i=1; i<=rows(anum); i++) {
            if (anum[i]==num) return(atxt[i])
        }
    }
    return(t)
}

void _suso_qx_parse(string scalar fn)
{
    real scalar fh, n, k, p, nvv, nq, nopt
    string scalar s, tail, ch, cursec, v, ti, ty, en, ms, op, rest, pat
    string colvector Cvar, Csec, Cty, Cti, Cen, Cms, Cop, Cov, chunks, anum, atxt, ovals, olabs
    real colvector Cnv, Cno

    fh = fopen(fn, "r")
    fseek(fh, 0, 1)
    n = ftell(fh)
    fseek(fh, 0, -1)
    s = fread(fh, n)
    fclose(fh)
    s = subinstr(s, char(13), "")

    anum = J(0,1,""); atxt = J(0,1,"")
    n = strpos(s, `"<span class="number">["')
    if (n > 0) {
        tail = substr(s, n, .)
        pat = `"(?s)<span class="number">\[([0-9]+)\]</span>\s*<div class="appendix_detail">(.*?)</div>"'
        while (ustrregexm(tail, pat)) {
            anum = anum \ ustrregexs(1)
            atxt = atxt \ substr(_suso_qx_clean(ustrregexs(2)), 1, 500)
            tail = ustrregexrf(tail, pat, "")
        }
    }

    Cvar = Csec = Cty = Cti = Cen = Cms = Cop = Cov = J(0,1,"")
    Cnv = Cno = J(0,1,.)
    chunks = _suso_qx_split(s, `"<div class="question-container">"')
    cursec = _suso_qx_lastsec(chunks[1])
    for (k=2; k<=rows(chunks); k++) {
        ch = chunks[k]
        v = ""
        if (ustrregexm(ch, `"(?s)class="variable_name">\s*(.*?)\s*</div>"')) v = strtrim(ustrregexs(1))
        if (v != "") {
            ti = ""
            if (ustrregexm(ch, `"(?s)class="question-title"[^>]*>(.*?)</div>"')) ti = substr(_suso_qx_clean(ustrregexs(1)), 1, 800)
            ty = ""
            if (ustrregexm(ch, `"(?s)class="type">\s*(.*?)\s*</div>"')) ty = substr(_suso_qx_clean(ustrregexs(1)), 1, 60)
            en = ""
            if (ustrregexm(ch, `"(?s)class="condition"><span>E</span>(.*?)</div>"')) en = substr(_suso_qx_resolve(_suso_qx_clean(ustrregexs(1)), anum, atxt), 1, 800)
            nvv = 0
            rest = ch
            while (strpos(rest, `"class="validation-expression""') > 0) {
                nvv = nvv + 1
                rest = subinstr(rest, `"class="validation-expression""', "", 1)
            }
            ms = ""
            if (ustrregexm(ch, `"(?s)class="validation-message"><span>M[0-9]+</span>(.*?)</div>"')) ms = substr(_suso_qx_clean(ustrregexs(1)), 1, 500)
            ovals = J(0,1,""); olabs = J(0,1,"")
            rest = ch
            pat = `"(?s)class="option-value"><span ?>(.*?)</span>"'
            while (rows(ovals)<60 & ustrregexm(rest, pat)) {
                ovals = ovals \ _suso_qx_clean(ustrregexs(1))
                rest = ustrregexrf(rest, pat, "")
            }
            nopt = rows(ovals)
            while (strpos(rest, `"class="option-value""') > 0) {
                nopt = nopt + 1
                rest = subinstr(rest, `"class="option-value""', "", 1)
            }
            rest = ch
            pat = `"(?s)<label[^>]*>(.*?)</label>"'
            while (rows(olabs)<8 & ustrregexm(rest, pat)) {
                olabs = olabs \ _suso_qx_clean(ustrregexs(1))
                rest = ustrregexrf(rest, pat, "")
            }
            op = ""
            for (p=1; p<=min((rows(ovals), rows(olabs), 8)); p++) {
                op = op + (p>1 ? " | " : "") + ovals[p] + " " + olabs[p]
            }
            Cvar = Cvar \ substr(v,1,80)
            Csec = Csec \ substr(cursec,1,200)
            Cty  = Cty  \ ty
            Cti  = Cti  \ ti
            Cen  = Cen  \ en
            Cms  = Cms  \ ms
            Cop  = Cop  \ substr(op,1,800)
            Cov  = Cov  \ substr(invtokens(ovals'), 1, 800)
            Cno  = Cno  \ nopt
            Cnv  = Cnv  \ nvv
        }
        rest = _suso_qx_lastsec(ch)
        if (rest != "") cursec = rest
    }

    nq = rows(Cvar)
    if (nq == 0) return
    st_addobs(nq)
    (void) st_addvar("str80",  "qx_var")
    (void) st_addvar("str200", "qx_section")
    (void) st_addvar("str60",  "qx_type")
    (void) st_addvar("strL",   "qx_text")
    (void) st_addvar("strL",   "qx_enable")
    (void) st_addvar("int",    "qx_nval")
    (void) st_addvar("strL",   "qx_valmsg")
    (void) st_addvar("strL",   "qx_opts")
    (void) st_addvar("strL",   "qx_optvals")
    (void) st_addvar("int",    "qx_nopts")
    st_sstore(., "qx_var", Cvar)
    st_sstore(., "qx_section", Csec)
    st_sstore(., "qx_type", Cty)
    st_sstore(., "qx_text", Cti)
    st_sstore(., "qx_enable", Cen)
    st_sstore(., "qx_valmsg", Cms)
    st_sstore(., "qx_opts", Cop)
    st_sstore(., "qx_optvals", Cov)
    st_store(., "qx_nopts", Cno)
    st_store(., "qx_nval", Cnv)
}

end
