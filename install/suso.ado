*! suso v1.7.12 build 2026-08-13-RUNKEYMISSFIX  (missing run-key fix plus prior audit corrections; see help)
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
    real scalar i, c
    string scalar out, ch, hex
    out = ""
    hex = "0123456789ABCDEF"
    for (i=1; i<=strlen(s); i++) {
        ch = substr(s,i,1)
        c = ascii(ch)
        if      (c==34) out = out + "\" + char(34)
        else if (c==92) out = out + "\\"
        else if (c==8)  out = out + "\b"
        else if (c==9)  out = out + "\t"
        else if (c==10) out = out + "\n"
        else if (c==12) out = out + "\f"
        else if (c==13) out = out + "\r"
        else if (c<32)  out = out + "\u00" + substr(hex,floor(c/16)+1,1) + ///
            substr(hex,mod(c,16)+1,1)
        else            out = out + ch
    }
    return(out)
}
end

*===============================================================================
* Router
*===============================================================================
program suso, rclass
    version 14.2
    * Every routed command starts with a clean request body. Callers that need a
    * body set it after their syntax/validation checks.
    capture macro drop SUSO_BODY_REQ
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
            return add
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

    if "`insecure'"!="" & "`noinsecure'"!="" {
        di as err "suso config: specify only one of insecure or noinsecure."
        exit 198
    }

    if "`clear'"!="" {
        capture macro drop SUSO_BASE SUSO_WS SUSO_USER SUSO_PWD SUSO_TOKEN          ///
            SUSO_AUTHTYPE SUSO_PROXYHOST SUSO_PROXYPORT SUSO_PROXYUSER SUSO_PROXYPWD ///
            SUSO_INSECURE SUSO_CONNTO SUSO_READTO SUSO_MAXROWS SUSO_AUDIT            ///
            SUSO_GUID SUSO_QVER SUSO_EXPORTPWD SUSO_JAR
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
    * These options and the Java backend both use milliseconds. Do not scale
    * them again here (older builds accidentally multiplied them by 1,000).
    if `conntimeout'>0   global SUSO_CONNTO  "`conntimeout'"
    if `readtimeout'>0   global SUSO_READTO  "`readtimeout'"
    if `maxrows'>0       global SUSO_MAXROWS "`maxrows'"
    if "`auditfile'"!="" global SUSO_AUDIT   "`auditfile'"
    if "`guid'"!=""      global SUSO_GUID    "`guid'"
    if `qver'>0          global SUSO_QVER    "`qver'"
    if `"`exportpw'"'!="" global SUSO_EXPORTPWD `"`exportpw'"'   // export-archive password

    _suso_init

    if "`insecure'"!="" {
        di as err "suso: WARNING — TLS certificate-chain verification is DISABLED for this session."
        di as err "      Hostname matching remains enabled; this mode is scoped to suso's HTTP client."
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
    di as txt "  TLS chain   : " as res cond("$SUSO_INSECURE"=="1","DISABLED (hostname still checked)","verified")
    di as txt "  timeouts ms : " as res "connect=$SUSO_CONNTO  read=$SUSO_READTO"
    di as txt "  max rows    : " as res "$SUSO_MAXROWS"
    local af "$SUSO_AUDIT"
    if "`af'"=="" local af "`c(sysdir_personal)'suso_audit.log"
    di as txt "  audit log   : " as res `"`af'"'
    di as txt "{hline 62}"
end

program _suso_about, rclass
    di as txt _n "{hline 66}"
    di as txt "  suso  v1.7.12 (build 2026-08-13-RUNKEYMISSFIX)  —  Survey Solutions REST API client for Stata"
    di as txt "{hline 66}"
    di as txt "  Author       : Attique Ur Rehman, Economist, The World Bank"
    di as txt "                 Development Economics (DEC) · Enterprise Surveys"
    di as txt "  Email        : attique@worldbank.org"
    di as txt "  Web          : https://sites.google.com/view/attique-ur-rehman"
    di as txt "{hline 66}"
    di as txt "  Java backend : suso.jar (requires a Java 11+ runtime)"
    di as txt "  Help         : {help suso}        Diagnostics: {stata suso doctor:suso doctor}"
    di as txt "{hline 66}"
    return local version "1.7.12"
    return local build "2026-08-13-RUNKEYMISSFIX"
    return local expected_backend "1.7.11-AUDITFIX"
end

*===============================================================================
* Diagnostics
*===============================================================================
program _suso_doctor, rclass
    version 14.2
    syntax [, STRICT]
    local ok 1
    local backend ""
    local javaver ""
    di as txt _n "{hline 62}"
    di as txt "suso doctor — environment check"
    di as txt "{hline 62}"
    di as txt "Stata"
    di as txt "  ado code build : " as res "1.7.12-RUNKEYMISSFIX"
    di as txt "  version       : " as res "`c(flavor)' `c(stata_version)'"
    di as txt "  sysdir PLUS   : " as res "`c(sysdir_plus)'"
    di as txt "  sysdir PERSON : " as res "`c(sysdir_personal)'"

    di as txt "Java backend"
    capture _suso_jar
    if _rc {
        local ok 0
        di as err "  suso.jar      : NOT FOUND — put it on the adopath or set -suso config , jar(...)-"
    }
    else {
        di as txt "  suso.jar      : " as res "$SUSO_JAR"
        capture noisily javacall org.worldbank.suso.Stata jvm , classpath("$SUSO_JAR")
        if _rc {
            local ok 0
            di as err "  javacall      : FAILED (rc=`=_rc') — is Java available to Stata? See {help java}."
        }
        else if "$SUSO_JAVAOK"=="1" {
            local backend "$SUSO_JARBUILD"
            local javaver "$SUSO_JAVAVER"
            di as txt "  Java 11+      : " as res "yes  ($SUSO_JAVAVER)"
            di as txt "  backend build : " as res cond("$SUSO_JARBUILD"=="","(not reported)","$SUSO_JARBUILD")
            if "$SUSO_JARBUILD"!="1.7.11-AUDITFIX" {
                local ok 0
                di as err "  WARNING       : suso.ado and suso.jar are from different builds."
                di as err "                  Reinstall both files from the same v1.7.12 package, then restart Stata."
            }
        }
        else {
            local ok 0
            local javaver "$SUSO_JAVAVER"
            di as err "  Java 11+      : NO ($SUSO_JAVAVER) — PATCH operations require Java 11 or newer."
        }
    }
    _suso_showconfig
    return scalar ok = `ok'
    return local ado_build "1.7.12-RUNKEYMISSFIX"
    return local backend_build "`backend'"
    return local java_version "`javaver'"
    capture macro drop SUSO_JAVAVER SUSO_JAVAOK SUSO_JARBUILD
    if "`strict'"!="" & !`ok' exit 459
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
    tempfile __suso_prior_gql
    local __suso_hadprior 0
    if "`todata'"!="" {
        capture quietly save `"`__suso_prior_gql'"'
        if !_rc local __suso_hadprior 1
        clear
    }
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
        if `__suso_hadprior' capture quietly use `"`__suso_prior_gql'"', clear
        di as err "suso: the Java call failed (Stata rc=`jrc'). See:  suso doctor"
        exit `jrc'
    }
    if "`rc'"=="" {
        if `__suso_hadprior' capture quietly use `"`__suso_prior_gql'"', clear
        di as err "suso: no response from the Java backend."
        exit 459
    }
    if "`rc'"!="0" {
        if `__suso_hadprior' capture quietly use `"`__suso_prior_gql'"', clear
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
            if "`tag'"=="" local tag "questionnaire"
            if length(`"`tag'"') > 40 local tag = substr(`"`tag'"',1,40)
            local gid = lower(subinstr("`guid'","-","",.))
            * The GUID makes filenames collision-proof when titles/versions match.
            local stub "`tag'_`gid'_v`ver'"

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
        * 1) Prefer the JAR installed beside the ado that Stata actually loaded.
        * This avoids pairing a new ado with a duplicate, stale backend.
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
        * 2) anywhere else on the adopath
        capture findfile suso.jar
        if !_rc global SUSO_JAR "`r(fn)'"
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

    tempfile __suso_prior_data
    local __suso_hadprior 0
    if "`todata'"!="" {
        capture quietly save `"`__suso_prior_data'"'
        if !_rc local __suso_hadprior 1
        clear
    }

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
        if `__suso_hadprior' capture quietly use `"`__suso_prior_data'"', clear
        _suso_clearbridge
        di as err "suso: the Java call failed (Stata rc=`jrc')."
        di as err "      Check suso.jar and that Stata runs Java 11+ :  suso doctor"
        exit `jrc'
    }
    if "`rc'"=="" {
        if `__suso_hadprior' capture quietly use `"`__suso_prior_data'"', clear
        _suso_clearbridge
        di as err "suso: no response from the Java backend (it may not have executed)."
        exit 459
    }
    if "`rc'"!="0" {
        if `__suso_hadprior' capture quietly use `"`__suso_prior_data'"', clear
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
        quietly gen double `t' = clock(subinstr(substr(`v',1,23),"T"," ",1), "YMDhms")
        quietly replace `t' = clock(subinstr(substr(`v',1,19),"T"," ",1), "YMDhms") ///
            if missing(`t') & `v'!=""
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
    else if `page'>=0    local pos = `page'
    else if `offset'>=0  local pos = `offset'
    else                 local pos = 1

    local maxrows = real("$SUSO_MAXROWS")
    if `maxrows'<=0 local maxrows 100000

    tempfile acc __suso_getall_prior
    local __suso_hadprior 0
    capture quietly save `"`__suso_getall_prior'"'
    if !_rc local __suso_hadprior 1
    local got 0
    local total .
    local first 1

    while (1) {
        local q "`baseq'"
        if "`q'"!="" local q "`q'&"
        local q "`q'`pageparam'=`pos'&`sizeparam'=`size'"

        capture noisily _suso_call , method(GET) path(`path') query(`q') todata ///
            arraykey(`arraykey') `rootopt' `vopt'
        if _rc {
            local callrc = _rc
            if `__suso_hadprior' capture quietly use `"`__suso_getall_prior'"', clear
            else clear
            exit `callrc'
        }
        local n = r(nobs)
        if "`n'"=="" local n 0
        if !missing(r(totalcount)) local total = r(totalcount)

        * A valid empty response has no variables, so there is no first page to
        * save as an accumulator. Return the empty dataset cleanly.
        if `first' & `n'==0 {
            return scalar nobs = 0
            if !missing(`total') return scalar totalcount = `total'
            exit
        }

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
                local arc = _rc
                di as err "suso: pagination failed because column types differ across pages."
                di as err "      No partial result is being returned (append rc=`arc')."
                if `__suso_hadprior' capture quietly use `"`__suso_getall_prior'"', clear
                else clear
                exit 459
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
        BODY(string) ROOT ALLOWdestructive VERBOSE REPLACE ]
    if "`method'"=="" local method GET
    local method = strupper(strtrim("`method'"))
    if `"`body'"'!="" global SUSO_BODY_REQ `"`body'"'
    local allowopt = cond("`allowdestructive'"!="","allow","")
    * DELETE is destructive independently of whether permission was granted.
    local destopt  = cond("`method'"=="DELETE","destructive","")
    local rootopt  = cond("`root'"!="","root","")
    local vopt     = cond("`verbose'"!="","verbose","")
    local todopt   = cond("`todata'"!="","todata","")
    if `"`savefile'"'!="" & "`replace'"=="" {
        capture confirm file `"`savefile'"'
        if !_rc {
            di as err `"suso raw: savefile already exists: `savefile'"'
            di as err "          Re-run with replace to overwrite it."
            exit 602
        }
    }
    _suso_call , method(`method') path(`path') query(`query') ct(`ctype') acc(`accept') ///
        `todopt' arraykey(`arraykey') savefile(`savefile') `rootopt' `destopt' `allowopt' `vopt'
    if "`method'"=="DELETE" {
        _suso_audit , action("raw DELETE") target(`"`path'"') http("`r(http)'")
    }
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
        if "`on'"!="" & "`off'"!="" {
            di as err "suso: specify only one of -on- or -off-."
            exit 198
        }
        if "`on'"=="" & "`off'"=="" {
            _suso_call , method(GET) path(/api/v1/assignments/`id'/recordAudio) `verbose'
            di as txt "Assignment `id': audio recording Enabled=" as res `"`r(enabled)'"'
            return add
            exit
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
            _suso_jsonesc `"`rnm'"'
            global SUSO_BODY_REQ `"{"ResponsibleName":"`r(js)'"}"'
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
        if ("`on'"!="" & "`off'"!="") | ("`get'"!="" & ("`on'"!="" | "`off'"!="")) {
            di as err "suso: use get, on, or off — only one at a time."
            exit 198
        }
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
        syntax [, CONFIRM VERBOSE]
        _suso_block , action("Clear the workspace-wide global notice") `confirm'
        _suso_call , method(DELETE) path(/api/v1/settings/globalnotice) ///
            destructive allow `verbose'
        _suso_audit , action("settings globalnotice clear") ///
            target("$SUSO_WS") http("`r(http)'")
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
*   suso paradata skips    historical AnswerRemoved runs + final-state review
*   suso paradata report   one-page self-contained HTML QC report with figures
*   suso paradata qx       parse the exported questionnaire HTML (text, skips, validations)
*   suso paradata check    evaluate the skip logic + option values against exported data
*   suso paradata suite    all three QC pages (behaviour, skip review, data QC) in one tabbed HTML
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
    if inlist("`verb'","flag","quality","anomalies")           local verb flags
    if inlist("`verb'","skip","skipcheck","gates","cascades") local verb skips
    if inlist("`verb'","html","dashboard","qc")               local verb report
    if inlist("`verb'","questionnaire","instrument")           local verb qx
    if inlist("`verb'","skiplogic","datacheck","codebook")      local verb check
    if inlist("`verb'","all","combined","onepage")               local verb suite

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
    if "`verb'"=="suite" {
        _suso_para_suite `macval(0)'
        return add
        exit
    }
    di as err "suso paradata: action must be get, load, timing, flags, skips, report, qx, check or suite.  See {help suso##paradata:help suso}."
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
    if "`reduced'"!="" {
        char _dta[suso_paradata_reduced] 1
        di as err "suso paradata: reduced export loaded. Omitted enable/validity events can"
        di as err "                 change adjacency and timing context; prefer full paradata for QC."
    }
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
    di as txt "    {bf:suso paradata skips}    historical AnswerRemoved runs, nearby/linked answer variables, and final-state review"
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

    capture confirm string variable interview__id
    if _rc {
        di as err "suso paradata: no string interview__id column — this does not look like a Survey Solutions paradata file."
        exit 459
    }
    quietly count if strtrim(interview__id)==""
    if r(N)>0 {
        local nblank = r(N)
        di as err "suso paradata: `nblank' event row(s) have a missing/blank interview__id."
        di as err "                 Repair or remove those source rows before running paradata QC."
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
    quietly replace para_ord = para_seq if missing(para_ord)
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
        * Official paradata timestamps include milliseconds. Preserve the first
        * three fractional digits; the whole-second fallback supports old files.
        quietly gen double para_ts = clock(subinstr(substr(`tsvar',1,23),"T"," ",1), "YMDhms")
        quietly replace para_ts = clock(subinstr(substr(`tsvar',1,19),"T"," ",1), "YMDhms") ///
            if missing(para_ts) & `tsvar'!=""
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
    quietly gen byte para_vset = (para_ev=="variableset")
    quietly gen byte para_ven  = (para_ev=="variableenabled")
    quietly gen byte para_vdis = (para_ev=="variabledisabled")
    label variable para_ev  "paradata: event (lowercase)"
    label variable para_ans "AnswerSet"
    label variable para_rem "AnswerRemoved"
    label variable para_inv "declared invalid"
    label variable para_cmp "Completed"
    label variable para_rst "Restarted"
    label variable para_rej "Rejected (SV/HQ)"
    label variable para_pau "Paused"
    label variable para_vset "VariableSet"
    label variable para_ven  "VariableEnabled"
    label variable para_vdis "VariableDisabled"

    * Parse event parameters into variable, answer value and optional roster
    * address. Official SuSo formats are:
    *   AnswerSet     varname||value||OptionalRosterAddress
    *   AnswerRemoved varname||OptionalRosterAddress
    *   Variable*     varname||value||OptionalRosterAddress
    * The question-instance key prevents values from different roster rows from
    * being combined when reconstructing an exact answer transition.
    capture confirm string variable parameters
    if !_rc {
        tempvar pc quoted p1 rest p2 isqevent
        quietly gen strL `pc' = parameters
        quietly gen byte `quoted' = substr(`pc',1,1)==char(34) & ///
            substr(`pc',length(`pc'),1)==char(34) & length(`pc')>=2
        quietly replace `pc' = substr(`pc',2,length(`pc')-2) if `quoted'
        quietly replace `pc' = substr(`pc',2,.) if substr(`pc',1,1)==char(34)
        quietly gen long `p1' = strpos(`pc', "||")
        quietly gen strL `rest' = substr(`pc',`p1'+2,.) if `p1'>0
        quietly gen long `p2' = strpos(`rest', "||") if `p1'>0
        quietly gen byte `isqevent' = para_ans | para_rem | para_inv | ///
            strpos(para_ev,"declaredvalid")>0 | para_ev=="commentset" | ///
            para_vset | para_ven | para_vdis

        quietly gen str80 para_var = cond(`p1'>0, substr(`pc',1,`p1'-1), `pc') ///
            if `isqevent'
        quietly gen strL para_val = ""
        quietly replace para_val = cond(`p2'>0, substr(`rest',1,`p2'-1), `rest') ///
            if (para_ans | para_vset | para_ven | para_vdis) & `p1'>0

        quietly gen str160 para_roster = ""
        quietly replace para_roster = substr(`rest',`p2'+2,160) ///
            if (para_ans | para_vset | para_ven | para_vdis) & `p2'>0
        quietly replace para_roster = substr(`rest',1,160) ///
            if (para_rem | para_inv | strpos(para_ev,"declaredvalid")>0) & `p1'>0
        quietly replace para_roster = substr(`rest',`p2'+2,160) ///
            if para_ev=="commentset" & `p2'>0
        quietly replace para_roster = strtrim(para_roster)
        quietly replace para_roster = substr(para_roster,1,length(para_roster)-1) ///
            if length(para_roster)>0 & substr(para_roster,-1,1)==char(34)

        quietly gen str244 para_qkey = substr(para_var + ///
            cond(para_roster!="", "||" + para_roster, ""), 1, 244) ///
            if para_var!=""
        quietly gen str244 para_qdisp = substr(para_var + ///
            cond(para_roster!="", " [roster " + para_roster + "]", ""), 1, 244) ///
            if para_var!=""

        label variable para_var    "paradata: question variable"
        label variable para_val    "paradata: answer/calculated-variable value"
        label variable para_roster "paradata: optional roster address"
        label variable para_qkey   "paradata: question-instance key"
        label variable para_qdisp  "paradata: question instance (display)"
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
    if "`kind'"=="events" & `"`: char _dta[suso_paradata_reduced]'"'=="1" {
        di as err "suso paradata: WARNING — this is a reduced export; some event context is absent."
    }
    * self-heal: a crashed earlier run can leave temp-named columns behind; a later
    * -tempvar- may be issued the same name and its -gen- would then fail with r(110)
    capture quietly ds __0*
    if !_rc {
        if "`r(varlist)'"!="" quietly drop `r(varlist)'
    }
end

* ---- varsel: restrict answer-level events to selected variables ---------------
* Keeps structural events (sessions, completions, workflow) so timing and status
* derivation stay intact; answer/removal/comment events survive only when the
* variable matches one of the (wildcard-capable) patterns in vars().
program _suso_para_varsel, rclass
    version 14.2
    syntax [, VARS(string) ]
    if `"`vars'"'=="" exit
    capture confirm variable para_var
    if _rc {
        di as txt "  vars(): the paradata has no variable names (parameters column absent) - option ignored."
        exit
    }
    tempvar kev
    quietly gen byte `kev' = !(para_ans | para_rem | para_ev=="commentset")
    foreach p of local vars {
        quietly replace `kev' = 1 if (para_ans | para_rem | para_ev=="commentset") & strmatch(para_var, "`p'")
    }
    quietly count if `kev' & para_ans
    local na = r(N)
    quietly keep if `kev'
    quietly drop `kev'
    di as txt "  vars(): analysis restricted to " as res "`na'" as txt " answer events on the selected variables (`vars')."
    di as txt "  structural events kept; interviews with no selected-variable activity may drop from the started count."
    return scalar nanskept = `na'
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
    capture drop para_ivw para_resp para_gap para_prevp para_prevcmp para_brk   ///
        para_act para_ansgap para_fast para_night para_tivw para_one            ///
        para_preload para_fieldans para_fieldrem para_fieldcmp para_fieldrst

    * Interviewer-role detection. Map the documented labels/codes directly so
    * a Supervisor/HQ/API-only extract can never become interviewer traffic.
    * For genuinely unknown legacy codes only, use Completed events as fallback.
    local rolenote "all roles (no role column)"
    quietly gen byte para_ivw = 1
    capture confirm variable role
    if !_rc & "`allroles'"=="" {
        capture confirm string variable role
        if !_rc quietly gen para_role = lower(strtrim(role))
        else    quietly gen para_role = lower(strtrim(strofreal(role,"%18.0g")))
        tempvar knownrole
        quietly gen byte `knownrole' = inlist(para_role,"interviewer","1",      ///
            "supervisor","2","headquarter","headquarters","3") |            ///
            inlist(para_role,"administrator","4","api","api user","5","0")
        quietly count if `knownrole'
        if r(N)>0 {
            quietly replace para_ivw = inlist(para_role,"interviewer","1")
            local rolenote "Interviewer-role events (documented role mapping)"
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
            if "`rcode'"!="" {
                quietly replace para_ivw = (para_role=="`rcode'")
                local rolenote `"interviewer role inferred as legacy code `rcode' (modal role on Completed events)"'
            }
            else {
                quietly replace para_ivw = 0
                local rolenote "no interviewer role found"
            }
        }
    }
    if "`allroles'"!="" local rolenote "all roles (allroles)"

    * CAPI preload values arrive as AnswerSet events at InterviewCreated time,
    * before the tablet's first field session. Keep them in history/final-state
    * reconstruction, but exclude them from interviewer behaviour metrics.
    tempvar created firststart
    quietly egen double `created' = min(cond(para_ev=="interviewcreated",para_tsu,.)), ///
        by(interview__id)
    quietly egen double `firststart' = min(cond(inlist(para_ev,"resumed",       ///
        "restarted","receivedbyinterviewer"),para_ord,.)), by(interview__id)
    quietly gen byte para_preload = para_ans & para_ivw & !missing(`created') & ///
        para_tsu==`created' & (missing(`firststart') | para_ord<`firststart')
    quietly gen byte para_fieldans = para_ans & para_ivw & !para_preload
    quietly gen byte para_fieldrem = para_rem & para_ivw
    quietly gen byte para_fieldcmp = para_cmp & para_ivw
    quietly gen byte para_fieldrst = para_rst & para_ivw
    label variable para_preload  "initial CAPI preload AnswerSet"
    label variable para_fieldans "interviewer AnswerSet (preload excluded)"
    label variable para_fieldrem "interviewer AnswerRemoved"
    label variable para_fieldcmp "interviewer Completed"
    label variable para_fieldrst "interviewer Restarted"

    * responsible: at the last answer event, else at the last event
    quietly gen str244 para_resp = ""
    capture confirm string variable responsible
    if !_rc {
        tempvar resppri
        quietly gen byte `resppri' = para_ivw + para_fieldans
        quietly bysort interview__id (`resppri' para_ord para_seq): ///
            replace para_resp = responsible[_N]
    }

    * gaps within the interviewer-role event stream of each interview
    quietly bysort interview__id para_ivw (para_ord para_seq): ///
        gen double para_gap = (para_tsu - para_tsu[_n-1])/1000 if para_ivw & _n>1
    quietly replace para_gap = 0 if para_gap<0                       // clock skew
    quietly bysort interview__id para_ivw (para_ord para_seq): ///
        gen byte para_prevp = (para_pau[_n-1]==1) if para_ivw & _n>1
    quietly replace para_prevp = 0 if missing(para_prevp)
    quietly bysort interview__id para_ivw (para_ord para_seq): ///
        gen byte para_prevcmp = (para_cmp[_n-1]==1) if para_ivw & _n>1
    quietly replace para_prevcmp = 0 if missing(para_prevcmp)

    * Only a productive/current work event can open a session. A trailing Paused
    * event after Completed is terminal bookkeeping, not a phantom new session.
    tempvar canwork cumwork
    quietly gen byte `canwork' = para_ivw & (para_fieldans | para_fieldrem |  ///
        para_inv | inlist(para_ev,"resumed","restarted",                    ///
        "receivedbyinterviewer"))
    quietly bysort interview__id (para_ord para_seq): gen long `cumwork' = sum(`canwork')
    quietly gen byte para_brk = para_ivw & `canwork' & (`cumwork'==1 |       ///
        (!missing(para_gap) & (para_prevp | para_prevcmp |                  ///
        inlist(para_ev,"resumed","restarted","receivedbyinterviewer") |   ///
        para_gap>`gapsecs')))
    quietly gen double para_act = cond(para_ivw & !missing(para_gap), ///
        cond(para_prevp | para_prevcmp | inlist(para_ev,"resumed", ///
        "restarted","receivedbyinterviewer"),0,min(para_gap,`gapsecs')),0)
    quietly gen double para_ansgap = para_gap if para_fieldans & !para_brk &    ///
        !missing(para_gap)
    * a repeat AnswerSet on the same variable (multi-select taps, list items,
    * immediate revisions) is not a newly reached question - keep it out of the
    * answer-speed clock so tapping through a checklist cannot look like speeding
    capture confirm variable para_var
    if !_rc {
        local __akey para_var
        capture confirm variable para_qkey
        if !_rc local __akey para_qkey
        tempvar sameav lastav prevav
        quietly gen `sameav' = `__akey' if para_fieldans
        quietly bysort interview__id para_ivw (para_ord para_seq): gen `lastav' = `sameav'
        quietly by interview__id para_ivw: replace `lastav' = `lastav'[_n-1] if `lastav'=="" & _n>1
        quietly by interview__id para_ivw: gen `prevav' = `lastav'[_n-1] if _n>1
        quietly replace para_ansgap = . if para_fieldans & `__akey'!="" & `prevav'==`__akey'
        quietly drop `sameav' `lastav' `prevav'
    }
    quietly gen byte   para_fast   = (para_ansgap<`fastsecs') if !missing(para_ansgap)
    quietly gen byte   para_night  = para_fieldans & !missing(para_tsl) & ///
                                     (hh(para_tsl)>=22 | hh(para_tsl)<6)
    quietly gen double para_tivw   = para_tsu if para_ivw
    quietly gen byte   para_one    = 1
    return local rolenote `"`rolenote'"'
end

* ---- timing: events in memory  ->  one row per interview / question / interviewer
program _suso_para_timing, rclass
    version 14.2
    syntax [, BY(string) GAPMins(real 30) FASTsecs(real 2) ALLRoles VARS(string) ]
    _suso_para_need events
    _suso_para_varsel , vars(`"`vars'"')

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
        quietly keep if para_fieldans & para_var!=""
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
        collapse (sum) n_interviews=`tag' n_events=para_one n_answers=para_fieldans  ///
            n_removed=para_fieldrem active_s=para_act n_fast=para_fast n_night=para_night ///
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
    collapse (sum) n_events=para_one n_answers=para_fieldans n_removed=para_fieldrem ///
        n_answers_all=para_ans n_removed_all=para_rem n_preload=para_preload         ///
        n_invalid=para_inv n_completed=para_fieldcmp n_restarted=para_fieldrst     ///
        n_completed_all=para_cmp n_restarted_all=para_rst                          ///
        n_rejected=para_rej n_breaks=para_brk active_s=para_act                     ///
        n_fast=para_fast n_night=para_night                                         ///
        (count) n_timed=para_ansgap                                                 ///
        (p50) ans_med_s=para_ansgap (p90) ans_p90_s=para_ansgap                     ///
        (min) t_first=para_tsu ti0=para_tivw (max) t_last=para_tsu ti1=para_tivw    ///
        (first) responsible=para_resp, by(interview__id) fast

    quietly gen double active_min  = active_s/60
    quietly gen double span_min    = cond(!missing(ti0), (ti1-ti0)/60000, (t_last-t_first)/60000)
    quietly gen byte started = (n_answers>0 | n_removed>0 | n_completed>0 | n_restarted>0)
    * Session-start events themselves are boundaries; the first one is session
    * one, not a break plus an extra phantom session.
    quietly gen double sessions = cond(started,max(1,n_breaks),0)
    quietly gen double fast_share  = n_fast/n_timed    if n_timed>0
    quietly gen double night_share = n_night/n_answers if n_answers>0
    quietly gen double churn       = n_removed/max(n_answers,1)
    quietly gen double pace_apm    = n_answers/active_min if active_min>0
    quietly drop active_s ti0 ti1 n_breaks n_fast n_night

    format t_first t_last %tcCCYY-NN-DD_HH:MM:SS
    format active_min span_min ans_med_s ans_p90_s pace_apm %9.1f
    format fast_share night_share churn %5.2f
    label variable interview__id "interview id"
    label variable responsible   "interviewer (at last answer)"
    label variable n_events      "paradata events"
    label variable n_answers     "interviewer AnswerSet (preload excluded)"
    label variable n_removed     "interviewer AnswerRemoved"
    label variable n_answers_all "AnswerSet events (all roles, incl. preload)"
    label variable n_removed_all "AnswerRemoved events (all roles)"
    label variable n_preload     "initial preload AnswerSet events"
    label variable n_invalid     "validation-error events"
    label variable n_completed   "Completed events"
    label variable n_restarted   "Restarted events"
    label variable n_completed_all "Completed events (all roles)"
    label variable n_restarted_all "Restarted events (all roles)"
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
    order interview__id responsible started n_events n_answers n_removed n_preload          ///
        n_answers_all n_removed_all n_invalid                                      ///
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
    quietly gen byte f_speed = !missing(ans_med_s)  & ans_med_s  < `fastsecs' & n_timed>=10
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
    label variable f_speed   "median sec/answer < `fastsecs' (10+ timed answers)"
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

* ---- final-data adjudication for affected question instances -----------------
* Input using-file: one row per interview x removal-run x question instance.
* Output: exact final-data state and effective enablement classification.
program _suso_para_casefinal, rclass
    version 14.2
    syntax using/ , DATA(string) SAVing(string) [ QXMETA(string) ]
    confirm file `"`using'"'
    confirm file `"`data'"'

    tempfile CASES IDS FD META ACC VC ONE
    quietly use `"`using'"', clear
    foreach v in interview__id sk_run affected_var affected_roster affected_qkey affected_qdisp {
        capture confirm variable `v', exact
        if _rc {
            di as err "suso paradata: internal final-data check is missing `v'."
            exit 459
        }
    }
    quietly save `"`CASES'"'

    preserve
        quietly keep interview__id
        quietly duplicates drop
        quietly save `"`IDS'"'
    restore

    * Restrict the final export to interviews that appear in the removal cases.
    quietly use `"`data'"', clear
    capture confirm string variable interview__id
    if _rc {
        di as err "suso paradata skips: data() must contain string interview__id."
        exit 459
    }
    quietly merge m:1 interview__id using `"`IDS'"', keep(match) nogenerate
    tempvar __dup
    quietly bysort interview__id: gen byte `__dup' = _N>1
    quietly count if `__dup'
    if r(N)>0 {
        di as txt "  data(): duplicate interview__id rows found; using the first row per interview for the main-export final-state check."
        quietly bysort interview__id: keep if _n==1
    }
    quietly drop `__dup'
    quietly save `"`FD'"'

    * Merge inherited questionnaire conditions onto every affected variable.
    quietly use `"`CASES'"', clear
    if `"`qxmeta'"'!="" {
        preserve
            quietly use `"`qxmeta'"', clear
            quietly keep qx_var qx_type qx_section qx_subsection qx_section_enable ///
                qx_group_enable qx_item_enable qx_enable qx_enable_deps          ///
                qx_calc qx_section_tri qx_group_tri qx_item_tri
            quietly bysort qx_var: keep if _n==1
            quietly rename qx_var affected_var
            quietly gen byte qx_known = 1
            quietly save `"`META'"'
        restore
        quietly merge m:1 affected_var using `"`META'"', keep(master match) nogenerate
    }
    capture confirm variable qx_known
    if _rc quietly gen byte qx_known = 0
    foreach v in qx_type qx_section qx_subsection qx_section_enable qx_group_enable ///
        qx_item_enable qx_enable qx_enable_deps qx_calc qx_section_tri            ///
        qx_group_tri qx_item_tri {
        capture confirm variable `v', exact
        if _rc quietly gen strL `v' = ""
    }
    quietly replace qx_known = 0 if missing(qx_known)
    quietly save `"`CASES'"', replace
    quietly levelsof affected_var, local(avars) clean

    * Empty accumulator with the same identifying fields.
    quietly use `"`CASES'"', clear
    quietly keep if 0
    quietly gen byte final_status = .
    quietly gen byte final_answered = .
    quietly gen byte final_enabled = .
    quietly gen double final_enable_tri = .
    quietly gen strL final_note = ""
    quietly save `"`ACC'"', replace

    foreach v of local avars {
        quietly use `"`CASES'"', clear
        quietly keep if affected_var=="`v'"
        if _N==0 continue
        local qknown = qx_known[1]
        local secraw `"`=qx_section_enable[1]'"'
        local grpraw `"`=qx_group_enable[1]'"'
        local itemraw `"`=qx_item_enable[1]'"'
        local secexpr `"`=qx_section_tri[1]'"'
        local grpexpr `"`=qx_group_tri[1]'"'
        local itemexpr `"`=qx_item_tri[1]'"'
        local qtype `"`=lower(qx_type[1])'"'
        local ismulti = strpos(`"`qtype'"',"multi")>0 | strpos(`"`qtype'"',"multy")>0
        local isyesno = strpos(`"`qtype'"',"yes/no")>0 | strpos(`"`qtype'"',"yesno")>0
        local iscombo = strpos(`"`qtype'"',"combo")>0
        local isordered = strpos(`"`qtype'"',"ordered")>0 | strpos(`"`qtype'"',"rank")>0

        * Roster instances require the corresponding roster export, not the main
        * one-row-per-interview file supplied to suite data().
        preserve
            quietly keep if affected_roster!=""
            if _N>0 {
                quietly gen byte final_status = 6
                quietly gen byte final_answered = .
                quietly gen byte final_enabled = .
                quietly gen double final_enable_tri = .
                quietly gen strL final_note = "roster instance - check the corresponding roster export"
                quietly append using `"`ACC'"'
                quietly save `"`ACC'"', replace
            }
        restore
        quietly keep if affected_roster==""
        if _N==0 continue
        quietly save `"`VC'"', replace

        quietly use `"`FD'"', clear
        local splitvars ""
        capture confirm variable `v', exact
        if _rc {
            capture unab splitvars : `v'__*
            if _rc {
                quietly use `"`VC'"', clear
                quietly gen byte final_status = 5
                quietly gen byte final_answered = .
                quietly gen byte final_enabled = .
                quietly gen double final_enable_tri = .
                quietly gen strL final_note = "variable not found in supplied data() file"
                quietly append using `"`ACC'"'
                quietly save `"`ACC'"', replace
                continue
            }
        }

        if `"`splitvars'"'=="" {
            capture confirm numeric variable `v'
            if !_rc quietly gen byte final_answered = !missing(`v')
            else quietly gen byte final_answered = (`v'!="" & `v'!="##N/A##")
        }
        else {
            * Split exports have two distinct shapes. Checkbox multi-selects
            * use 0/1 option dummies; combobox/ordered multi-selects and list
            * questions store values in their members. Detect an unexpected
            * non-dummy family conservatively when presentation metadata is old.
            local splitvalues = `iscombo' | `isordered'
            if `ismulti' & !`isyesno' & !`splitvalues' {
                tempvar __nondummy
                quietly gen byte `__nondummy' = 0
                foreach sv of local splitvars {
                    capture confirm numeric variable `sv'
                    if !_rc quietly replace `__nondummy' = 1 if ///
                        !missing(`sv') & !inlist(`sv',0,1)
                    else quietly replace `__nondummy' = 1 if !inlist( ///
                        lower(strtrim(`sv')),"","0","1","false","true", ///
                        "no","yes","##n/a##")
                }
                quietly count if `__nondummy'
                if r(N)>0 local splitvalues 1
                quietly drop `__nondummy'
            }
            quietly gen byte final_answered = 0
            foreach sv of local splitvars {
                capture confirm numeric variable `sv'
                if !_rc {
                    if `ismulti' & !`isyesno' & !`splitvalues' ///
                        quietly replace final_answered = 1 if `sv'==1
                    else quietly replace final_answered = 1 if !missing(`sv')
                }
                else {
                    if `ismulti' & !`isyesno' & !`splitvalues' ///
                        quietly replace final_answered = 1 if ///
                        !inlist(lower(strtrim(`sv')),"","0","false","no","##n/a##")
                    else quietly replace final_answered = 1 if `sv'!="" & `sv'!="##N/A##"
                }
            }
        }

        * Each hierarchy component is evaluated separately. Tri-state values use
        * 0=false, 1=true, .5=unknown; AND is min(), so a known false parent
        * correctly disables a child even when the child's own referent is blank.
        foreach c in sec grp item {
            local raw  `"``c'raw'"'
            local expr `"``c'expr'"'
            if `qknown'!=1 {
                quietly gen double __`c'tri = .5
            }
            else if strtrim(`"`raw'"')=="" {
                quietly gen double __`c'tri = 1
            }
            else if strtrim(`"`expr'"')=="" {
                quietly gen double __`c'tri = .5
            }
            else {
                capture quietly gen double __`c'tri = (`expr')
                if _rc quietly gen double __`c'tri = .5
                else quietly replace __`c'tri = .5 if missing(__`c'tri) | ///
                    !inlist(__`c'tri,0,.5,1)
            }
        }
        quietly gen double final_enable_tri = min(__sectri,__grptri,__itemtri)
        quietly gen byte final_enabled = cond(final_enable_tri==.5,.,final_enable_tri)
        quietly keep interview__id final_answered final_enabled final_enable_tri
        quietly save `"`ONE'"', replace

        quietly use `"`VC'"', clear
        * ONE is built from all removal-case interviews that exist in data().
        * For the current affected variable, VC can be a strict subset.  Never
        * admit using-only rows here: they have no sk_run/affected identifiers
        * and would corrupt the run-level accumulator.
        quietly merge m:1 interview__id using `"`ONE'"', ///
            keep(master match) gen(__fm)
        quietly gen byte final_status = 5 if __fm==1
        quietly replace final_status = 1 if __fm==3 & final_answered==1 & ///
            (final_enabled==1 | missing(final_enabled))
        quietly replace final_status = 7 if __fm==3 & final_answered==1 & final_enabled==0
        quietly replace final_status = 2 if __fm==3 & final_answered==0 & final_enabled==0
        quietly replace final_status = 3 if __fm==3 & final_answered==0 & final_enabled==1
        quietly replace final_status = 4 if __fm==3 & final_answered==0 & missing(final_enabled)
        quietly gen strL final_note = ""
        quietly replace final_note = "answered in final data" if final_status==1
        quietly replace final_note = "answered although final questionnaire logic disables it" if final_status==7
        quietly replace final_note = "blank as expected - final questionnaire logic disables it" if final_status==2
        quietly replace final_note = "blank although final questionnaire logic enables it" if final_status==3
        quietly replace final_note = "blank and final enablement could not be evaluated" if final_status==4
        quietly replace final_note = "interview not found in supplied data() file" if final_status==5
        quietly drop __fm
        quietly append using `"`ACC'"'
        quietly save `"`ACC'"', replace
    }

    quietly use `"`ACC'"', clear
    quietly sort interview__id sk_run affected_qdisp
    quietly save `"`saving'"', replace
    quietly count if final_status==1
    return scalar n_answered = r(N)
    quietly count if final_status==7
    return scalar n_answereddisabled = r(N)
    quietly count if final_status==2
    return scalar n_expectedblank = r(N)
    quietly count if inlist(final_status,3,4,5,6,7)
    return scalar n_check = r(N)
end

* ---- final exported value for the nearby/linked AnswerSet ---------------------
* The answer transition shown in a removal card is historical. This helper keeps
* that event separate from the current value in the supplied final main export.
program _suso_para_triggerfinal, rclass
    version 14.2
    syntax using/ , DATA(string) SAVing(string)
    confirm file `"`using'"'
    confirm file `"`data'"'

    tempfile CASES IDS FD ACC VC ONE
    quietly use `"`using'"', clear
    foreach v in interview__id sk_run trigger trigger_roster trigval oldval qx_optmap qx_type {
        capture confirm variable `v'
        if _rc {
            di as err "suso paradata: internal historical/final value check is missing `v'."
            exit 459
        }
    }
    quietly bysort interview__id sk_run: keep if _n==1
    quietly save `"`CASES'"'

    preserve
        quietly keep interview__id
        quietly duplicates drop
        quietly save `"`IDS'"'
    restore

    quietly use `"`data'"', clear
    capture confirm string variable interview__id
    if _rc {
        di as err "suso paradata skips: data() must contain string interview__id."
        exit 459
    }
    quietly merge m:1 interview__id using `"`IDS'"', keep(match) nogenerate
    tempvar __dup
    quietly bysort interview__id: gen byte `__dup' = _N>1
    quietly count if `__dup'
    if r(N)>0 quietly bysort interview__id: keep if _n==1
    quietly drop `__dup'
    quietly save `"`FD'"'

    quietly use `"`CASES'"', clear
    quietly keep if 0
    quietly gen byte trigger_final_status = .
    quietly gen strL trigger_final_value = ""
    quietly gen strL trigger_final_label = ""
    quietly gen strL trigger_final_show = ""
    quietly gen byte trigger_final_matches_event = .
    quietly gen byte trigger_final_returns_old = .
    quietly gen strL trigger_final_text = ""
    quietly save `"`ACC'"', replace

    quietly use `"`CASES'"', clear
    quietly levelsof trigger, local(tvars) clean
    foreach v of local tvars {
        quietly use `"`CASES'"', clear
        quietly keep if trigger=="`v'"
        local qtype `"`=lower(qx_type[1])'"'
        local ismulti = strpos(`"`qtype'"',"multi")>0 | strpos(`"`qtype'"',"multy")>0
        local istextlist = strpos(`"`qtype'"',"text list")>0 | strpos(`"`qtype'"',"textlist")>0
        local iscombo = strpos(`"`qtype'"',"combo")>0
        local isordered = strpos(`"`qtype'"',"ordered")>0 | strpos(`"`qtype'"',"rank")>0

        * Main exports have one row per interview and cannot identify roster rows.
        preserve
            quietly keep if trigger_roster!=""
            if _N>0 {
                quietly gen byte trigger_final_status = 4
                quietly gen strL trigger_final_value = ""
                quietly gen strL trigger_final_label = ""
                quietly gen strL trigger_final_show = ""
                quietly gen byte trigger_final_matches_event = .
                quietly gen byte trigger_final_returns_old = .
                quietly gen strL trigger_final_text = ///
                    "Final export value was not checked because this is a roster instance; use the corresponding roster export."
                quietly append using `"`ACC'"'
                quietly save `"`ACC'"', replace
            }
        restore
        quietly keep if trigger_roster==""
        if _N==0 continue
        quietly save `"`VC'"', replace

        quietly use `"`FD'"', clear
        local splitvars ""
        capture confirm variable `v', exact
        if _rc {
            capture unab splitvars : `v'__*
            if _rc {
                quietly use `"`VC'"', clear
                quietly gen byte trigger_final_status = 3
                quietly gen strL trigger_final_value = ""
                quietly gen strL trigger_final_label = ""
                quietly gen strL trigger_final_show = ""
                quietly gen byte trigger_final_matches_event = .
                quietly gen byte trigger_final_returns_old = .
                quietly gen strL trigger_final_text = ///
                    "Final export value was not checked because the answer-event variable is not present in data()."
                quietly append using `"`ACC'"'
                quietly save `"`ACC'"', replace
                continue
            }
        }

        * Ordered/ranked multi-select families encode ranks against option-code
        * suffixes, while old metadata may not identify whether a non-dummy
        * family is ordered or combobox. Do not manufacture an exact value in
        * either ambiguous case; return an explicit not-evaluable status.
        local splitunsupported 0
        local splitwhy ""
        if `"`splitvars'"'!="" & `isordered' {
            local splitunsupported 1
            local splitwhy "ordered/ranked split multi-select export"
        }
        else if `"`splitvars'"'!="" & `ismulti' & !`iscombo' {
            tempvar __nondummy
            quietly gen byte `__nondummy' = 0
            foreach sv of local splitvars {
                capture confirm numeric variable `sv'
                if !_rc quietly replace `__nondummy' = 1 if ///
                    !missing(`sv') & !inlist(`sv',0,1)
                else quietly replace `__nondummy' = 1 if !inlist( ///
                    lower(strtrim(`sv')),"","0","1","false","true", ///
                    "no","yes","##n/a##")
            }
            quietly count if `__nondummy'
            if r(N)>0 {
                local splitunsupported 1
                local splitwhy "split multi-select export with unknown presentation"
            }
            quietly drop `__nondummy'
        }
        if `splitunsupported' {
            quietly use `"`VC'"', clear
            quietly gen byte trigger_final_status = 6
            quietly gen strL trigger_final_value = ""
            quietly gen strL trigger_final_label = ""
            quietly gen strL trigger_final_show = ""
            quietly gen byte trigger_final_matches_event = .
            quietly gen byte trigger_final_returns_old = .
            quietly gen strL trigger_final_text = ///
                "Final export value was not compared because `splitwhy' cannot be reconstructed exactly without presentation metadata."
            quietly append using `"`ACC'"'
            quietly save `"`ACC'"', replace
            continue
        }

        if `"`splitvars'"'=="" {
            capture confirm numeric variable `v'
            if !_rc quietly gen strL trigger_final_value = ///
                cond(missing(`v'), "", strtrim(string(`v', "%21.0g")))
            else quietly gen strL trigger_final_value = ///
                cond(`v'=="" | `v'=="##N/A##", "", `v')
        }
        else {
            * Reconstruct the documented parent value. Checkbox multi-select
            * dummies contribute their option-code suffix; combobox slots and
            * ordinary split values contribute their cell value. Text lists use
            * a vertical bar, while categorical values use commas.
            local splitsep = cond(`istextlist',"|",",")
            quietly gen strL trigger_final_value = ""
            foreach sv of local splitvars {
                local suffix = substr("`sv'",length("`v'")+3,.)
                tempvar svtxt take
                capture confirm numeric variable `sv'
                if !_rc {
                    quietly gen strL `svtxt' = cond(missing(`sv'),"",      ///
                        strtrim(string(`sv',"%21.0g")))
                    if `ismulti' & !`iscombo' {
                        quietly gen byte `take' = (`sv'==1) if !missing(`sv')
                        quietly replace `svtxt' = "`suffix'" if `take'==1
                        quietly replace `svtxt' = "" if `take'!=1
                    }
                }
                else {
                    quietly gen strL `svtxt' = cond(`sv'=="" | `sv'=="##N/A##","",`sv')
                    if `ismulti' & !`iscombo' {
                        quietly gen byte `take' = !inlist(lower(strtrim(`sv')),"","0","false","no")
                        quietly replace `svtxt' = "`suffix'" if `take'==1
                        quietly replace `svtxt' = "" if `take'!=1
                    }
                }
                quietly replace trigger_final_value = trigger_final_value +   ///
                    cond(trigger_final_value!="" & `svtxt'!="","`splitsep'","") + `svtxt'
                quietly drop `svtxt'
                capture quietly drop `take'
            }
        }
        quietly keep interview__id trigger_final_value
        quietly save `"`ONE'"', replace

        quietly use `"`VC'"', clear
        * ONE contains every removal-case interview in the final export, while
        * VC contains only runs whose selected trigger is `v'.  Keeping using-only
        * rows would create observations with missing sk_run and make the final
        * run-key isid fail (notably under vars() on heterogeneous interviews).
        quietly merge m:1 interview__id using `"`ONE'"', ///
            keep(master match) gen(__tf)
        quietly gen byte trigger_final_status = 5 if __tf==1
        quietly replace trigger_final_status = 2 if __tf==3 & trigger_final_value==""
        quietly replace trigger_final_status = 1 if __tf==3 & trigger_final_value!=""
        quietly gen strL trigger_final_label = ""
        quietly gen strL __dummy_label = ""
        mata: _suso_qx_apply_labels("trigger_final_value", "trigger_final_value", ///
            "qx_optmap", "trigger_final_label", "__dummy_label")
        quietly drop __dummy_label __tf
        quietly gen strL trigger_final_show = trigger_final_value + ///
            cond(trigger_final_label!="", " - " + trigger_final_label, "")

        tempvar __fn __tn __on
        quietly gen double `__fn' = real(trigger_final_value)
        quietly gen double `__tn' = real(trigval)
        quietly gen double `__on' = real(oldval)
        quietly gen byte trigger_final_matches_event = .
        quietly replace trigger_final_matches_event = ///
            cond(!missing(`__fn') & !missing(`__tn'), `__fn'==`__tn', ///
            trigger_final_value==trigval) if trigger_final_status==1
        quietly gen byte trigger_final_returns_old = .
        quietly replace trigger_final_returns_old = ///
            cond(!missing(`__fn') & !missing(`__on'), `__fn'==`__on', ///
            trigger_final_value==oldval) if trigger_final_status==1 & oldval!=""
        if `ismulti' {
            * Multi-select order is not semantically meaningful. Compare unique,
            * sorted code sets so "1,3" and "3,1" match.
            forvalues rr = 1/`=_N' {
                if trigger_final_status[`rr']!=1 continue
                local fset = subinstr(trigger_final_value[`rr'],","," ",.)
                local eset = subinstr(trigval[`rr'],","," ",.)
                local oset = subinstr(oldval[`rr'],","," ",.)
                foreach which in f e o {
                    local norm ""
                    foreach token of local `which'set {
                        local number = real("`token'")
                        if !missing(`number') local token = strtrim(string(`number',"%21.0g"))
                        local norm "`norm' `token'"
                    }
                    local `which'set = strtrim("`norm'")
                }
                local fset : list uniq fset
                local eset : list uniq eset
                local oset : list uniq oset
                local fset : list sort fset
                local eset : list sort eset
                local oset : list sort oset
                quietly replace trigger_final_matches_event = ("`fset'"=="`eset'") in `rr'
                if oldval[`rr']!="" quietly replace trigger_final_returns_old = ///
                    ("`fset'"=="`oset'") in `rr'
            }
        }

        quietly gen strL trigger_final_text = ""
        quietly replace trigger_final_text = trigger + ///
            " = " + trigger_final_show + ". It matches the historical event value." ///
            if trigger_final_status==1 & trigger_final_matches_event==1
        quietly replace trigger_final_text = trigger + ///
            " = " + trigger_final_show + ". The historical event was not final; " + ///
            "the export returned to the earlier value." ///
            if trigger_final_status==1 & trigger_final_matches_event==0 & ///
            trigger_final_returns_old==1
        quietly replace trigger_final_text = trigger + ///
            " = " + trigger_final_show + ". This differs from the historical event value " + ///
            trigval + "." if trigger_final_status==1 & ///
            trigger_final_matches_event==0 & trigger_final_returns_old!=1
        quietly replace trigger_final_text = trigger + ///
            " is blank." if trigger_final_status==2
        quietly replace trigger_final_text = ///
            "Final export row was not found for this interview." if trigger_final_status==5

        quietly append using `"`ACC'"'
        quietly save `"`ACC'"', replace
    }

    quietly use `"`ACC'"', clear
    quietly keep interview__id sk_run trigger_final_status trigger_final_value   ///
        trigger_final_label trigger_final_show trigger_final_matches_event       ///
        trigger_final_returns_old trigger_final_text
    quietly sort interview__id sk_run
    quietly by interview__id sk_run: keep if _n==1
    quietly isid interview__id sk_run
    quietly save `"`saving'"', replace
    quietly count if trigger_final_status==1 & trigger_final_matches_event==0
    return scalar ndifferent = r(N)
    quietly count if trigger_final_status==1 & trigger_final_returns_old==1
    return scalar nreturnedold = r(N)
end

* ---- skips: historical answer-removal runs and nearby/linked answers --------
* A "cascade" is a compact run of >= cascade() consecutive AnswerRemoved events
* near an AnswerSet. It is a screening signal, not proof of causation or proof
* that the affected questions remain blank in the final interview.
program _suso_para_skips, rclass
    version 14.2
    syntax [, CASCade(integer 3) WINdow(real 60) TOP(integer 15) SAVing(string) replace ///
        QX(string) DATA(string) MESSages(string) HTML(string) DETail(string) VARS(string) ///
        FULL ALLRoles ]
    _suso_para_need events
    quietly _suso_para_derive , gapmins(30) fastsecs(2) `allroles'
    if `"`qx'"'!=""   local qx   = subinstr(`"`qx'"',   "\", "/", .)
    if `"`data'"'!="" local data = subinstr(`"`data'"', "\", "/", .)
    if `"`data'"'!="" {
        capture confirm file `"`data'"'
        if _rc {
            di as err `"suso paradata skips: final data file not found: `data'"'
            exit 601
        }
    }
    if `cascade'<2 {
        di as err "suso paradata skips: cascade() is the minimum run of AnswerRemoved events; use 2 or more."
        exit 198
    }
    if `window'<=0 {
        di as err "suso paradata skips: window() must be positive (seconds)."
        exit 198
    }

    * Parse questionnaire metadata. qx_enable is the EFFECTIVE condition:
    * section + subsection/group + item-level conditions. Keeping the components
    * separately lets final-data adjudication apply three-valued logic correctly:
    * a false parent condition disables a question even when a child referent is blank.
    local hasqx 0
    tempfile QXT QXMETA
    if `"`qx'"'!="" {
        preserve
        _suso_para_qxload , file(`"`qx'"')
        quietly keep qx_var qx_type qx_text qx_section qx_subsection qx_enable  ///
            qx_enable_deps qx_section_enable qx_group_enable qx_item_enable       ///
            qx_calc qx_optmap qx_section_tri qx_group_tri qx_item_tri
        quietly bysort qx_var: keep if _n==1
        quietly save `"`QXMETA'"'
        forvalues j = 1/`=_N' {
            local known_`=qx_var[`j']' 1
            local en_`=qx_var[`j']' = substr(qx_enable[`j'], 1, 1600)
            local deps_`=qx_var[`j']' = substr(qx_enable_deps[`j'], 1, 4000)
            local sec_`=qx_var[`j']' = substr(qx_section[`j'], 1, 80)
        }
        quietly rename qx_var trigger
        quietly save `"`QXT'"'
        restore
        local hasqx 1
    }

    local hasvar 0
    capture confirm variable para_var
    if !_rc local hasvar 1
    if !`hasvar' di as txt "suso paradata skips: note — no parameters column (reduced export?); cascades are detected but trigger variables cannot be named."

    * Backfill question-instance fields when events were prepared by an older
    * build. Exact roster-aware transitions require para_qkey/para_roster.
    if `hasvar' {
        capture confirm variable para_val
        if _rc quietly gen strL para_val = ""
        capture confirm variable para_roster
        if _rc quietly gen str160 para_roster = ""
        capture confirm variable para_qkey
        if _rc {
            quietly gen str244 para_qkey = para_var if para_var!=""
            di as txt "  note: this prepared event table predates roster-aware keys; non-roster transitions remain exact, roster transitions should be rebuilt with {bf:suso paradata load}."
        }
        capture confirm variable para_qdisp
        if _rc quietly gen str244 para_qdisp = para_var if para_var!=""
    }

    capture drop sk_*
    quietly gen byte sk_isrem = para_fieldrem

    * vars() is an output filter only. Cascade construction must always use the
    * untouched event stream; otherwise dropping intervening events changes
    * adjacency and can manufacture a removal run that never occurred.
    quietly gen byte sk_vsel = 1
    if `"`vars'"'!="" & `hasvar' {
        quietly replace sk_vsel = 0
        foreach p of local vars {
            quietly replace sk_vsel = 1 if (para_fieldans | para_fieldrem) & strmatch(para_var, "`p'")
        }
    }
    else if `"`vars'"'!="" & !`hasvar' {
        di as txt "  vars(): ignored because this reduced paradata has no question-variable names."
    }

    * Final state is computed per exact question instance (variable + roster
    * address). Keep the full state history as well so the candidate AnswerSet can
    * be described as changed, repeated, first observed, or re-entered.
    tempfile FSTATE HSTATE
    local hasfstate 0
    local hashstate 0
    if `hasvar' {
        preserve
        quietly keep if (para_ans | para_rem) & para_qkey!=""
        if _N>0 {
            quietly gen str16 hist_event = cond(para_ans,"answerset","answerremoved")
            quietly gen strL hist_val = cond(para_ans,para_val,"")
            quietly gen str244 trigger_qkey = para_qkey
            quietly gen double hist_ord = para_ord
            quietly gen double hist_seq = para_seq
            quietly gen double hist_tsu = para_tsu
            quietly keep interview__id trigger_qkey hist_event hist_val ///
                hist_ord hist_seq hist_tsu
            quietly save `"`HSTATE'"'
            local hashstate 1
        }
        restore

        preserve
        quietly keep if (para_ans | para_rem) & para_qkey!=""
        if _N>0 {
            sort interview__id para_qkey para_ord para_seq
            quietly by interview__id para_qkey: keep if _n==_N
            quietly gen byte sk_finalans = para_ans
            quietly keep interview__id para_qkey sk_finalans
            quietly save `"`FSTATE'"'
            local hasfstate 1
        }
        restore
    }

    * responsible (same rule as timing: at the last answer, else at the last event)
    quietly gen str244 sk_resp = ""
    capture confirm string variable responsible
    if !_rc {
        tempvar resppri
        quietly gen byte `resppri' = para_ivw + para_fieldans
        quietly bysort interview__id (`resppri' para_ord para_seq): ///
            replace sk_resp = responsible[_N]
    }

    * Carry the exact preceding and following AnswerSet through the stream.
    * Along with the variable and value, retain roster address, instance key,
    * event order, file-row tiebreaker, and timestamp.
    if `hasvar' quietly gen str80 sk_lastvar = para_var if para_fieldans
    else        quietly gen str80 sk_lastvar = "(unnamed)" if para_fieldans
    quietly gen strL   sk_lastval    = para_val if para_fieldans
    quietly gen str160 sk_lastroster = para_roster if para_fieldans
    quietly gen str244 sk_lastqkey   = para_qkey if para_fieldans
    quietly gen double sk_lastts     = para_tsu if para_fieldans
    quietly gen double sk_lastord    = para_ord if para_fieldans
    quietly gen double sk_lastseq    = para_seq if para_fieldans

    quietly gen str120 sk_actor = ""
    capture confirm string variable responsible
    if !_rc quietly replace sk_actor = substr(responsible,1,120)

    quietly gen str80  sk_nextvar    = sk_lastvar
    quietly gen strL   sk_nextval    = sk_lastval
    quietly gen str160 sk_nextroster = sk_lastroster
    quietly gen str244 sk_nextqkey   = sk_lastqkey
    quietly gen double sk_nextts     = sk_lastts
    quietly gen double sk_nextord    = sk_lastord
    quietly gen double sk_nextseq    = sk_lastseq

    quietly bysort interview__id (para_ord para_seq): ///
        replace sk_lastvar = sk_lastvar[_n-1] if missing(sk_lastseq) & _n>1
    quietly by interview__id: replace sk_lastval = sk_lastval[_n-1] if missing(sk_lastseq) & _n>1
    quietly by interview__id: replace sk_lastroster = sk_lastroster[_n-1] if missing(sk_lastseq) & _n>1
    quietly by interview__id: replace sk_lastqkey = sk_lastqkey[_n-1] if missing(sk_lastseq) & _n>1
    quietly by interview__id: replace sk_lastts = sk_lastts[_n-1] if missing(sk_lastseq) & _n>1
    quietly by interview__id: replace sk_lastord = sk_lastord[_n-1] if missing(sk_lastseq) & _n>1
    quietly by interview__id: replace sk_lastseq = sk_lastseq[_n-1] if missing(sk_lastseq) & _n>1

    * SuSo may record a removal run before the AnswerSet that triggered it, so
    * carry the next AnswerSet backward as an equally explicit candidate.
    gsort interview__id -para_ord -para_seq
    quietly by interview__id: replace sk_nextvar = sk_nextvar[_n-1] if missing(sk_nextseq) & _n>1
    quietly by interview__id: replace sk_nextval = sk_nextval[_n-1] if missing(sk_nextseq) & _n>1
    quietly by interview__id: replace sk_nextroster = sk_nextroster[_n-1] if missing(sk_nextseq) & _n>1
    quietly by interview__id: replace sk_nextqkey = sk_nextqkey[_n-1] if missing(sk_nextseq) & _n>1
    quietly by interview__id: replace sk_nextts = sk_nextts[_n-1] if missing(sk_nextseq) & _n>1
    quietly by interview__id: replace sk_nextord = sk_nextord[_n-1] if missing(sk_nextseq) & _n>1
    quietly by interview__id: replace sk_nextseq = sk_nextseq[_n-1] if missing(sk_nextseq) & _n>1
    sort interview__id para_ord para_seq

    * Interview keys for the review page.
    tempfile SKKEY
    local haskey 0
    preserve
    quietly keep if para_ev=="keyassigned"
    capture confirm string variable parameters
    if !_rc & _N>0 {
        local haskey 1
        quietly bysort interview__id (para_ord para_seq): keep if _n==_N
        quietly gen ikey = substr(strtrim(parameters), 1, 12)
        quietly keep interview__id ikey
        quietly save `"`SKKEY'"'
    }
    restore

    * Runs are constructed on the FULL event stream. The whole removal run must
    * be compact, and a candidate gate may be the nearest AnswerSet immediately
    * before OR after the run (SuSo versions differ in event ordering).
    sort interview__id para_ord para_seq
    tempvar rise rmin rmax rspan dtprev dtnext prevnear nextnear
    quietly by interview__id: gen byte `rise' = sk_isrem & sk_isrem[_n-1]!=1
    quietly by interview__id: gen double sk_run = sum(`rise')
    quietly bysort interview__id sk_run sk_isrem (para_ord para_seq): ///
        gen long sk_len = _N if sk_isrem
    quietly by interview__id sk_run sk_isrem: gen byte sk_first = (_n==1) & sk_isrem
    quietly egen double `rmin' = min(cond(sk_isrem, para_tsu, .)), by(interview__id sk_run)
    quietly egen double `rmax' = max(cond(sk_isrem, para_tsu, .)), by(interview__id sk_run)
    quietly gen double `rspan' = `rmax' - `rmin'
    quietly gen double `dtprev' = para_tsu - sk_lastts if sk_first
    quietly gen double `dtnext' = sk_nextts - `rmax' if sk_first
    quietly gen byte `prevnear' = sk_first & sk_len>=`cascade' & !missing(sk_len) ///
        & inrange(`dtprev', 0, `window'*1000) & `rspan'<=`window'*1000 & sk_lastvar!=""
    quietly gen byte `nextnear' = sk_first & sk_len>=`cascade' & !missing(sk_len) ///
        & inrange(`dtnext', 0, `window'*1000) & `rspan'<=`window'*1000 & sk_nextvar!=""
    quietly gen byte sk_prevnear = `prevnear'
    quietly gen byte sk_nextnear = `nextnear'
    quietly gen byte sk_useprev = sk_prevnear & (!sk_nextnear | (`dtprev'<=`dtnext'))
    quietly gen byte sk_casc1 = sk_prevnear | sk_nextnear
    tempvar runiscasc
    quietly egen byte `runiscasc' = max(sk_casc1), by(interview__id sk_run)
    quietly gen byte sk_casc = sk_isrem & `runiscasc'
    quietly gen str80 sk_trig = cond(sk_useprev, sk_lastvar, sk_nextvar) if sk_casc1
    quietly gen strL sk_trigval = cond(sk_useprev, sk_lastval, sk_nextval) if sk_casc1
    quietly gen str160 sk_trigroster = cond(sk_useprev, sk_lastroster, sk_nextroster) if sk_casc1
    quietly gen str244 sk_trigqkey = cond(sk_useprev, sk_lastqkey, sk_nextqkey) if sk_casc1
    quietly gen double sk_trigts = cond(sk_useprev, sk_lastts, sk_nextts) if sk_casc1
    quietly gen double sk_trigord = cond(sk_useprev, sk_lastord, sk_nextord) if sk_casc1
    quietly gen double sk_trigseq = cond(sk_useprev, sk_lastseq, sk_nextseq) if sk_casc1
    foreach sv in sk_trig sk_trigval sk_trigroster sk_trigqkey {
        quietly bysort interview__id sk_run (para_ord para_seq): ///
            replace `sv' = `sv'[_n-1] if `sv'=="" & _n>1
    }
    foreach nv in sk_useprev sk_trigts sk_trigord sk_trigseq {
        quietly bysort interview__id sk_run (para_ord para_seq): ///
            replace `nv' = `nv'[_n-1] if missing(`nv') & _n>1
    }
    quietly replace sk_trig = "" if !sk_casc
    quietly replace sk_trigval = "" if !sk_casc
    quietly replace sk_trigroster = "" if !sk_casc
    quietly replace sk_trigqkey = "" if !sk_casc
    quietly replace sk_useprev = . if !sk_casc
    quietly replace sk_trigts = . if !sk_casc
    quietly replace sk_trigord = . if !sk_casc
    quietly replace sk_trigseq = . if !sk_casc

    * Apply vars() only AFTER a run exists. Keep a run when either its candidate
    * trigger or at least one affected question matches the requested patterns.
    if `"`vars'"'!="" & `hasvar' {
        tempvar remsel runsel trigsel runtrigsel
        quietly gen byte `remsel' = sk_vsel & sk_isrem
        quietly egen byte `runsel' = max(`remsel'), by(interview__id sk_run)
        quietly gen byte `trigsel' = 0
        foreach p of local vars {
            quietly replace `trigsel' = 1 if sk_casc1 & ///
                ((sk_prevnear & strmatch(sk_lastvar, "`p'")) | ///
                 (sk_nextnear & strmatch(sk_nextvar, "`p'")))
        }
        quietly egen byte `runtrigsel' = max(`trigsel'), by(interview__id sk_run)
        quietly replace sk_casc1 = 0 if sk_casc1 & `runsel'==0 & `runtrigsel'==0
        quietly replace sk_casc  = 0 if sk_casc  & `runsel'==0 & `runtrigsel'==0
        quietly replace sk_trig = "" if !sk_casc
        quietly replace sk_trigval = "" if !sk_casc
        quietly replace sk_trigroster = "" if !sk_casc
        quietly replace sk_trigqkey = "" if !sk_casc
        quietly replace sk_trigts = . if !sk_casc
        quietly replace sk_trigord = . if !sk_casc
        quietly replace sk_trigseq = . if !sk_casc
    }

    * Determine the final state of each distinct question INSTANCE affected by
    * each run. Roster rows with the same variable name remain separate.
    if `hasfstate' {
        quietly merge m:1 interview__id para_qkey using `"`FSTATE'"', ///
            keep(master match) nogenerate
    }
    else quietly gen byte sk_finalans = .
    tempvar qtag
    if `hasvar' {
        quietly egen byte `qtag' = tag(interview__id sk_run para_qkey) ///
            if sk_casc & sk_isrem & para_qkey!=""
        quietly replace `qtag' = 0 if missing(`qtag')
        quietly gen byte sk_qtag = `qtag'
    }
    else quietly gen byte sk_qtag = sk_casc
    quietly gen byte sk_reanswered = sk_qtag & sk_finalans==1
    quietly gen byte sk_open       = sk_qtag & sk_finalans==0
    quietly gen byte sk_unknown    = sk_qtag & missing(sk_finalans)

    * One row per affected question instance. This is later compared with the
    * supplied final export and the effective questionnaire logic.
    tempfile CASEV FINALV FINALCASE FINALINT
    local hascasev 0
    if `hasvar' {
        preserve
        quietly keep if sk_qtag
        quietly keep interview__id sk_run para_var para_roster para_qkey para_qdisp
        quietly rename (para_var para_roster para_qkey para_qdisp)               ///
            (affected_var affected_roster affected_qkey affected_qdisp)
        quietly save `"`CASEV'"'
        local hascasev 1
        restore
    }

    quietly count if sk_casc1
    local ncasc = r(N)
    quietly count if sk_casc
    local nwiped = r(N)                 // backward-compatible: removal-event count
    local nremevents = `nwiped'
    quietly count if sk_qtag
    local naffectedqall = r(N)          // distinct question-within-run cases
    quietly count if sk_reanswered
    local nreansweredall = r(N)
    quietly count if sk_open
    local nopenall = r(N)
    quietly count if sk_unknown
    local nunknownall = r(N)

    * ---- cascade-level detail: exact candidate transition + affected states ----
    local hasdet 0
    local hasfinaldata 0
    local nfinalansweredall 0
    local nanswereddisabledall 0
    local nexpectedblankall 0
    local nblankenabledall 0
    local nlogicunknownall 0
    local nnotindataall 0
    local nfinalcheckall = `nopenall' + `nunknownall'
    tempfile skdet
    if `ncasc'>0 {
        local hasdet 1
        preserve
        quietly keep if sk_casc
        sort interview__id sk_run para_ord para_seq
        quietly by interview__id sk_run: gen long sk_k = _n

        * Build distinct, roster-aware lists for all affected instances and for
        * each final-state bucket shown to supervisors.
        quietly gen strL sk_wvars = ""
        quietly gen strL sk_wl = ""
        quietly gen strL sk_wr = ""
        quietly gen strL sk_wo = ""
        quietly gen strL sk_wu = ""
        if `hasvar' {
            quietly by interview__id sk_run: replace sk_wvars = ///
                cond(_n==1, cond(sk_qtag, para_var, ""), ///
                cond(sk_qtag, sk_wvars[_n-1] + cond(sk_wvars[_n-1]=="", "", ", ") + para_var, sk_wvars[_n-1]))
            quietly by interview__id sk_run: replace sk_wl = ///
                cond(_n==1, cond(sk_qtag, para_qdisp, ""), ///
                cond(sk_qtag, sk_wl[_n-1] + cond(sk_wl[_n-1]=="", "", ", ") + para_qdisp, sk_wl[_n-1]))
            quietly by interview__id sk_run: replace sk_wr = ///
                cond(_n==1, cond(sk_reanswered, para_qdisp, ""), ///
                cond(sk_reanswered, sk_wr[_n-1] + cond(sk_wr[_n-1]=="", "", ", ") + para_qdisp, sk_wr[_n-1]))
            quietly by interview__id sk_run: replace sk_wo = ///
                cond(_n==1, cond(sk_open, para_qdisp, ""), ///
                cond(sk_open, sk_wo[_n-1] + cond(sk_wo[_n-1]=="", "", ", ") + para_qdisp, sk_wo[_n-1]))
            quietly by interview__id sk_run: replace sk_wu = ///
                cond(_n==1, cond(sk_unknown, para_qdisp, ""), ///
                cond(sk_unknown, sk_wu[_n-1] + cond(sk_wu[_n-1]=="", "", ", ") + para_qdisp, sk_wu[_n-1]))
        }

        collapse (last) wvars=sk_wvars wl=sk_wl wl_reanswered=sk_wr             ///
            wl_open=sk_wo wl_unknown=sk_wu                                      ///
            avar=sk_nextvar aval=sk_nextval aroster=sk_nextroster               ///
            aqkey=sk_nextqkey aord=sk_nextord aseq=sk_nextseq ats=sk_nextts     ///
            pvar=sk_lastvar pval=sk_lastval proster=sk_lastroster               ///
            pqkey=sk_lastqkey pord=sk_lastord pseq=sk_lastseq pts=sk_lastts     ///
            (max) tend=para_tsu                                                  ///
            (count) nrem=sk_k (sum) nqrem=sk_qtag nreanswered=sk_reanswered    ///
            nopen=sk_open nunknown=sk_unknown (min) ts0=para_tsu                ///
            (first) trigger=sk_trig trigval=sk_trigval                          ///
            trigger_roster=sk_trigroster trigger_qkey=sk_trigqkey              ///
            trigger_tsu=sk_trigts trigger_ord=sk_trigord trigger_seq=sk_trigseq ///
            useprev=sk_useprev prevok=sk_prevnear nextok=sk_nextnear            ///
            actor=sk_actor resp=sk_resp, by(interview__id sk_run) fast

        * Only candidates that passed the bounded proximity test may adjudicate a run.
        quietly replace pvar = "" if prevok!=1
        quietly replace pval = "" if pvar==""
        quietly replace proster = "" if pvar==""
        quietly replace pqkey = "" if pvar==""
        quietly replace pord = . if pvar==""
        quietly replace pseq = . if pvar==""
        quietly replace pts = . if pvar==""
        quietly replace avar = "" if nextok!=1 | missing(ats) | (ats-tend)<0 | ///
            (ats-tend)>`window'*1000
        quietly replace aval = "" if avar==""
        quietly replace aroster = "" if avar==""
        quietly replace aqkey = "" if avar==""
        quietly replace aord = . if avar==""
        quietly replace aseq = . if avar==""
        quietly replace ats = . if avar==""

        * Questionnaire metadata distinguishes five relationship cases:
        *   1 linked candidate; 2 conditions exist but do not reference it;
        *   3 known questions with no item-level condition shown; 4 variables absent from preview;
        *   5 a mixture of known and absent variables.
        quietly gen byte conf = 0
        quietly gen int nqknown = 0
        quietly gen int nqcond = 0
        quietly gen int nqabsent = 0
        quietly gen int nlinked = 0
        quietly gen int nlinked_direct = 0
        quietly gen int nlinked_indirect = 0
        quietly gen byte reltype = 2
        if `hasqx' {
            forvalues r = 1/`=_N' {
                local wlw = subinstr(wvars[`r'], ",", " ", .)
                local av = avar[`r']
                local pv = pvar[`r']
                local up = useprev[`r']
                local hitAd 0
                local hitAi 0
                local hitPd 0
                local hitPi 0
                local nknown 0
                local ncond 0
                local nabs 0
                foreach w of local wlw {
                    if `"`known_`w''"'=="1" local ++nknown
                    else local ++nabs
                    local ee `"`en_`w''"'
                    if `"`ee'"'=="" continue
                    local ++ncond
                    local dd `"`deps_`w''"'
                    if "`av'"!="" {
                        if ustrregexm(`"`ee'"', "(^|[^A-Za-z0-9_])`av'([^A-Za-z0-9_]|$)") local ++hitAd
                        else if ustrregexm(`"`dd'"', "(^|[^A-Za-z0-9_])`av'([^A-Za-z0-9_]|$)") local ++hitAi
                    }
                    if "`pv'"!="" {
                        if ustrregexm(`"`ee'"', "(^|[^A-Za-z0-9_])`pv'([^A-Za-z0-9_]|$)") local ++hitPd
                        else if ustrregexm(`"`dd'"', "(^|[^A-Za-z0-9_])`pv'([^A-Za-z0-9_]|$)") local ++hitPi
                    }
                }
                local hitA = `hitAd' + `hitAi'
                local hitP = `hitPd' + `hitPi'
                quietly replace nqknown = `nknown' in `r'
                quietly replace nqcond = `ncond' in `r'
                quietly replace nqabsent = `nabs' in `r'

                if `hitA'>0 & (`hitP'==0 | `up'==0) {
                    quietly replace conf = 2 in `r'
                    quietly replace nlinked = `hitA' in `r'
                    quietly replace nlinked_direct = `hitAd' in `r'
                    quietly replace nlinked_indirect = `hitAi' in `r'
                    quietly replace trigger = avar[`r'] in `r'
                    quietly replace trigval = aval[`r'] in `r'
                    quietly replace trigger_roster = aroster[`r'] in `r'
                    quietly replace trigger_qkey = aqkey[`r'] in `r'
                    quietly replace trigger_tsu = ats[`r'] in `r'
                    quietly replace trigger_ord = aord[`r'] in `r'
                    quietly replace trigger_seq = aseq[`r'] in `r'
                    quietly replace useprev = 0 in `r'
                }
                else if `hitP'>0 {
                    quietly replace conf = 1 in `r'
                    quietly replace nlinked = `hitP' in `r'
                    quietly replace nlinked_direct = `hitPd' in `r'
                    quietly replace nlinked_indirect = `hitPi' in `r'
                    quietly replace trigger = pvar[`r'] in `r'
                    quietly replace trigval = pval[`r'] in `r'
                    quietly replace trigger_roster = proster[`r'] in `r'
                    quietly replace trigger_qkey = pqkey[`r'] in `r'
                    quietly replace trigger_tsu = pts[`r'] in `r'
                    quietly replace trigger_ord = pord[`r'] in `r'
                    quietly replace trigger_seq = pseq[`r'] in `r'
                    quietly replace useprev = 1 in `r'
                }
            }
        }
        quietly gen byte linkmode = 0
        quietly replace linkmode = 1 if nlinked_direct>0 & nlinked_indirect==0
        quietly replace linkmode = 2 if nlinked_direct==0 & nlinked_indirect>0
        quietly replace linkmode = 3 if nlinked_direct>0 & nlinked_indirect>0
        quietly replace reltype = 6 if !`hasqx'
        quietly replace reltype = 1 if conf>0
        quietly replace reltype = 3 if conf==0 & nqknown==nqrem & nqcond==0 & nqrem>0 & `hasqx'
        quietly replace reltype = 4 if conf==0 & nqknown==0 & nqrem>0 & `hasqx'
        quietly replace reltype = 5 if conf==0 & nqknown>0 & nqknown<nqrem & `hasqx'
        quietly gen byte allsvc = reltype==4
        quietly gen byte allalways = reltype==3
        quietly gen byte mixedqx = reltype==5

        if `hasqx' {
            quietly merge m:1 trigger using `"`QXT'"', keep(master match) nogenerate
        }
        else {
            quietly gen str60 qx_type = ""
            quietly gen strL qx_text = ""
            quietly gen strL qx_section = ""
            quietly gen strL qx_enable = ""
            quietly gen strL qx_optmap = ""
        }

        * The questionnaire-adjudicated trigger remains in the one-row-per-run
        * detail table. It is not merged back onto the multi-row event stream: that
        * merge is unnecessary for interview-level counts and was a repeated source
        * of fragile run-key failures on large real paradata exports.

        * Exact value history for the chosen AnswerSet and question instance.
        quietly gen str16 prev_event = ""
        quietly gen strL prev_value = ""
        quietly gen double prev_ord = .
        quietly gen double prev_seq = .
        quietly gen double prev_tsu = .
        quietly gen strL oldval = ""
        tempfile DETBASE PREVSTATE PREVANS
        quietly save `"`DETBASE'"'
        local hasprevstate 0
        local hasprevans 0
        if `hashstate' {
            quietly keep interview__id sk_run trigger_qkey trigger_ord trigger_seq
            quietly drop if trigger_qkey=="" | missing(trigger_ord)
            if _N>0 {
                quietly joinby interview__id trigger_qkey using `"`HSTATE'"', unmatched(none)
                quietly keep if hist_ord<trigger_ord | ///
                    (hist_ord==trigger_ord & hist_seq<trigger_seq)
                if _N>0 {
                    quietly sort interview__id sk_run hist_ord hist_seq
                    quietly by interview__id sk_run: keep if _n==_N
                    quietly rename hist_event prev_event
                    quietly rename hist_val prev_value
                    quietly rename hist_ord prev_ord
                    quietly rename hist_seq prev_seq
                    quietly rename hist_tsu prev_tsu
                    quietly gen str244 __suso_runkey = interview__id + "|" + ///
                        strtrim(string(sk_run,"%21.0g"))
                    quietly keep __suso_runkey prev_event prev_value ///
                        prev_ord prev_seq prev_tsu
                    quietly bysort __suso_runkey: keep if _n==1
                    quietly isid __suso_runkey
                    quietly save `"`PREVSTATE'"'
                    local hasprevstate 1
                }
            }

            quietly use `"`DETBASE'"', clear
            quietly keep interview__id sk_run trigger_qkey trigger_ord trigger_seq
            quietly drop if trigger_qkey=="" | missing(trigger_ord)
            if _N>0 {
                quietly joinby interview__id trigger_qkey using `"`HSTATE'"', unmatched(none)
                quietly keep if hist_event=="answerset" & ///
                    (hist_ord<trigger_ord | (hist_ord==trigger_ord & hist_seq<trigger_seq))
                if _N>0 {
                    quietly sort interview__id sk_run hist_ord hist_seq
                    quietly by interview__id sk_run: keep if _n==_N
                    quietly rename hist_val oldval
                    quietly gen str244 __suso_runkey = interview__id + "|" + ///
                        strtrim(string(sk_run,"%21.0g"))
                    quietly keep __suso_runkey oldval
                    quietly bysort __suso_runkey: keep if _n==1
                    quietly isid __suso_runkey
                    quietly save `"`PREVANS'"'
                    local hasprevans 1
                }
            }
        }
        quietly use `"`DETBASE'"', clear
        quietly gen str244 __suso_runkey = interview__id + "|" + ///
            strtrim(string(sk_run,"%21.0g"))
        quietly isid __suso_runkey
        if `hasprevstate' quietly merge 1:1 __suso_runkey using `"`PREVSTATE'"', ///
            update replace nogenerate
        if `hasprevans' quietly merge 1:1 __suso_runkey using `"`PREVANS'"', ///
            update replace nogenerate
        quietly drop __suso_runkey

        quietly gen byte transition = 0
        quietly replace transition = 1 if trigger_qkey!="" & prev_event=="" & trigval!=""
        quietly replace transition = 2 if prev_event=="answerset" & oldval!=trigval
        quietly replace transition = 3 if prev_event=="answerset" & oldval==trigval
        quietly replace transition = 4 if prev_event=="answerremoved" & trigval!=""

        quietly gen strL oldlabel = ""
        quietly gen strL newlabel = ""
        mata: _suso_qx_apply_labels("oldval", "trigval", "qx_optmap", "oldlabel", "newlabel")
        quietly gen strL oldshow = oldval + cond(oldlabel!="", " - " + oldlabel, "")
        quietly gen strL newshow = trigval + cond(newlabel!="", " - " + newlabel, "")
        quietly gen strL trigger_display = trigger + ///
            cond(trigger_roster!="", " [roster " + trigger_roster + "]", "")
        quietly gen str40 trigger_when = ""
        quietly replace trigger_when = string(trigger_tsu/86400000, "%tdDD_Mon_CCYY") + ///
            " " + string(trigger_tsu, "%tcHH:MM:SS") + " UTC" if !missing(trigger_tsu)
        quietly gen str40 transition_status = "Historical event not reconstructed"
        quietly replace transition_status = "Historical first observed value" if transition==1
        quietly replace transition_status = "Historical value change" if transition==2
        quietly replace transition_status = "Historical repeated value" if transition==3
        quietly replace transition_status = "Historical re-entry after removal" if transition==4
        quietly gen strL transition_text = ///
            "Exact historical answer transition could not be reconstructed from the available paradata."
        quietly replace transition_text = cond(trigger_when!="", "At " + trigger_when + ", ", "") + ///
            trigger_display + " was recorded as " + newshow + ///
            "; no earlier state event for this question instance was found." if transition==1
        quietly replace transition_text = cond(trigger_when!="", "At " + trigger_when + ", ", "") + ///
            trigger_display + " changed from " + oldshow + " to " + newshow + ///
            ". This describes that historical AnswerSet, not necessarily the final exported value." ///
            if transition==2
        quietly replace transition_text = cond(trigger_when!="", "At " + trigger_when + ", ", "") + ///
            trigger_display + " was recorded again as " + newshow + ///
            "; the value did not change at that event." if transition==3
        quietly replace transition_text = cond(trigger_when!="", "At " + trigger_when + ", ", "") + ///
            trigger_display + " was re-entered as " + newshow + " after being cleared" + ///
            cond(oldshow!="", "; the earlier recorded value was " + oldshow, "") + "." ///
            if transition==4

        * Compare every affected question instance with the FINAL export and the
        * inherited questionnaire logic. This removes false positives where the
        * final value is blank precisely because the final screening state disables it.
        tempfile DETTRANS
        quietly save `"`DETTRANS'"'
        if `"`data'"'!="" & `hascasev' {
            local qxopt ""
            if `hasqx' local qxopt `"qxmeta(`"`QXMETA'"')"'
            quietly _suso_para_casefinal using `"`CASEV'"', data(`"`data'"') ///
                saving(`"`FINALV'"') `qxopt'
            local hasfinaldata 1

            quietly use `"`FINALV'"', clear
            quietly gen byte __fa = final_status==1
            quietly gen byte __ad = final_status==7
            quietly gen byte __eb = final_status==2
            quietly gen byte __be = final_status==3
            quietly gen byte __lu = final_status==4
            quietly gen byte __nd = inlist(final_status,5,6)
            quietly gen byte __ck = inlist(final_status,3,4,5,6,7)
            quietly gen strL __la = cond(__fa,affected_qdisp,"")
            quietly gen strL __ld = cond(__ad,affected_qdisp,"")
            quietly gen strL __le = cond(__eb,affected_qdisp,"")
            quietly gen strL __lb = cond(__be,affected_qdisp,"")
            quietly gen strL __ll = cond(__lu,affected_qdisp,"")
            quietly gen strL __ln = cond(__nd,affected_qdisp,"")
            quietly gen strL __lc = cond(__ck,affected_qdisp,"")
            quietly sort interview__id sk_run affected_qdisp
            foreach z in la ld le lb ll ln lc {
                quietly by interview__id sk_run: replace __`z' = ///
                    cond(_n==1,__`z',cond(__`z'!="",__`z'[_n-1] + ///
                    cond(__`z'[_n-1]=="","",", ") + __`z',__`z'[_n-1]))
            }
            quietly collapse (sum) n_final_answered=__fa                    ///
                n_answered_disabled=__ad n_expected_blank=__eb                  ///
                n_blank_enabled=__be n_logic_unknown=__lu n_notindata=__nd      ///
                n_final_check=__ck (last) wl_final_answered=__la                ///
                wl_answered_disabled=__ld wl_expected_blank=__le                ///
                wl_blank_enabled=__lb wl_logic_unknown=__ll                     ///
                wl_notindata=__ln wl_final_check=__lc,                          ///
                by(interview__id sk_run) fast
            quietly summarize n_final_answered
            local nfinalansweredall = r(sum)
            quietly summarize n_answered_disabled
            local nanswereddisabledall = r(sum)
            quietly summarize n_expected_blank
            local nexpectedblankall = r(sum)
            quietly summarize n_blank_enabled
            local nblankenabledall = r(sum)
            quietly summarize n_logic_unknown
            local nlogicunknownall = r(sum)
            quietly summarize n_notindata
            local nnotindataall = r(sum)
            quietly summarize n_final_check
            local nfinalcheckall = r(sum)
            quietly gen str244 __suso_runkey = interview__id + "|" + ///
                strtrim(string(sk_run,"%21.0g"))
            quietly bysort __suso_runkey: keep if _n==1
            quietly isid __suso_runkey
            quietly save `"`FINALCASE'"', replace

            tempfile FINALCASEMAP
            quietly keep __suso_runkey n_final_answered n_answered_disabled ///
                n_expected_blank n_blank_enabled n_logic_unknown n_notindata ///
                n_final_check wl_final_answered wl_answered_disabled ///
                wl_expected_blank wl_blank_enabled wl_logic_unknown ///
                wl_notindata wl_final_check
            quietly save `"`FINALCASEMAP'"', replace

            quietly use `"`DETTRANS'"', clear
            quietly gen str244 __suso_runkey = interview__id + "|" + ///
                strtrim(string(sk_run,"%21.0g"))
            quietly isid __suso_runkey
            quietly merge 1:1 __suso_runkey using `"`FINALCASEMAP'"', ///
                keep(master match) nogenerate
            quietly drop __suso_runkey
        }
        else quietly use `"`DETTRANS'"', clear

        * Keep the historical AnswerSet separate from the value in the final
        * export. A transition such as 1 -> 6 may be an intermediate event even
        * when the current exported value has subsequently returned to 1.
        tempfile DETFINAL TRIGFINAL
        quietly save `"`DETFINAL'"', replace
        if `"`data'"'!="" {
            quietly _suso_para_triggerfinal using `"`DETFINAL'"', ///
                data(`"`data'"') saving(`"`TRIGFINAL'"')
            tempfile TRIGFINALMAP
            quietly use `"`TRIGFINAL'"', clear
            quietly gen str244 __suso_runkey = interview__id + "|" + ///
                strtrim(string(sk_run,"%21.0g"))
            quietly bysort __suso_runkey: keep if _n==1
            quietly isid __suso_runkey
            quietly keep __suso_runkey trigger_final_status trigger_final_value ///
                trigger_final_label trigger_final_show trigger_final_matches_event ///
                trigger_final_returns_old trigger_final_text
            quietly save `"`TRIGFINALMAP'"', replace

            quietly use `"`DETFINAL'"', clear
            quietly gen str244 __suso_runkey = interview__id + "|" + ///
                strtrim(string(sk_run,"%21.0g"))
            quietly isid __suso_runkey
            quietly merge 1:1 __suso_runkey using `"`TRIGFINALMAP'"', ///
                keep(master match) nogenerate
            quietly drop __suso_runkey
        }
        else quietly use `"`DETFINAL'"', clear
        foreach v in trigger_final_status trigger_final_matches_event            ///
            trigger_final_returns_old {
            capture confirm variable `v'
            if _rc quietly gen byte `v' = .
        }
        foreach v in trigger_final_value trigger_final_label trigger_final_show  ///
            trigger_final_text {
            capture confirm variable `v'
            if _rc quietly gen strL `v' = ""
        }

        quietly gen byte final_data_checked = `hasfinaldata'
        foreach v in n_final_answered n_answered_disabled n_expected_blank      ///
            n_blank_enabled n_logic_unknown n_notindata n_final_check {
            capture confirm variable `v'
            if _rc quietly gen long `v' = 0
            quietly replace `v' = 0 if missing(`v')
        }
        foreach v in wl_final_answered wl_answered_disabled wl_expected_blank   ///
            wl_blank_enabled wl_logic_unknown wl_notindata wl_final_check {
            capture confirm variable `v'
            if _rc quietly gen strL `v' = ""
        }
        quietly replace n_final_check = nopen+nunknown if !final_data_checked
        quietly replace wl_final_check = strtrim(wl_open + ///
            cond(wl_open!="" & wl_unknown!="", ", ", "") + wl_unknown) ///
            if !final_data_checked

        quietly save `"`skdet'"'
        if `"`detail'"'!="" quietly copy `"`skdet'"' `"`detail'"', replace
        restore

        * Final-data counts for the Behaviour dashboard and saved skip table.
        if `hasfinaldata' {
            preserve
                quietly use `"`FINALCASE'"', clear
                quietly collapse (sum) casc_finalanswered=n_final_answered       ///
                    casc_answered_disabled=n_answered_disabled                   ///
                    casc_expectedblank=n_expected_blank                          ///
                    casc_blank_enabled=n_blank_enabled                           ///
                    casc_logicunknown=n_logic_unknown casc_notindata=n_notindata ///
                    casc_finalcheck=n_final_check, by(interview__id) fast
                quietly gen byte casc_datachecked = 1
                quietly save `"`FINALINT'"', replace
            restore
        }

        * No run-level lookup is merged back to the event stream. Interview-level
        * cascade counts below are invariant to candidate re-attribution; the detailed
        * review and trigger summary use the adjudicated one-row-per-run table.
    }

    * ---- stage 1: collapse to (interview x trigger) — everything below is small,
    *      so the multi-million-row events are copied/sorted exactly once ----
    collapse (sum) n_answers=para_fieldans n_removed=para_fieldrem n_cascades=sk_casc1 ///
        casc_removed=sk_casc casc_questions=sk_qtag casc_open=sk_open            ///
        casc_reanswered=sk_reanswered casc_unknown=sk_unknown                    ///
        (first) responsible=sk_resp, by(interview__id sk_trig) fast
    tempfile sk1
    quietly save `"`sk1'"'

    di as txt _n "{hline 72}"
    di as res "  suso paradata skips" as txt "   (cascade = >=`cascade' removals within `window's of an answer)"
    di as txt "{hline 72}"

    * ---- survey-level: adjudicated answer variables recurring across runs -------
    if `hasvar' & `ncasc'>0 & `hasdet' {
        quietly use `"`skdet'"', clear
        quietly keep if trigger!=""
        if _N>0 {
            quietly gen byte __one = 1
            quietly bysort trigger interview__id: gen byte __itag = (_n==1)
            quietly collapse (sum) n_flips=__one wiped=nrem n_ints=__itag, ///
                by(trigger) fast
            quietly rename trigger sk_trig
            gsort -wiped -n_flips sk_trig
            local k = min(10, _N)
            tempname SKT
            matrix `SKT' = J(`k', 3, 0)
            local trigret ""
            di as txt "  nearby or questionnaire-linked answer variables associated with the most removal events (top `k'):"
            di as txt "  {ul:variable                }  {ul:runs}  {ul:interviews}  {ul:removal events}"
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
        }
        quietly use `"`sk1'"', clear
    }

    * ---- stage 2: one row per interview ----
    quietly gen byte sk_tg = (sk_trig!="")
    collapse (sum) n_answers n_removed n_cascades casc_removed casc_questions    ///
        casc_open casc_reanswered casc_unknown n_triggers=sk_tg                    ///
        (first) responsible, by(interview__id) fast
    if `hasfinaldata' quietly merge 1:1 interview__id using `"`FINALINT'"', ///
        keep(master match) nogenerate
    foreach v in casc_finalanswered casc_answered_disabled casc_expectedblank  ///
        casc_blank_enabled casc_logicunknown casc_notindata casc_finalcheck       ///
        casc_datachecked {
        capture confirm variable `v'
        if _rc quietly gen long `v' = 0
        quietly replace `v' = 0 if missing(`v')
    }
    quietly gen double wipe_share = casc_removed/max(n_answers,1)
    label variable interview__id "interview id"
    label variable responsible   "interviewer (at last answer)"
    label variable n_answers     "AnswerSet events"
    label variable n_removed     "AnswerRemoved events (all)"
    label variable n_cascades    "historical AnswerRemoved cascades"
    label variable casc_removed    "AnswerRemoved events in detected cascades"
    label variable casc_questions  "distinct question-within-run cases affected"
    label variable casc_open       "affected questions whose final event is AnswerRemoved"
    label variable casc_reanswered "affected questions re-answered later"
    label variable casc_unknown      "affected questions with unknown paradata final state"
    label variable casc_finalanswered "affected questions answered in final data"
    label variable casc_answered_disabled "final answers present while disabled"
    label variable casc_expectedblank  "final blanks expected because disabled"
    label variable casc_blank_enabled  "final blanks while enabled"
    label variable casc_logicunknown   "final blanks with enablement unknown"
    label variable casc_notindata      "affected instances absent from supplied data"
    label variable casc_finalcheck     "affected instances needing final-data review"
    label variable casc_datachecked    "final data and inherited logic evaluated"
    label variable n_triggers          "distinct nearby or questionnaire-linked answer variables"
    label variable wipe_share      "removal events / answers set"
    format wipe_share %5.2f
    sort interview__id
    char _dta[suso_paradata] skips

    quietly count if n_cascades>0
    local naff = r(N)
    local nints = _N
    di as txt "  cascades " as res "`ncasc'" as txt "  |  question-run cases affected " as res "`naffectedqall'" ///
        as txt "  |  removal events " as res "`nwiped'" as txt "  |  re-answered later " as res "`nreansweredall'" ///
        as txt "  |  interviews affected " as res "`naff'" as txt " of " as res "`nints'"
    if `hasfinaldata' di as txt "  final export: answered " as res "`nfinalansweredall'" ///
        as txt "  |  blank as expected (disabled) " as res "`nexpectedblankall'" ///
        as txt "  |  answered while disabled " as res "`nanswereddisabledall'" ///
        as txt "  |  blank while enabled " as res "`nblankenabledall'" ///
        as txt "  |  logic/data unresolved " as res "`=`nlogicunknownall'+`nnotindataall''"
    else di as txt "  no data() supplied: action triage falls back to paradata final state."

    * ---- top interviews ----
    if `naff'>0 {
        gsort -casc_removed -n_cascades interview__id
        local k = min(`top', `naff')
        di as txt _n "  interviews with the largest historical removal runs (top `k'):"
        di as txt "  {ul:interview}  {ul:interviewer }  {ul:cascades}  {ul:removal events}  {ul:answer vars}  {ul:removed/set}"
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
            di as txt "  {ul:interviewer     }  {ul:ints}  {ul:w/ cascade}  {ul:share}  {ul:flips}  {ul:removal events}"
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
    di as txt "  unresolved final states and repeated questionnaire-linked patterns warrant review."
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
        gsort -nqrem -nrem interview__id sk_run
        local hasqxt 0
        capture confirm variable qx_text
        if !_rc local hasqxt 1

        * ---- automatic triage: classify every case, roll up to findings -------------
        quietly gen byte nsecs = 1
        quietly gen byte selferased = 0
        quietly gen strL wlc = wl
        forvalues r = 1/`=_N' {
            local wlw = subinstr(wvars[`r'], ",", " ", .)
            local trg = trigger[`r']
            local selfr 0
            local secs ""
            foreach w of local wlw {
                if "`w'"=="`trg'" & "`trg'"!="" local selfr 1
                if `hasqxt' {
                    local ss `"`sec_`w''"'
                    if `"`ss'"'!="" & strpos(`"|`secs'|"', `"|`ss'|"')==0 local secs `"`secs'|`ss'"'
                }
            }
            quietly replace selferased = `selfr' in `r'
            local nsc = length(`"`secs'"') - length(subinstr(`"`secs'"', "|", "", .))
            if `nsc'>0 quietly replace nsecs = `nsc' in `r'
        }
        * Case severity is based on the FINAL export when data() is supplied.
        * Blank-but-disabled questions are resolved, not action items. Without
        * data(), retain the conservative paradata-only fallback.
        quietly bysort interview__id: gen long __ncint = _N
        quietly egen long __wint = total(nqrem), by(interview__id)
        quietly bysort interview__id trigger: gen long __same = _N
        quietly gen str1 tier = "C"
        quietly gen strL why = "Resolved - historical removal only"

        quietly replace why = "Resolved - final export is consistent with final questionnaire logic" ///
            if final_data_checked & n_final_check==0
        quietly replace tier = "V" if final_data_checked & n_final_check>0
        quietly replace why = "Check final data - " + strofreal(n_answered_disabled) + ///
            " answered while disabled; " + strofreal(n_blank_enabled) + ///
            " blank while enabled; " + strofreal(n_logic_unknown) + ///
            " logic unknown; " + strofreal(n_notindata) + " not in supplied data" ///
            if final_data_checked & n_final_check>0

        quietly replace why = "Resolved - all affected questions were answered again" ///
            if !final_data_checked & nopen==0 & nunknown==0
        quietly replace tier = "V" if !final_data_checked & (nopen>0 | nunknown>0)
        quietly replace why = "Check final data - " + strofreal(nopen) + ///
            " question(s) still end in AnswerRemoved; " + strofreal(nunknown) + ///
            " have unknown paradata state" if !final_data_checked & tier=="V"

        * Priority is allowed only when unresolved final-data checks remain.
        quietly replace tier = "A" if tier=="V" & ///
            ((__ncint>=3 & n_final_check>=3) | __wint>=50 | nsecs>=3)
        quietly replace why = "Priority check - multiple unresolved questions or sections" ///
            if tier=="A"
        capture quietly drop __ncint __wint __same
        quietly save `"`skdet'"', replace
        if `"`detail'"'!="" quietly copy `"`skdet'"' `"`detail'"', replace
        * Findings roll-up. Keep names and interview lists in variables rather
        * than embedding enumerator names in local-macro names (names may contain
        * spaces or punctuation).
        tempvar rg itag rtag reviewer rids rq ri vtag
        quietly gen str120 `reviewer' = substr(cond(resp!="",resp,actor),1,120)
        quietly egen long `rg' = group(`reviewer') if tier=="A" & `reviewer'!=""
        quietly bysort `rg' interview__id: gen byte `itag' = (_n==1) if !missing(`rg')
        quietly sort `rg' interview__id sk_run
        quietly gen strL `rids' = ""
        quietly by `rg': replace `rids' = ///
            cond(_n==1, cond(`itag'==1,substr(interview__id,1,8),""), ///
            cond(`itag'==1, strtrim(`rids'[_n-1] + " " + substr(interview__id,1,8)), `rids'[_n-1])) ///
            if !missing(`rg')
        quietly egen long `rq' = total(cond(tier=="A",nqrem,0)), by(`rg')
        quietly egen long `ri' = total(cond(tier=="A",`itag',0)), by(`rg')
        quietly by `rg': gen byte `rtag' = (_n==_N) if !missing(`rg')
        quietly count if `rtag'==1
        local ninv = r(N)

        quietly sort interview__id sk_run
        quietly by interview__id: gen byte `vtag' = tier=="V" & sum(tier=="V")==1
        quietly count if `vtag'==1
        local nver = r(N)
        quietly count if tier=="C"
        local nclr = r(N)
        local clrline ""
        foreach w in "Resolved - final export is consistent with final questionnaire logic" ///
            "Resolved - all affected questions were answered again" ///
            "Resolved - historical removal only" {
            quietly count if tier=="C" & why=="`w'"
            if r(N)>0 local clrline "`clrline'`=cond("`clrline'"=="","",", ")'`w' x`r(N)'"
        }
        gsort -nqrem -nrem interview__id sk_run
        quietly gen strL m_head = "CASE " + strofreal(_n) + " of `ncasc'.  Interview " ///
            + interview__id + ".  Enumerator: " + cond(actor!="", actor, resp)          ///
            + ".  Removal run on " + string(ts0/86400000, "%tdDD_Mon_CCYY") + " at " ///
            + string(ts0, "%tcHH:MM") + " UTC."
        quietly gen strL m_event = "HISTORICAL ANSWER EVENT: " + transition_text
        quietly gen strL m_finalevent = cond(trigger_final_text!="", ///
            "CURRENT FINAL VALUE: " + trigger_final_text, "")
        quietly gen strL m_rel = "RELATIONSHIP: no questionnaire relationship was established."
        quietly replace m_rel = "RELATIONSHIP: " + strofreal(nlinked_direct) + ///
            " affected question/roster instance(s) directly reference [" + trigger + ///
            "] in their enabling conditions. This is a questionnaire relationship, not proof of cause." ///
            if reltype==1 & linkmode==1
        quietly replace m_rel = "RELATIONSHIP: " + strofreal(nlinked_indirect) + ///
            " affected question/roster instance(s) depend indirectly on [" + trigger + ///
            "] through one or more calculated variables. This is a questionnaire relationship, not proof of cause." ///
            if reltype==1 & linkmode==2
        quietly replace m_rel = "RELATIONSHIP: " + strofreal(nlinked_direct) + ///
            " affected instance(s) reference [" + trigger + "] directly and " + ///
            strofreal(nlinked_indirect) + " depend on it through calculated variables. " + ///
            "This is a questionnaire relationship, not proof of cause." if reltype==1 & linkmode==3
        quietly replace m_rel = "RELATIONSHIP: affected questionnaire questions have enabling conditions, but none references [" + ///
            trigger + "]; it is the nearest AnswerSet only." if reltype==2
        quietly replace m_rel = "RELATIONSHIP: affected items are ordinary questionnaire questions with no effective enabling condition. They are not service fields; [" + ///
            trigger + "] is the nearest AnswerSet only." if reltype==3
        quietly replace m_rel = "RELATIONSHIP: affected field names were not found in the parsed questionnaire metadata; [" + ///
            trigger + "] is timing context only." if reltype==4
        quietly replace m_rel = "RELATIONSHIP: affected items mix questionnaire questions and fields absent from questionnaire metadata; no causal link was established." if reltype==5
        quietly replace m_rel = "RELATIONSHIP: questionnaire metadata was not supplied, so the relationship could not be assessed; the nearby AnswerSet is timing context only." if reltype==6

        quietly gen strL m_what = "REMOVAL HISTORY: " + strofreal(nrem) + ///
            " AnswerRemoved event(s) affected " + strofreal(nqrem) + ///
            " distinct question/roster instance(s)."
        quietly gen strL m_state = "CURRENT PARADATA STATE: " + strofreal(nreanswered) + ///
            " answered again; " + strofreal(nopen) + " still end in AnswerRemoved; " + ///
            strofreal(nunknown) + " have unknown state."
        quietly replace m_state = "FINAL DATA ASSESSMENT: " + strofreal(n_final_answered) + ///
            " answered; " + strofreal(n_expected_blank) + ///
            " blank as expected because final logic disables them; " + ///
            strofreal(n_answered_disabled) + " answered while disabled; " + ///
            strofreal(n_blank_enabled) + " blank while enabled; " + ///
            strofreal(n_logic_unknown) + " with logic unknown; " + ///
            strofreal(n_notindata) + " not found in supplied data." if final_data_checked

        quietly gen strL m_q = ""
        quietly gen strL m_s = ""
        quietly gen strL m_e = ""
        if `hasqxt' {
            quietly replace m_q = "ANSWER-EVENT QUESTION [" + trigger + "]: " + char(34) ///
                + substr(qx_text,1,160) + char(34) if qx_text!=""
            quietly replace m_s = "SECTION: " + substr(qx_section,1,60) if qx_section!=""
            quietly replace m_e = "This answer-event question is asked only when: " + ///
                substr(qx_enable,1,120) if qx_enable!=""
        }
        quietly gen strL m_w = "ALL AFFECTED ITEMS: " + wl if wl!=""
        quietly gen strL m_res = "ANSWERED AGAIN: " + wl_reanswered if wl_reanswered!=""
        quietly gen strL m_open = "CHECK IN FINAL DATA: " + wl_final_check if wl_final_check!=""
        quietly gen strL m_expected = "BLANK AS EXPECTED (DISABLED): " + ///
            wl_expected_blank if wl_expected_blank!=""
        quietly gen strL m_finalanswered = "ANSWERED IN FINAL DATA: " + ///
            wl_final_answered if wl_final_answered!=""

        quietly gen strL m_a = "NO ACTION NEEDED: final values are either present or correctly blank under the final questionnaire logic." ///
            if tier=="C" & final_data_checked
        quietly replace m_a = "NO ACTION NEEDED: keep this as interview history only." ///
            if tier=="C" & !final_data_checked
        quietly replace m_a = "NEXT STEP: review only these unresolved items in the final export: " + ///
            wl_final_check + ". Reject only when a value is blank AND the effective final logic evaluates to enabled." ///
            if tier=="V"
        quietly replace m_a = "PRIORITY CHECK: review these unresolved items and the exact history: " + ///
            wl_final_check + "." if tier=="A"
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
            file write `mf' "PARADATA SKIP/REMOVAL REVIEW" _n
            file write `mf' "Generated `c(current_date)' `c(current_time)' by suso paradata skips (suso v1.7.12)" _n
            file write `mf' "Definition: a case is `cascade' or more consecutive AnswerRemoved events in a compact run near an AnswerSet event." _n
            file write `mf' "`ncasc' case(s) found; `nwiped' removal event(s); `naffectedqall' distinct question-run case(s) affected." _n
            if `hasfinaldata' file write `mf' "Final export assessment: `nfinalansweredall' answered; `nanswereddisabledall' answered while disabled; `nexpectedblankall' blank as expected because disabled; `nfinalcheckall' require review." _n
            else file write `mf' "No data() supplied; `nopenall' still end in AnswerRemoved and `nunknownall' have unknown paradata state." _n
            file write `mf' _n "BOTTOM LINE: `=`ninv'+`nver'' finding(s) need attention - `nclr' cases are resolved and require no action." _n
            forvalues r = 1/`=_N' {
                if `rtag'[`r']!=1 continue
                file write `mf' _n "INVESTIGATE " (`reviewer'[`r']) ": " (strofreal(`ri'[`r'])) " interview(s) with priority unresolved histories, " (strofreal(`rq'[`r'])) " questions affected across sections." _n
                file write `mf' "  interviews: " (`rids'[`r']) _n
                file write `mf' "  do: open each in Headquarters and review the exact answer transition, unresolved variables, and final export." _n
            }
            forvalues r = 1/`=_N' {
                if `vtag'[`r']!=1 continue
                file write `mf' _n "VERIFY " (substr(interview__id[`r'],1,8)) " (" (cond(resp[`r']!="",resp[`r'],actor[`r'])) "): " (why[`r']) "." _n
            }
            if `nclr'>0 file write `mf' _n "Auto-cleared as routine: `clrline'." _n
            file write `mf' _n "Case-by-case detail below is for reference only." _n
        }
        di as txt _n "  {hline 70}"
        di as res "  BOTTOM LINE: `=`ninv'+`nver'' finding(s) need attention — `nclr' of `ncasc' cases are resolved (no action)."
        di as txt "  {hline 70}"
        forvalues r = 1/`=_N' {
            if `rtag'[`r']!=1 continue
            di as res "  INVESTIGATE  " (`reviewer'[`r']) as txt ": " (`ri'[`r']) " interview(s), " (`rq'[`r']) " unresolved questions."
            di as txt "               ids: " (`rids'[`r'])
            di as txt "               do: review the exact answer transition, unresolved variables, and final export."
        }
        forvalues r = 1/`=_N' {
            if `vtag'[`r']!=1 continue
            di as res "  VERIFY       " (substr(interview__id[`r'],1,8)) as txt "  " ///
                (cond(resp[`r']!="",resp[`r'],actor[`r'])) " — " (why[`r'])
        }
        if `nclr'>0 di as txt "  cleared      `clrline'"
        if !`hasqxt' di as txt "  tip: add qx(questionnaire.html) for question wording and stronger triage."
        if "`full'"=="" {
            di as txt "  (add the {bf:full} option for the complete case-by-case list)"
            local k 0
        }
        forvalues i = 1/`k' {
            di as txt ""
            di as res "  " m_head[`i']
            di as txt "  " m_event[`i']
            if m_finalevent[`i']!="" di as txt "  " m_finalevent[`i']
            di as txt "  " m_rel[`i']
            di as txt "  " m_what[`i']
            if `mh' {
                file write `mf' _n "----------------------------------------------------------------------" _n
                file write `mf' (m_head[`i']) _n
                file write `mf' (m_event[`i']) _n
                if m_finalevent[`i']!="" file write `mf' (m_finalevent[`i']) _n
                file write `mf' (m_rel[`i']) _n
                file write `mf' (m_what[`i']) _n
            }
            foreach mv in m_state m_a m_q m_s m_e m_w m_res m_finalanswered m_expected m_open {
                if `mv'[`i']!="" {
                    di as txt "  " `mv'[`i']
                    if `mh' file write `mf' (`mv'[`i']) _n
                }
            }
        }
        if `mh' {
            file write `mf' _n "----------------------------------------------------------------------" _n
            file write `mf' "General note: a historical removal run is not itself a problem. Review unresolved final states first; repeated questionnaire-linked patterns are secondary context." _n
            file close `mf'
            di as txt _n "  vendor/supervisor message file written: " as res `"`messages'"'
        }

        * ---- shareable Skip/Removal Review page (self-contained, printable) --------
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
            quietly gen str244 g_label = cond(reltype==1, ///
                cond(linkmode==2,"Indirect questionnaire relationship: ", ///
                cond(linkmode==3,"Direct and indirect questionnaire relationship: ", ///
                "Direct questionnaire relationship: ")) + ///
                cond(trigger!="",trigger,"(unknown)"), ///
                cond(reltype==3, "Questionnaire questions with no item-level condition shown", ///
                cond(reltype==4, "Fields outside questionnaire metadata", ///
                cond(reltype==5, "Mixed questionnaire/external fields", ///
                cond(reltype==6, "Questionnaire metadata not supplied", "Cause not identified")))))
            collapse (count) flips=__w (sum) wiped=__w, by(g_label) fast
            gsort -wiped -flips g_label
            quietly keep in 1/`=min(10,_N)'
            quietly save `"`GSUM'"'
            * Exact old/new transition is already stored in DET1.
            quietly use `"`DET1'"', clear
            if `haskey' quietly merge m:1 interview__id using `"`SKKEY'"', keep(master match) nogenerate
            capture confirm variable ikey
            if _rc quietly gen ikey = ""
            gsort -nqrem -nrem interview__id sk_run
            * pre-built display columns: data reaches the file only via (exp)
            quietly gen str120 h_ac = substr(cond(actor!="", actor, resp),1,120)
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
            quietly gen strL h_wl = substr(wlc,1,600)
            quietly gen strL h_event = transition_text
            quietly gen str40 h_eventstatus = transition_status
            quietly gen strL h_finalevent = trigger_final_text
            quietly gen strL h_check = wl_final_check
            quietly replace h_check = h_check + cond(h_check!="", " | ", "") + wl_unknown ///
                if wl_unknown!=""
            quietly gen strL h_key = ikey
            quietly gen str100 h_gkey = cond(reltype==1, ///
                cond(linkmode==2,"indirect:",cond(linkmode==3,"mixedlink:","direct:")) + trigger, ///
                cond(reltype==3, "always", cond(reltype==4, "external", ///
                cond(reltype==5, "mixed", cond(reltype==6, "noqx", "unlinked")))))
            quietly gen str244 h_group = cond(reltype==1, ///
                cond(linkmode==2,"Indirect questionnaire relationship: ", ///
                cond(linkmode==3,"Direct and indirect questionnaire relationship: ", ///
                "Direct questionnaire relationship: ")) + ///
                cond(trigger!="",trigger,"(unknown)"), ///
                cond(reltype==3, "Questionnaire questions with no item-level condition shown", ///
                cond(reltype==4, "Fields outside questionnaire metadata", ///
                cond(reltype==5, "Mixed questionnaire/external fields", ///
                cond(reltype==6, "Questionnaire metadata not supplied", "Cause not identified")))))
            foreach v in h_ac h_tg h_tv0 h_qt h_sc h_en h_wl h_event       ///
                h_eventstatus h_finalevent h_check h_key h_group {
                quietly replace `v' = subinstr(subinstr(subinstr(`v',"&","&amp;",.),"<","&lt;",.),">","&gt;",.)
            }

            quietly gen str12 h_class = cond(tier=="A","priority", ///
                cond(tier=="V","verify","resolved"))
            quietly gen strL h_open = "<div class=" + char(34) + "case " + ///
                h_class + char(34) + ">"
            quietly gen strL h_chip = "<div class=" + char(34) + "chip " + ///
                h_class + char(34) + ">Resolved - no action</div>" if tier=="C"
            quietly replace h_chip = "<div class=" + char(34) + "chip " + ///
                h_class + char(34) + ">Check final data - " + ///
                strofreal(cond(final_data_checked,n_final_check,nopen+nunknown)) + ///
                " question(s)</div>" if tier=="V"
            quietly replace h_chip = "<div class=" + char(34) + "chip " + ///
                h_class + char(34) + ">Priority check - " + ///
                strofreal(cond(final_data_checked,n_final_check,nopen+nunknown)) + ///
                " question(s)</div>" if tier=="A"

            quietly gen strL h_l1 = "<div class=" + char(34) + "c1" + char(34) + ">" ///
                + cond(h_key!="", "<b class=" + char(34) + "mono" + char(34) + ">" + h_key + "</b> &nbsp;&middot;&nbsp; <span class=" + char(34) + "mono small" + char(34) + ">" + interview__id + "</span>", ///
                       "<span class=" + char(34) + "mono" + char(34) + ">" + interview__id + "</span>") ///
                + " &nbsp;&middot;&nbsp; <b>" + h_ac + "</b> &nbsp;&middot;&nbsp; " ///
                + string(ts0/86400000, "%tdDD_Mon_CCYY") + " " + string(ts0, "%tcHH:MM") + " UTC</div>"

            quietly gen strL h_eventbox = "<div class=" + char(34) + "eventbox" + char(34) + "><div class=" + char(34) + "eventstatus" + char(34) + ">" + h_eventstatus + "</div><b>Historical answer event:</b> " + h_event
            quietly replace h_eventbox = h_eventbox + "<div class=" + char(34) + "eventquestion" + char(34) + "><b>Question:</b> &quot;" + h_qt + "&quot;</div>" if h_qt!=""
            quietly replace h_eventbox = h_eventbox + "</div>"
            quietly gen strL h_finalbox = ""
            quietly replace h_finalbox = "<div class=" + char(34) + "finalbox" + char(34) + "><b>Current final export:</b> " + h_finalevent + "</div>" if h_finalevent!=""
            quietly gen strL h_rel = "<div class=" + char(34) + "relbox" + char(34) + "><b>No questionnaire relationship found:</b> the answer event is shown only because it was nearest in the event sequence.</div>"
            quietly replace h_rel = "<div class=" + char(34) + "relbox linked" + char(34) + "><b>Direct questionnaire relationship:</b> " + strofreal(nlinked_direct) + " affected question/roster instance(s) directly reference <span class=" + char(34) + "mono" + char(34) + ">" + h_tg + "</span> in their enabling conditions. This does not prove cause by itself.</div>" if reltype==1 & linkmode==1
            quietly replace h_rel = "<div class=" + char(34) + "relbox linked" + char(34) + "><b>Indirect questionnaire relationship:</b> " + strofreal(nlinked_indirect) + " affected question/roster instance(s) depend on <span class=" + char(34) + "mono" + char(34) + ">" + h_tg + "</span> through calculated variables. This does not prove cause by itself.</div>" if reltype==1 & linkmode==2
            quietly replace h_rel = "<div class=" + char(34) + "relbox linked" + char(34) + "><b>Direct and indirect questionnaire relationship:</b> " + strofreal(nlinked_direct) + " affected instance(s) reference <span class=" + char(34) + "mono" + char(34) + ">" + h_tg + "</span> directly and " + strofreal(nlinked_indirect) + " depend on it through calculated variables. This does not prove cause by itself.</div>" if reltype==1 & linkmode==3
            quietly replace h_rel = "<div class=" + char(34) + "relbox" + char(34) + "><b>No questionnaire relationship found:</b> affected questions have enabling conditions, but none references <span class=" + char(34) + "mono" + char(34) + ">" + h_tg + "</span>.</div>" if reltype==2
            quietly replace h_rel = "<div class=" + char(34) + "relbox" + char(34) + "><b>Questionnaire questions with no effective enabling condition:</b> these are ordinary questionnaire variables, not service fields. <span class=" + char(34) + "mono" + char(34) + ">" + h_tg + "</span> is the nearest AnswerSet only.</div>" if reltype==3
            quietly replace h_rel = "<div class=" + char(34) + "relbox" + char(34) + "><b>Fields outside questionnaire metadata:</b> none of the affected names was found in the parsed questionnaire. The nearby AnswerSet is timing context only.</div>" if reltype==4
            quietly replace h_rel = "<div class=" + char(34) + "relbox" + char(34) + "><b>Mixed field types:</b> affected items include questionnaire questions and fields absent from questionnaire metadata. No causal link was established.</div>" if reltype==5
            quietly replace h_rel = "<div class=" + char(34) + "relbox" + char(34) + "><b>Questionnaire relationship not assessed:</b> no questionnaire metadata was supplied. The nearby AnswerSet is timing context only.</div>" if reltype==6

            quietly gen strL h_l2 = "<div class=" + char(34) + "c2" + char(34) + "><b>Removal history:</b> " + strofreal(nrem) + " AnswerRemoved event(s) affected <b>" + strofreal(nqrem) + "</b> distinct question/roster instance(s).</div>"
            quietly gen strL h_state = "<div class=" + char(34) + "state resolved" + char(34) + "><b>Final data assessment:</b> " + strofreal(n_final_answered) + " answered; " + strofreal(n_expected_blank) + " blank as expected because disabled; 0 require review.</div>" if tier=="C" & final_data_checked
            quietly replace h_state = "<div class=" + char(34) + "state resolved" + char(34) + "><b>Current paradata state:</b> all affected items were answered again.</div>" if tier=="C" & !final_data_checked
            quietly replace h_state = "<div class=" + char(34) + "state verify" + char(34) + "><b>Final data assessment:</b> " + strofreal(n_final_answered) + " answered; " + strofreal(n_expected_blank) + " blank as expected because disabled; " + strofreal(n_answered_disabled) + " answered while disabled; " + strofreal(n_blank_enabled) + " blank while enabled; " + strofreal(n_logic_unknown) + " logic unknown; " + strofreal(n_notindata) + " not in supplied data.</div>" if tier=="V"
            quietly replace h_state = "<div class=" + char(34) + "state priority" + char(34) + "><b>Final data assessment:</b> " + strofreal(n_final_answered) + " answered; " + strofreal(n_expected_blank) + " blank as expected because disabled; " + strofreal(n_final_check) + " require review.</div>" if tier=="A"

            quietly gen strL h_do = "<div class=" + char(34) + "action resolved" + char(34) + "><b>No action needed.</b> Final values are present or correctly blank under the final questionnaire logic.</div>" if tier=="C" & final_data_checked
            quietly replace h_do = "<div class=" + char(34) + "action resolved" + char(34) + "><b>No action needed.</b> Keep this only as interview history.</div>" if tier=="C" & !final_data_checked
            quietly replace h_do = "<div class=" + char(34) + "action verify" + char(34) + "><b>Review only:</b> <span class=" + char(34) + "mono" + char(34) + ">" + h_check + "</span>. A blank value is actionable only when effective final logic says enabled.</div>" if tier=="V"
            quietly replace h_do = "<div class=" + char(34) + "action priority" + char(34) + "><b>Priority review:</b> <span class=" + char(34) + "mono" + char(34) + ">" + h_check + "</span>. Also inspect the exact interview history.</div>" if tier=="A"

            quietly gen strL h_l3 = ""
            quietly replace h_l3 = "<blockquote><b>Answer-event question:</b> <span class=" + char(34) + "mono" + char(34) + ">" + h_tg + "</span>" + cond(h_qt!=""," &nbsp; &quot;" + h_qt + "&quot;","") + "</blockquote>" if h_tg!=""
            quietly gen strL h_l4 = ""
            quietly replace h_l4 = "Section: " + h_sc if h_sc!=""
            quietly replace h_l4 = h_l4 + cond(h_l4!="", " &nbsp;&middot;&nbsp; ", "") + "Asked only when: <span class=" + char(34) + "mono" + char(34) + ">" + h_en + "</span>" if h_en!=""
            quietly replace h_l4 = "<div class=" + char(34) + "meta" + char(34) + ">" + h_l4 + "</div>" if h_l4!=""
            quietly gen strL h_l5 = "<div class=" + char(34) + "meta" + char(34) + ">All affected items: <span class=" + char(34) + "mono" + char(34) + ">" + h_wl + cond(length(wlc)>600, " ...", "") + "</span></div>" if h_wl!=""
            quietly gen strL h_fa = "<div class=" + char(34) + "meta linked" + char(34) + ">Answered in final data: <span class=" + char(34) + "mono" + char(34) + ">" + wl_final_answered + "</span></div>" if wl_final_answered!=""
            quietly gen strL h_ad = "<div class=" + char(34) + "meta caution" + char(34) + ">Answered although disabled: <span class=" + char(34) + "mono" + char(34) + ">" + wl_answered_disabled + "</span></div>" if wl_answered_disabled!=""
            quietly gen strL h_eb = "<div class=" + char(34) + "meta linked" + char(34) + ">Blank as expected because disabled: <span class=" + char(34) + "mono" + char(34) + ">" + wl_expected_blank + "</span></div>" if wl_expected_blank!=""
            quietly gen strL h_l6 = "<div class=" + char(34) + "meta" + char(34) + ">AnswerSet order: " + string(trigger_ord,"%12.0g") + "; removal-run start: " + string(ts0,"%tcCCYY-NN-DD_HH:MM:SS") + "; raw removal events: " + strofreal(nrem) + ".</div>"
            quietly gen strL h_tech = "<details class=" + char(34) + "tech" + char(34) + "><summary>Technical details</summary>" + h_l3 + h_l4 + h_l5 + h_fa + h_ad + h_eb + h_l6 + "</details>"
            local ncheckall = `nfinalcheckall'
            local now = trim("`c(current_date)' `c(current_time)'")
            local wst ""
            if "$SUSO_WS"!="" local wst " — $SUSO_WS"
            tempname hf
            quietly file open `hf' using `"`html'"', write replace text
            file write `hf' `"<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Skip Removal Review</title><style>"' _n
            file write `hf' `"body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:#f4f5f7;color:#1a1a1a}"' _n
            file write `hf' `".logobar{background:#fff;padding:10px 28px;border-bottom:1px solid #e0e0e0}"' _n
            file write `hf' `".logobar .wbtxt{font-size:13px;letter-spacing:.06em;color:#002244;font-weight:600}.logobar .wbtxt span{color:#8a8a8a;font-weight:400}"' _n
            file write `hf' `".mast{background:#002244;color:#fff;padding:18px 28px}.mast h1{margin:0;font-size:21px;font-weight:600}.mast .sub{color:#c9d4e0;font-size:12.5px;margin-top:5px}"' _n
            file write `hf' `".wrap{max-width:900px;margin:0 auto;padding:16px 28px 40px}"' _n
            file write `hf' `".cards{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0}"' _n
            file write `hf' `".card{flex:1 1 140px;background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:10px 13px;border-top:3px solid #002244}"' _n
            file write `hf' `".card.warn{border-top-color:#c48a00}.card.dim{border-top-color:#9aa7b5}"' _n
            file write `hf' `".card .v{font-size:20px;font-weight:700;color:#002244}.card .k{font-size:11px;color:#666;margin-top:2px;text-transform:uppercase;letter-spacing:.04em}"' _n
            file write `hf' `".how{background:#fdf6e3;border:1px solid #ecd9a0;border-radius:8px;padding:12px 16px;font-size:13px;line-height:1.55;margin:12px 0}"' _n
            file write `hf' `"h2{font-size:15px;color:#002244;border-bottom:2px solid #C9A227;padding-bottom:4px;margin:22px 0 8px}"' _n
            file write `hf' `"table{border-collapse:collapse;width:100%;font-size:12.5px;background:#fff}"' _n
            file write `hf' `"th{background:#002244;color:#fff;text-align:left;padding:6px 8px;font-weight:600}td{padding:5px 8px;border-bottom:1px solid #eef0f2}td.r,th.r{text-align:right}"' _n
            file write `hf' `".case{background:#fff;border:1px solid #e3e6ea;border-left:4px solid #7b8794;border-radius:8px;padding:12px 16px;margin:10px 0;position:relative;page-break-inside:avoid}"' _n
            file write `hf' `".case.resolved{border-left-color:#2f7d4a}.case.verify{border-left-color:#c48a00}.case.priority{border-left-color:#a33}"' _n
            file write `hf' `".chip{position:absolute;top:10px;right:12px;border-radius:12px;font-size:11px;padding:3px 10px;font-weight:700}"' _n
            file write `hf' `".chip.resolved{background:#eaf5ec;color:#1e6b34;border:1px solid #bfe0c8}.chip.verify{background:#fdf6e3;color:#7a5b00;border:1px solid #ecd9a0}.chip.priority{background:#fbeaea;color:#8a1f1f;border:1px solid #e8bcbc}"' _n
            file write `hf' `".c1{font-size:12.5px;color:#444;margin-right:190px}.c2{font-size:13.5px;margin-top:8px;line-height:1.45}"' _n
            file write `hf' `".eventquestion{margin-top:5px;color:#44515f}.eventstatus{display:inline-block;margin:0 7px 4px 0;padding:2px 7px;border-radius:10px;background:#002244;color:#fff;font-size:10.5px;font-weight:700}.eventbox,.relbox,.finalbox{font-size:12.5px;line-height:1.5;border-radius:6px;padding:8px 10px;margin-top:7px;background:#f7f8fa;border:1px solid #e2e6ea}.finalbox{background:#edf5fb;border-color:#bfd4e5;color:#173b5e}.relbox.linked{background:#eef8f0;border-color:#cfe4d3}.state,.action{font-size:12.5px;line-height:1.45;border-radius:6px;padding:7px 10px;margin-top:7px}.state.resolved,.action.resolved{background:#eef7f0;color:#1e6b34}.state.verify,.action.verify{background:#fdf6e3;color:#6f5600}.state.priority,.action.priority{background:#fbeaea;color:#8a1f1f}"' _n
            file write `hf' `"blockquote{margin:8px 0;padding:8px 12px;background:#f7f8fa;border-left:3px solid #c9cfd6;font-size:12.5px;color:#333}"' _n
            file write `hf' `".meta{font-size:11.5px;color:#666;margin-top:4px}.meta.linked{color:#1e6b34}.caution{color:#7a5b00}.mono{font-family:Consolas,monospace}"' _n
            file write `hf' `".small{font-size:10.5px;color:#888}.tech{margin-top:8px}.tech summary{cursor:pointer;color:#556575;font-size:11.5px}.techsum{background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:8px 12px;margin:12px 0}.techsum>summary{cursor:pointer;color:#556575;font-size:12.5px;font-weight:600}"' _n
            file write `hf' `"details{margin:4px 0}summary.gate{cursor:pointer;font-size:13.5px;color:#002244;padding:8px 10px;background:#f5f7f9;border:1px solid #dce2e8;border-radius:6px;margin-top:14px}"' _n
            file write `hf' `".foot{font-size:11px;color:#777;margin-top:24px;line-height:1.5}"' _n
            file write `hf' `"@media print{body{background:#fff}.case{border:1px solid #bbb;border-left-width:4px}}"' _n
            file write `hf' `"</style></head><body>"' _n
            file write `hf' `"<div class="logobar"><!-- wbLogo slot: replace content with the base64 banner img -->"' _n
            file write `hf' `"<span class="wbtxt">THE WORLD BANK <span>| Development Economics - Policy Indicators</span> &nbsp;-&nbsp; ENTERPRISE SURVEYS <span>- What Businesses Experience</span></span></div>"' _n
            file write `hf' `"<div class="mast"><h1>Skip Removal Review`wst'</h1>"' _n
            file write `hf' `"<div class="sub">Generated `now' &nbsp;-&nbsp; a case is `cascade'+ compact consecutive AnswerRemoved events near an AnswerSet; final values may be restored later</div></div>"' _n
            file write `hf' `"<div class="wrap">"' _n
            file write `hf' `"<div class="cards">"' _n
            file write `hf' `"<div class="card"><div class="v">`ncasc'</div><div class="k">removal histories</div></div>"' _n
            file write `hf' `"<div class="card"><div class="v">`naffectedqall'</div><div class="k">question-run cases affected</div></div>"' _n
            file write `hf' `"<div class="card warn"><div class="v">`ncheckall'</div><div class="k">need final-data check</div></div>"' _n
            file write `hf' `"<div class="card"><div class="v">`nreansweredall'</div><div class="k">answered again later</div></div>"' _n
            file write `hf' `"<div class="card dim"><div class="v">`nwiped'</div><div class="k">technical removal events</div></div>"' _n
            file write `hf' `"</div>"' _n
            file write `hf' `"<div class="how"><b>How to read each card:</b> first read <b>Observed answer event</b>, which now states whether the exact question/roster instance changed value, repeated the same value, was first observed, or was re-entered after removal. Next read <b>Questionnaire relationship</b>, then the removal history and current state. When data() is supplied, blank-but-disabled questions move to <b>Resolved history</b>; only final blanks that are enabled, not evaluable, or absent from the supplied export remain under <b>Cases needing verification</b>. A questionnaire relationship is not automatic proof of cause.</div>"' _n
            quietly save `"`DET2'"'

            quietly use `"`GSUM'"', clear
            file write `hf' `"<details class="techsum"><summary>Technical pattern summary</summary>"' _n
            file write `hf' `"<div class="meta">This table counts raw removal histories. Cause not identified means no questionnaire relationship was found. A direct link means the conditions mention the variable; an indirect link means they mention a calculated variable that depends on it. Neither proves cause.</div>"' _n
            file write `hf' `"<table><tr><th>relationship / variable</th><th class="r">histories</th><th class="r">removal events</th></tr>"' _n
            forvalues i = 1/`=_N' {
                file write `hf' `"<tr><td>"' (g_label[`i']) `"</td><td class="r">"' (strofreal(flips[`i'])) `"</td><td class="r">"' (strofreal(wiped[`i'])) `"</td></tr>"' _n
            }
            file write `hf' `"</table></details>"' _n

            quietly use `"`DET2'"', clear
            file write `hf' `"<h2>Cases needing verification</h2>"' _n
            file write `hf' `"<div class="note">These cases contain at least one final blank that is enabled, whose effective logic could not be evaluated, or whose variable/roster instance is absent from the supplied data. Blank-but-disabled questions are resolved automatically.</div>"' _n
            quietly count if tier!="C"
            local nact = r(N)
            if `nact'>0 {
                quietly keep if tier!="C"
                quietly gen long __check = nopen + nunknown
                tempvar gw gi ge tgi tge gc2
                quietly egen long `gw'  = total(__check), by(h_gkey)
                quietly egen byte `tgi' = tag(h_gkey interview__id)
                quietly egen long `gi'  = total(`tgi'), by(h_gkey)
                quietly egen byte `tge' = tag(h_gkey h_ac)
                quietly egen long `ge'  = total(`tge'), by(h_gkey)
                quietly egen long `gc2' = count(nrem), by(h_gkey)
                gsort -`gw' h_gkey -__check -nqrem interview__id sk_run
                quietly gen byte __gf = 1
                quietly replace __gf = h_gkey != h_gkey[_n-1] if _n>1
                local ing 0
                forvalues i = 1/`=_N' {
                    if __gf[`i'] {
                        if `ing' file write `hf' `"</details>"' _n
                        local ing 1
                        file write `hf' `"<details open><summary class="gate"><b>"' (h_group[`i']) `"</b> &nbsp;-&nbsp; "' (strofreal(`gc2'[`i'])) `" case(s), "' (strofreal(`gw'[`i'])) `" question(s) to check, in "' (strofreal(`gi'[`i'])) `" interview(s)</summary>"' _n
                    }
                    file write `hf' (h_open[`i']) _n
                    file write `hf' (h_chip[`i']) _n
                    file write `hf' (h_l1[`i']) _n
                    file write `hf' (h_eventbox[`i']) _n
                    if h_finalbox[`i']!="" file write `hf' (h_finalbox[`i']) _n
                    file write `hf' (h_rel[`i']) _n
                    file write `hf' (h_l2[`i']) _n
                    file write `hf' (h_state[`i']) _n
                    file write `hf' (h_do[`i']) _n
                    file write `hf' (h_tech[`i']) _n
                    file write `hf' `"</div>"' _n
                }
                if `ing' file write `hf' `"</details>"' _n
            }
            else file write `hf' `"<div class="state resolved"><b>No final-data checks are indicated.</b> Every affected item is answered or correctly blank under the final questionnaire logic.</div>"' _n

            quietly use `"`DET2'"', clear
            file write `hf' `"<h2>Resolved history - no action</h2>"' _n
            file write `hf' `"<details><summary style="cursor:pointer;font-size:13px;color:#555;padding:6px 0">Show `nclr' resolved historical case(s)</summary>"' _n
            local wr 0
            forvalues i = 1/`=_N' {
                if tier[`i']!="C" continue
                if `wr'>=200 continue
                local ++wr
                file write `hf' (h_open[`i']) _n
                file write `hf' (h_chip[`i']) _n
                file write `hf' (h_l1[`i']) _n
                file write `hf' (h_eventbox[`i']) _n
                if h_finalbox[`i']!="" file write `hf' (h_finalbox[`i']) _n
                file write `hf' (h_rel[`i']) _n
                file write `hf' (h_l2[`i']) _n
                file write `hf' (h_state[`i']) _n
                file write `hf' (h_do[`i']) _n
                file write `hf' (h_tech[`i']) _n
                file write `hf' `"</div>"' _n
            }
            file write `hf' `"</details>"' _n
            if `nclr'>200 file write `hf' `"<div class="meta">Showing the first 200 of `nclr' resolved historical cases.</div>"' _n
            file write `hf' `"<div class="foot">Produced by suso paradata skips (suso v1.7.12). Cases are screening signals from the paradata event stream, not proof of misconduct.</div>"' _n
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
    return scalar nwiped       = `nwiped'
    return scalar nremovalevents = `nremevents'
    return scalar naffectedquestions = `naffectedqall'
    return scalar nreanswered    = `nreansweredall'
    return scalar nopen          = `nopenall'
    return scalar nunknown       = `nunknownall'
    return scalar nfinalanswered = `nfinalansweredall'
    return scalar nanswereddisabled = `nanswereddisabledall'
    return scalar nexpectedblank = `nexpectedblankall'
    return scalar nblankenabled  = `nblankenabledall'
    return scalar nlogicunknown  = `nlogicunknownall'
    return scalar nnotindata     = `nnotindataall'
    return scalar nfinalcheck    = `nfinalcheckall'
    return scalar hasfinaldata   = `hasfinaldata'
    return scalar naffected      = `naff'
end

* ---- report: dynamic self-contained HTML QC report ------------------------------
* All data is embedded as JSON; vanilla JS (no CDN, works offline) recomputes
* every figure and table live as the user filters by enumerator, searches
* questions, or moves the flag thresholds / night window.
program _suso_para_report, rclass
    version 14.2
    syntax [, SAVing(string) replace TITle(string) QX(string)                    ///
        DATA(string) FILTERS(string) VARS(string)                                ///
        GAPMins(real 30) FASTsecs(real 2) ALLRoles                               ///
        CASCade(integer 3) WINdow(real 60) LITEcap(integer 15000) ]
    _suso_para_need events
    tempfile EVFULL
    quietly save `"`EVFULL'"'
    _suso_para_varsel , vars(`"`vars'"')

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
    tempfile EV EVD SK QT QTK DAILY HHF GGF MERGED RSD WS FLK                    ///
        KEYF MODEF TZF REJF OVF PCEF VERF NQF RTF FRF
    quietly save `"`EV'"'
    local nevents = _N

    _suso_para_derive , gapmins(`gapmins') fastsecs(`fastsecs') `allroles'
    local rolenote `"`r(rolenote)'"'
    quietly save `"`EVD'"'

    * coverage of the event stream (freshness line in the header)
    quietly summarize para_tsu
    local cov0 ""
    local cov1 ""
    if r(N)>0 {
        local cov0 : di %tcCCYY-NN-DD r(min)
        local cov1 : di %tcCCYY-NN-DD r(max)
        local cov0 = trim("`cov0'")
        local cov1 = trim("`cov1'")
    }

    * variable-filter lookup from the main export: value per interview + labels
    local fdimvars ""
    local jfdims ""
    if `"`data'"'!="" & `"`filters'"'!="" {
        preserve
        quietly use `"`data'"', clear
        capture confirm variable interview__id
        if _rc di as txt "  filters(): data() has no interview__id - variable filters skipped."
        else {
            local __fvb 0
            foreach fvv of local filters {
                capture confirm numeric variable `fvv'
                if _rc {
                    di as txt "  filters(): " as res "`fvv'" as txt " not found or not numeric in data() - skipped."
                    continue
                }
                quietly levelsof `fvv', local(fl)
                local nfl : word count `fl'
                if `nfl'==0 | `nfl'>20 | `__fvb'+`nfl'>40 {
                    di as txt "  filters(): " as res "`fvv'" as txt " skipped (`nfl' values; limit 20 per variable, 40 total)."
                    continue
                }
                local __fvb = `__fvb' + `nfl'
                local fdimvars "`fdimvars' `fvv'"
                local jv1 ""
                foreach s of local fl {
                    local lb : label (`fvv') `s'
                    local lb = subinstr(subinstr(`"`lb'"', char(34), "", .), char(92), "", .)
                    local jv1 `"`jv1'`=cond(`"`jv1'"'=="","",",")'{"c":"`s'","l":"`lb'"}"'
                }
                local jfdims `"`jfdims'`=cond(`"`jfdims'"'=="","",",")'{"v":"`fvv'","vals":[`jv1']}"'
            }
            local fdimvars = strtrim("`fdimvars'")
            if "`fdimvars'"!="" {
                quietly keep interview__id `fdimvars'
                quietly bysort interview__id: keep if _n==1
                foreach fvv of local fdimvars {
                    quietly rename `fvv' f__`fvv'
                }
                quietly save `"`FLK'"'
            }
        }
        restore
    }

    * ---- question timing table (medians reflect newly-reached questions only) ----
    local hasq 0
    capture confirm variable para_var
    if !_rc {
        quietly keep if para_fieldans & para_var!=""
        if _N>0 {
            local hasq 1
            tempvar tag
            quietly bysort para_var interview__id: gen byte `tag' = _n==1
            collapse (sum) qn=para_one qni=`tag' qnf=para_fast (count) qnt=para_ansgap ///
                (p50) qmed=para_ansgap (p90) qp90=para_ansgap, by(para_var) fast
            quietly gen double qfsh = qnf/qnt if qnt>0
            gsort -qmed para_var
            quietly save `"`QT'"'
            quietly keep para_var qmed
            quietly keep if !missing(qmed)
            quietly save `"`QTK'"'
        }
    }

    * ---- interviewer-day volume + lite decision ----------------------------------
    quietly use `"`EVD'"', clear
    quietly keep if para_fieldans & !missing(para_tsu)
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
        quietly keep if para_fieldans & !missing(para_tsl)
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

    * ---- workflow state at the last status event ----------------------------------
    local hasws 0
    quietly use `"`EVD'"', clear
    * SuSo logs rejections in the past tense but approvals without the d
    * (RejectedBySupervisor vs ApproveBySupervisor) - normalise before matching
    quietly gen __evn = subinstr(subinstr(para_ev, "approved", "approve", .), "rejected", "reject", .)
    quietly keep if inlist(__evn, "completed", "restarted", "rejectbysupervisor", "approvebysupervisor") ///
        | inlist(__evn, "approvebyheadquarter", "approvebyheadquarters", "rejectbyheadquarter", "rejectbyheadquarters", "unapprovebyheadquarters")
    if _N>0 {
        local hasws 1
        quietly bysort interview__id (para_ord para_seq): keep if _n==_N
        quietly gen ws = "Completed"
        quietly replace ws = "In progress"      if __evn=="restarted"
        quietly replace ws = "Approved by Sup"  if __evn=="approvebysupervisor"
        quietly replace ws = "Rejected by Sup"  if __evn=="rejectbysupervisor"
        quietly replace ws = "Approved by HQ"   if inlist(__evn, "approvebyheadquarter", "approvebyheadquarters")
        quietly replace ws = "Rejected by HQ"   if inlist(__evn, "rejectbyheadquarter", "rejectbyheadquarters")
        quietly replace ws = "Unapproved by HQ" if __evn=="unapprovebyheadquarters"
        quietly keep interview__id ws
        quietly save `"`WS'"'
    }

    * ---- NEW: interview key (what the supervisor types into Headquarters) --------
    * KeyAssigned parameters carry the NN-NN-NN-NN key; the latest event is current.
    local haskey 0
    quietly use `"`EVD'"', clear
    quietly keep if para_ev=="keyassigned"
    if _N>0 {
        capture confirm string variable parameters
        if !_rc {
            local haskey 1
            quietly bysort interview__id (para_ord para_seq): keep if _n==_N
            quietly gen ikey = substr(strtrim(parameters), 1, 12)
            quietly keep interview__id ikey
            quietly save `"`KEYF'"'
        }
    }

    * ---- NEW: interview mode (CAPI vs CAWI) ---------------------------------------
    * A CAWI (self-administered web) interview has respondent-driven timing: speed,
    * burst, night and duration flags are meaningless there and are suppressed.
    local hascawi 0
    quietly use `"`EVD'"', clear
    quietly keep if para_ev=="interviewmodechanged"
    if _N>0 {
        capture confirm string variable parameters
        if !_rc {
            quietly bysort interview__id (para_ord para_seq): keep if _n==_N
            quietly gen byte iscawi = strpos(lower(parameters), "cawi")>0
            quietly count if iscawi
            if r(N)>0 local hascawi 1
            quietly keep interview__id iscawi
            quietly save `"`MODEF'"'
        }
    }
    capture confirm file `"`MODEF'"'
    if _rc {
        quietly clear
        quietly set obs 0
        quietly gen interview__id = ""
        quietly gen byte iscawi = 0
        quietly save `"`MODEF'"'
    }

    * ---- NEW: device-clock sanity (timezone offsets) ------------------------------
    * Night-work times come from the tablet clock. A tablet whose timezone differs
    * from the team, or changes mid-interview, cannot be trusted for time-of-day.
    quietly use `"`EVD'"', clear
    * tablet clock = interviewer-side events only; supervisor/HQ web actions carry
    * the browser or server offset and would fake a "changed mid-interview" signal
    * on every rejected or approved interview
    quietly keep if para_ivw
    quietly contract interview__id para_off, freq(__pk)
    quietly drop if missing(para_off)
    * an offset must back >=5 events to count at all (a stray event is not a clock)
    quietly drop if __pk<5
    local tzmode 0
    if _N>0 {
        preserve
        collapse (sum) __pk, by(para_off) fast
        gsort -__pk para_off
        local tzmode = para_off[1]
        restore
        gsort interview__id -__pk para_off
        quietly bysort interview__id: gen __k = _N
        quietly by interview__id: keep if _n==1
        quietly gen double tzh   = para_off/3600000
        quietly gen byte   tzodd = (para_off!=`tzmode') | (__k>1)
        quietly keep interview__id tzh tzodd
        quietly save `"`TZF'"'
    }
    else {
        quietly clear
        quietly set obs 0
        quietly gen interview__id = ""
        quietly gen double tzh = .
        quietly gen byte tzodd = 0
        quietly save `"`TZF'"'
    }
    local tzmodeh : di %4.1f `tzmode'/3600000
    local tzmodeh = trim("`tzmodeh'")

    * ---- NEW: rejection bounce-backs ----------------------------------------------
    * For every rejection, how quickly was the interview re-completed and how many
    * answers were actually changed before that re-completion? A re-completion with
    * zero changes means the supervisor's rejection was simply bounced straight back.
    quietly use `"`EVD'"', clear
    sort interview__id para_ord para_seq
    quietly by interview__id: gen double __ca = sum(para_fieldans | para_fieldrem)
    quietly gen double __cts = para_tsu if para_cmp
    quietly gen double __cca = __ca     if para_cmp
    gsort interview__id -para_ord -para_seq
    quietly by interview__id: replace __cts = __cts[_n-1] if missing(__cts) & _n>1
    quietly by interview__id: replace __cca = __cca[_n-1] if missing(__cca) & _n>1
    sort interview__id para_ord para_seq
    quietly keep if para_rej
    if _N>0 {
        quietly gen double rbm = (__cts - para_tsu)/60000
        quietly replace rbm = 0 if rbm<0
        quietly gen double rbe = __cca - __ca
        quietly replace rbe = . if missing(rbm)
        sort interview__id rbe rbm
        quietly by interview__id: keep if _n==1
        quietly keep interview__id rbm rbe
        quietly save `"`REJF'"'
    }
    else {
        quietly clear
        quietly set obs 0
        quietly gen interview__id = ""
        quietly gen double rbm = .
        quietly gen double rbe = .
        quietly save `"`REJF'"'
    }

    * ---- NEW: same-minute cross-interview answering -------------------------------
    * One person cannot interview two respondents at once. Minutes in which the same
    * enumerator recorded answers in two or more (non-CAWI) interviews are counted
    * against every interview involved. Repeated cross-minutes = desk work.
    quietly use `"`EVD'"', clear
    local hasov 0
    capture confirm string variable responsible
    if !_rc {
        quietly keep if para_fieldans & responsible!="" & !missing(para_tsu)
        if _N>0 {
            quietly merge m:1 interview__id using `"`MODEF'"', keep(master match) nogenerate
            quietly drop if iscawi==1
        }
        if _N>0 {
            local hasov 1
            quietly gen double __mb = floor(para_tsu/60000)
            quietly contract responsible __mb interview__id
            quietly bysort responsible __mb: gen __nI = _N
            quietly keep if __nI>=2
            if _N>0 {
                collapse (count) ovm=__nI, by(interview__id) fast
                quietly save `"`OVF'"'
            }
            else local hasov 0
        }
    }
    if !`hasov' {
        quietly clear
        quietly set obs 0
        quietly gen interview__id = ""
        quietly gen long ovm = 0
        quietly save `"`OVF'"', replace
    }

    * ---- NEW: answers set after the first completion ------------------------------
    quietly use `"`EVD'"', clear
    tempvar fct fmin
    quietly gen double `fct' = para_tsu if para_cmp
    quietly egen double `fmin' = min(`fct'), by(interview__id)
    quietly gen byte __pc1 = para_fieldans & !missing(`fmin') & para_tsu>`fmin'
    collapse (sum) pce=__pc1, by(interview__id) fast
    quietly save `"`PCEF'"'

    * ---- NEW: validation errors still open at the end (full exports only) ---------
    local hasve 0
    quietly use `"`EVD'"', clear
    capture confirm variable para_var
    if !_rc {
        quietly keep if (para_inv | para_ev=="questiondeclaredvalid") & para_var!=""
        if _N>0 {
            local hasve 1
            quietly bysort interview__id para_var (para_ord para_seq): keep if _n==_N
            quietly gen byte __bad = para_inv
            collapse (sum) verr=__bad, by(interview__id) fast
            quietly save `"`VERF'"'
        }
    }
    if !`hasve' {
        quietly clear
        quietly set obs 0
        quietly gen interview__id = ""
        quietly gen long verr = .
        quietly save `"`VERF'"', replace
    }

    * ---- NEW: distinct questions answered (coverage) ------------------------------
    local hasnq 0
    quietly use `"`EVD'"', clear
    capture confirm variable para_var
    if !_rc {
        quietly keep if para_fieldans & para_var!=""
        if _N>0 {
            local hasnq 1
            quietly bysort interview__id para_var: keep if _n==1
            collapse (count) nq=para_one, by(interview__id) fast
            quietly save `"`NQF'"'
        }
    }
    if !`hasnq' {
        quietly clear
        quietly set obs 0
        quietly gen interview__id = ""
        quietly gen long nq = .
        quietly save `"`NQF'"', replace
    }

    * ---- NEW: peer-relative speed (controls for question mix) ---------------------
    * Expected time = sum over this interview's timed questions of the survey-median
    * seconds for those same questions. An interview finishing its own question mix
    * in a small fraction of the time colleagues need is speeding relative to peers,
    * whatever the absolute thresholds.
    local hasrt 0
    if `hasq' {
        quietly use `"`EVD'"', clear
        quietly keep if !missing(para_ansgap) & para_var!=""
        if _N>0 {
            quietly merge m:1 para_var using `"`QTK'"', keep(master match) nogenerate
            collapse (sum) __act=para_ansgap __exp=qmed, by(interview__id) fast
            quietly gen double rt = __act/__exp if __exp>0
            quietly keep interview__id rt
            quietly keep if !missing(rt)
            if _N>0 {
                local hasrt 1
                quietly save `"`RTF'"'
            }
        }
    }
    if !`hasrt' {
        quietly clear
        quietly set obs 0
        quietly gen interview__id = ""
        quietly gen double rt = .
        quietly save `"`RTF'"', replace
    }

    * ---- NEW: longest fast streak ------------------------------------------------
    * Honest interviews scatter their quick answers; fabricated ones produce runs.
    * The streak counts consecutive newly-reached questions each answered in under
    * fastsecs seconds (same-question repeat taps are already excluded upstream).
    quietly use `"`EVD'"', clear
    quietly keep if !missing(para_ansgap)
    if _N>0 {
        sort interview__id para_ord para_seq
        tempvar isf rise runid rlen
        quietly gen byte `isf' = (para_fast==1)
        quietly by interview__id: gen byte `rise' = `isf' & (`isf'[_n-1]!=1 | _n==1)
        quietly by interview__id: gen double `runid' = sum(`rise')
        quietly bysort interview__id `runid' `isf': gen long `rlen' = _N*`isf'
        collapse (max) fr=`rlen', by(interview__id) fast
        quietly save `"`FRF'"'
    }
    else {
        quietly clear
        quietly set obs 0
        quietly gen interview__id = ""
        quietly gen long fr = 0
        quietly save `"`FRF'"'
    }

    * ---- skip cascades ------------------------------------------------------------
    quietly use `"`EVFULL'"', clear
    quietly _suso_para_skips , cascade(`cascade') window(`window') qx(`"`qx'"') ///
        data(`"`data'"') detail(`"`RSD'"') vars(`"`vars'"') `allroles'
    local ncasc = r(ncascades)
    local nwiped = r(nwiped)
    local naffectedq = r(naffectedquestions)
    local nopen = r(nopen)
    local nreanswered = r(nreanswered)
    local nunknown = r(nunknown)
    local nfinalanswered = r(nfinalanswered)
    local nanswereddisabled = r(nanswereddisabled)
    local nexpectedblank = r(nexpectedblank)
    local nfinalcheck = r(nfinalcheck)
    local hasfinaldata = r(hasfinaldata)
    local trignames `"`r(triggers)'"'
    tempname RT
    capture matrix `RT' = r(triggers_stats)
    quietly keep interview__id n_cascades casc_removed casc_questions casc_open ///
        casc_reanswered casc_unknown casc_finalanswered casc_answered_disabled ///
        casc_expectedblank                                                       ///
        casc_blank_enabled casc_logicunknown casc_notindata casc_finalcheck      ///
        casc_datachecked n_triggers
    quietly save `"`SK'"'

    * ---- timing + flags (defaults; live thresholds are client-side) ---------------
    quietly use `"`EVD'"', clear
    quietly _suso_para_timing , by(interview) gapmins(`gapmins') fastsecs(`fastsecs') `allroles'
    quietly _suso_para_flags
    quietly merge 1:1 interview__id using `"`SK'"', nogenerate
    foreach v in n_cascades casc_removed casc_questions casc_open casc_reanswered ///
        casc_unknown casc_finalanswered casc_answered_disabled casc_expectedblank ///
        casc_blank_enabled                                                       ///
        casc_logicunknown casc_notindata casc_finalcheck casc_datachecked n_triggers {
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
    quietly gen ws = "In progress"
    if `hasws' {
        quietly rename ws __wsfill
        quietly merge 1:1 interview__id using `"`WS'"', nogenerate
        quietly replace ws = "In progress" if ws==""
        quietly drop __wsfill
    }
    quietly replace ws = "" if !started
    label variable ws "workflow state at last paradata event"
    if "`fdimvars'"!="" {
        quietly merge 1:1 interview__id using `"`FLK'"', keep(master match) nogenerate
    }
    * merge the new per-interview signals
    quietly gen ikey = ""
    if `haskey' {
        quietly rename ikey __ikfill
        quietly merge 1:1 interview__id using `"`KEYF'"', keep(master match) nogenerate
        quietly replace ikey = "" if missing(ikey)
        quietly drop __ikfill
    }
    quietly merge 1:1 interview__id using `"`MODEF'"', keep(master match) nogenerate
    quietly replace iscawi = 0 if missing(iscawi)
    quietly merge 1:1 interview__id using `"`TZF'"',  keep(master match) nogenerate
    quietly replace tzodd = 0 if missing(tzodd)
    quietly merge 1:1 interview__id using `"`REJF'"', keep(master match) nogenerate
    quietly merge 1:1 interview__id using `"`OVF'"',  keep(master match) nogenerate
    quietly replace ovm = 0 if missing(ovm)
    quietly merge 1:1 interview__id using `"`PCEF'"', keep(master match) nogenerate
    quietly replace pce = 0 if missing(pce)
    quietly merge 1:1 interview__id using `"`VERF'"', keep(master match) nogenerate
    quietly merge 1:1 interview__id using `"`NQF'"',  keep(master match) nogenerate
    quietly merge 1:1 interview__id using `"`RTF'"',  keep(master match) nogenerate
    quietly merge 1:1 interview__id using `"`FRF'"',  keep(master match) nogenerate
    quietly replace fr = 0 if missing(fr)
    quietly gen __d0 = string(dofc(t_first), "%tdCCYY-NN-DD")
    quietly replace __d0 = "" if missing(t_first)
    char _dta[suso_paradata] timing
    local nints = _N
    quietly count if started
    local nstarted = r(N)
    quietly count if n_completed>0
    local ncompleted = r(N)
    local nuntouched = `nints' - `nstarted'
    quietly count if started & iscawi
    local ncawi = r(N)
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
    local warnc = cond((`nopen'+`nunknown')>0, "warn", "dim")
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
    file write `fh' `".wrap{max-width:1080px;margin:0 auto;padding:16px 28px 40px}"' _n
    file write `fh' `".cards{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0 4px}"' _n
    file write `fh' `".card{flex:1 1 130px;background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:10px 13px;border-top:3px solid #002244}"' _n
    file write `fh' `".card.dim{border-top-color:#9aa7b5}.card.warn{border-top-color:#C9A227}.card.bad{border-top-color:#a33}"' _n
    file write `fh' `".card .v{font-size:20px;font-weight:700;color:#002244}"' _n
    file write `fh' `".card .k{font-size:11px;color:#666;margin-top:2px;text-transform:uppercase;letter-spacing:.04em}"' _n
    file write `fh' `".panel{background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:12px 16px;margin:12px 0;position:sticky;top:0;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.06)}"' _n
    file write `fh' `".prow{display:flex;flex-wrap:wrap;gap:14px;align-items:flex-end}"' _n
    file write `fh' `".prow+.prow{margin-top:10px;padding-top:10px;border-top:1px dashed #e3e6ea}"' _n
    file write `fh' `".ctrl{display:flex;flex-direction:column;gap:3px}"' _n
    file write `fh' `".ctrl label{font-size:10.5px;color:#555;text-transform:uppercase;letter-spacing:.03em}"' _n
    file write `fh' `".ctrl input,.ctrl select{font-size:13px;padding:4px 6px;border:1px solid #c9cfd6;border-radius:5px;min-width:64px}"' _n
    file write `fh' `"#c_resp{min-width:210px}"' _n
    file write `fh' `".pbtn{background:#002244;color:#fff;border:0;border-radius:5px;padding:7px 14px;font-size:12.5px;cursor:pointer}"' _n
    file write `fh' `".pbtn.ghost{background:#fff;color:#002244;border:1px solid #c9cfd6}"' _n
    file write `fh' `".verdict{margin:10px 0;padding:10px 14px;border-radius:8px;font-size:13.5px;font-weight:600}"' _n
    file write `fh' `".verdict.ok{background:#eaf5ec;color:#1e6b34;border:1px solid #bfe0c8}"' _n
    file write `fh' `".verdict.warn{background:#fdf6e3;color:#7a5b00;border:1px solid #ecd9a0}"' _n
    file write `fh' `".verdict.bad{background:#fbeaea;color:#8a1f1f;border:1px solid #e8bcbc}"' _n
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
    file write `fh' `".tier{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:700;letter-spacing:.03em}"' _n
    file write `fh' `".tier.A{background:#fbeaea;color:#8a1f1f;border:1px solid #e8bcbc}"' _n
    file write `fh' `".tier.V{background:#fdf6e3;color:#7a5b00;border:1px solid #ecd9a0}"' _n
    file write `fh' `".tier.W{background:#eef3f8;color:#2a4a6b;border:1px solid #c9d4e0}"' _n
    file write `fh' `".chip{display:inline-block;margin:1px 3px 1px 0;padding:1px 7px;border-radius:9px;font-size:10.5px;background:#eef3f8;color:#2a4a6b;border:1px solid #c9d4e0;cursor:default}"' _n
    file write `fh' `".chip.hard{background:#fbeaea;color:#8a1f1f;border-color:#e8bcbc;font-weight:700}"' _n
    file write `fh' `".chip.info{background:#f2f2f2;color:#666;border-color:#ddd}"' _n
    file write `fh' `".ev{font-size:12px;color:#333;margin-top:3px;line-height:1.45}"' _n
    file write `fh' `".ev .cav{color:#8a6d00}"' _n
    file write `fh' `".wrow{cursor:pointer}"' _n
    file write `fh' `".wdet td{background:#f7f9fb !important;border-left:3px solid #C9A227}"' _n
    file write `fh' `".wdet .facts{font-size:12px;color:#444;margin:4px 0 8px}"' _n
    file write `fh' `".cpy{display:inline-block;margin-left:6px;padding:0 6px;border:1px solid #c9cfd6;border-radius:4px;font-size:10.5px;color:#2a4a6b;cursor:pointer;background:#fff}"' _n
    file write `fh' `".cpy:hover{background:#eef3f8}"' _n
    file write `fh' `".legend{font-size:11.5px;color:#555;margin:6px 0 2px}"' _n
    file write `fh' `"@media print{.panel{position:static;box-shadow:none}.pbtn,.cpy{display:none}}"' _n
    file write `fh' `"</style></head><body>"' _n
    file write `fh' `"<div class="logobar"><!-- wbLogo slot: replace content with the base64 banner img (class wbLogo) -->"' _n
    file write `fh' `"<span class="wbtxt">THE WORLD BANK <span>| Development Economics - Policy Indicators</span> &nbsp;-&nbsp; ENTERPRISE SURVEYS <span>- What Businesses Experience</span></span></div>"' _n
    file write `fh' `"<div class="mast"><h1>`htitle'</h1>"' _n
    local sub "Generated `now'"
    if "$SUSO_BASE"!="" local sub "`sub' &nbsp;-&nbsp; $SUSO_BASE"
    if "$SUSO_GUID"!="" local sub "`sub' &nbsp;-&nbsp; questionnaire $SUSO_GUID v$SUSO_QVER"
    local covline ""
    if "`cov0'"!="" local covline " &nbsp;-&nbsp; events `cov0' to `cov1'"
    file write `fh' `"<div class="sub">`sub' &nbsp;-&nbsp; `nevents' paradata events`covline'</div></div>"' _n
    file write `fh' `"<div class="wrap">"' _n
    file write `fh' `"<div class="cards">"' _n
    file write `fh' `"<div class="card dim"><div class="v">`nintsc'</div><div class="k">records in paradata</div></div>"' _n
    file write `fh' `"<div class="card"><div class="v">`nstartedc'</div><div class="k">fieldwork started</div></div>"' _n
    file write `fh' `"<div class="card"><div class="v">`ncompletedc'</div><div class="k">completed</div></div>"' _n
    file write `fh' `"<div class="card dim"><div class="v">`nuntouchedc'</div><div class="k">never started (preload only)</div></div>"' _n
    file write `fh' `"<div class="card"><div class="v">`tothrc'</div><div class="k">interviewer hours</div></div>"' _n
    file write `fh' `"<div class="card `warnc'"><div class="v">`ncasc'</div><div class="k">removal histories (`nfinalcheck' need review; `nexpectedblank' correctly blank; `nfinalanswered' answered; `nanswereddisabled' answered while disabled)</div></div>"' _n
    file write `fh' `"</div>"' _n
    file write `fh' `"<div class="panel">"' _n
    file write `fh' `"<div class="prow">"' _n
    file write `fh' `"<div class="ctrl"><label>Enumerator</label><select id="c_resp"></select></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Interview status</label><select id="c_ws"></select></div>"' _n
    file write `fh' `"<div class="ctrl" id="ctl_fd"><label>Filter variable</label><select id="c_fd"></select></div>"' _n
    file write `fh' `"<div class="ctrl" id="ctl_fv"><label>= value</label><select id="c_fv"></select></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Sensitivity</label><select id="c_preset"><option value="standard">Standard</option><option value="lenient">Lenient (fewer flags)</option><option value="strict">Strict (more flags)</option><option value="custom">Custom</option></select></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Show top</label><input id="c_top" type="number" min="5" max="200" step="5" value="25"></div>"' _n
    file write `fh' `"<button id="c_adv" class="pbtn ghost">Advanced thresholds</button>"' _n
    file write `fh' `"<button id="c_reset" class="pbtn">Reset</button>"' _n
    file write `fh' `"<span id="lite_note"></span>"' _n
    file write `fh' `"</div>"' _n
    file write `fh' `"<div class="prow" id="advrow" style="display:none">"' _n
    file write `fh' `"<div class="ctrl"><label title="An answer arriving faster than this is a fast answer">Fast answer &lt; sec</label><input id="c_fs" type="number" min="0.5" max="10" step="0.5"></div>"' _n
    file write `fh' `"<div class="ctrl"><label title="Flag a streak of this many consecutive answers, each faster than the fast-answer cutoff fixed at build time">Burst run &ge;</label><input id="c_burst" type="number" min="3" max="40" step="1" value="8"></div>"' _n
    file write `fh' `"<div class="ctrl"><label title="A completed interview under this active time is too short">Min active min</label><input id="c_minact" type="number" min="1" max="240" step="1" value="10"></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Night from</label><select id="c_n1"></select></div>"' _n
    file write `fh' `"<div class="ctrl"><label>Night to</label><select id="c_n2"></select></div>"' _n
    file write `fh' `"<div class="ctrl"><label title="Flag when this share of answers falls in the night window">Night share %</label><input id="c_nshare" type="number" min="1" max="100" step="1" value="25"></div>"' _n
    file write `fh' `"<div class="ctrl"><label title="Answers removed per 100 set">Churn %</label><input id="c_churn" type="number" min="1" max="100" step="1" value="20"></div>"' _n
    file write `fh' `"<div class="ctrl"><label title="Robust z-score on log active time">Outlier z</label><input id="c_z" type="number" min="2" max="6" step="0.5" value="3.5"></div>"' _n
    file write `fh' `"<div class="ctrl"><label title="Flag when the interview needed less than this share of the time colleagues typically take on the same questions">Peer speed &lt; %</label><input id="c_peer" type="number" min="5" max="90" step="5" value="35"></div>"' _n
    file write `fh' `"<div class="ctrl"><label title="Minutes in which the enumerator answered in two interviews at once">Overlap min &ge;</label><input id="c_ov" type="number" min="1" max="60" step="1" value="3"></div>"' _n
    file write `fh' `"<div class="ctrl"><label title="Rate-based flags need at least this many timed answers">Min answers</label><input id="c_nmin" type="number" min="3" max="100" step="1" value="10"></div>"' _n
    file write `fh' `"</div>"' _n
    file write `fh' `"</div>"' _n
    file write `fh' `"<div class="cards">"' _n
    file write `fh' `"<div class="card"><div class="v" id="k_started">-</div><div class="k">interviews in view</div></div>"' _n
    file write `fh' `"<div class="card bad"><div class="v" id="k_inv">-</div><div class="k">investigate</div></div>"' _n
    file write `fh' `"<div class="card warn"><div class="v" id="k_ver">-</div><div class="k">verify</div></div>"' _n
    file write `fh' `"<div class="card"><div class="v" id="k_medact">-</div><div class="k">median active min</div></div>"' _n
    file write `fh' `"<div class="card"><div class="v" id="k_medans">-</div><div class="k">median sec / answer</div></div>"' _n
    file write `fh' `"</div>"' _n
    file write `fh' `"<div id="verdict" class="verdict"></div>"' _n
    file write `fh' `"<h2>What needs attention</h2>"' _n
    file write `fh' `"<div class="note">Every interview here comes with the evidence in plain words. <b>Investigate</b> = hard evidence (two interviews at once, or a rejection bounced straight back) or three independent signals. <b>Verify</b> = an unresolved removal history, two signals, or one signal plus a resubmission concern. <b>Watch</b> = a single behaviour signal; look only if a pattern builds. Click a row for its detail; the key is what you paste into Headquarters. Signals are screening evidence for review, never proof of fabrication on their own. <span id="w_none"></span></div>"' _n
    file write `fh' `"<section><div style="margin:6px 0"><button id="c_csv" class="pbtn ghost">Download this list (CSV)</button></div><table id="t_worst"></table></section>"' _n
    file write `fh' `"<h2>Behaviour flags</h2>"' _n
    file write `fh' `"<div class="note">How often each signal fires at the current thresholds. Adjust sensitivity in the panel; everything recomputes instantly. Only interviews with actual fieldwork are analysed; API-preloaded records are set aside.</div>"' _n
    file write `fh' `"<section id="ch_flags"><div class="legend" id="flag_leg"></div></section>"' _n
    file write `fh' `"<h2>How long do interviews take?</h2>"' _n
    file write `fh' `"<div class="note">Active interviewer time per interview: gaps over `gapmins' min and pauses excluded. <span id="n_act"></span></div>"' _n
    file write `fh' `"<section id="ch_act"></section>"' _n
    file write `fh' `"<h2>How fast are answers?</h2>"' _n
    file write `fh' `"<div class="note">Each interview gets one number: the typical (median) time to answer a newly reached question. Repeat taps on the same question (multi-select choices, list items, immediate corrections) are kept out of this clock, so tapping through a checklist cannot look like speeding. A real interview needs time to ask, listen and type - a sustained 1-2 seconds per question was probably filled in without talking to anyone. <span id="n_med"></span></div>"' _n
    file write `fh' `"<section id="ch_med"></section>"' _n
    file write `fh' `"<h2>When is the work happening?</h2>"' _n
    file write `fh' `"<div class="note">Interviewer answers by hour of day (device-local time). Gold bars mark the night window - night answering on establishment surveys usually means desk work, not fieldwork. Interviews whose tablet clock disagrees with the team are marked in their detail row, because their hours cannot be trusted.</div>"' _n
    file write `fh' `"<section id="ch_hour"></section>"' _n
    file write `fh' `"<h2>Fieldwork over time</h2>"' _n
    file write `fh' `"<div class="note">Interviewer answers recorded per day (`dnote'). Responds to the enumerator filter.</div>"' _n
    file write `fh' `"<section id="ch_daily"></section>"' _n
    file write `fh' `"<h2>Enumerators</h2>"' _n
    file write `fh' `"<div class="note">Compare within the team: the person whose answer speed, night share or overlap stands apart from colleagues on the same instrument is the one to review first. <b>vs team</b> is the enumerator's typical answer speed relative to the team (0.5 = twice as fast as the team). Gold rows have at least one flagged interview; judge shares only where the interview count is reasonable. <span id="l_more"></span></div>"' _n
    file write `fh' `"<section><table id="t_league"></table></section>"' _n
    file write `fh' `"<h2>Question timing</h2>"' _n
    file write `fh' `"<div class="note">Median seconds to answer each question, across interviews with fieldwork. Type to filter; click a column header to sort. Slow questions are usually hard questions - candidates for rewording or interviewer training. <span id="q_more"></span></div>"' _n
    file write `fh' `"<section><div class="ctrl" style="max-width:280px;margin-bottom:8px"><label>Filter questions</label><input id="c_q" type="text" placeholder="variable name contains..."></div><table id="t_q"></table></section>"' _n
    * static removal-history summary (technical, collapsed by default)
    if `ncasc'>0 & `"`trignames'"'!="" {
        file write `fh' `"<details style="margin-top:22px"><summary style="cursor:pointer;color:#556575;font-size:13px;font-weight:600">Technical removal-pattern summary</summary>"' _n
        file write `fh' `"<div class="note">These counts describe historical AnswerRemoved runs. The displayed variable may be either questionnaire-linked or merely the nearest answer event; it is not automatically the cause.</div>"' _n
        file write `fh' `"<section><table><tr><th>nearby / linked variable</th><th class="r">histories</th><th class="r">interviews</th><th class="r">removal events</th></tr>"' _n
        local i = 0
        foreach t of local trignames {
            local ++i
            _suso_para_hesc `t'
            file write `fh' `"<tr><td class="mono">`r(out)'</td><td class="r">`=`RT'[`i',1]'</td><td class="r">`=`RT'[`i',2]'</td><td class="r">`=`RT'[`i',3]'</td></tr>"' _n
        }
        file write `fh' `"</table></section></details>"' _n
    }

    capture confirm file `"`RSD'"'
    if !_rc & `ncasc'>0 {
        preserve
        quietly use `"`RSD'"', clear
        capture confirm variable tier
        if _rc {
            quietly gen str1 tier = "V"
            quietly gen strL why = "Check final data"
        }
        quietly gen byte __sev = cond(tier=="A",2,cond(tier=="V",1,0))
        gsort -__sev -nopen -nunknown -nqrem interview__id sk_run
        local hasqxt 0
        capture confirm variable qx_text
        if !_rc local hasqxt 1

        quietly gen str120 e_ac = substr(cond(actor!="", actor, resp),1,120)
        quietly gen strL e_tg = trigger
        quietly gen strL e_qt = ""
        if `hasqxt' quietly replace e_qt = substr(qx_text,1,160)
        quietly gen strL e_wl = substr(wlc,1,300)
        quietly gen strL e_event = transition_text
        quietly gen strL e_final = trigger_final_text
        quietly gen strL e_check = wl_open
        quietly replace e_check = e_check + cond(e_check!="", " | ", "") + wl_unknown if wl_unknown!=""
        quietly gen strL e_rel = cond(reltype==1, ///
            cond(linkmode==2,"Indirect questionnaire relationship: ", ///
            cond(linkmode==3,"Direct and indirect questionnaire relationship: ", ///
            "Direct questionnaire relationship: ")) + ///
            cond(trigger!="",trigger,"(unknown)"), ///
            cond(reltype==3, "Questionnaire questions with no item-level condition shown", ///
            cond(reltype==4, "Fields outside questionnaire metadata", ///
            cond(reltype==5, "Mixed questionnaire/external fields", ///
            cond(reltype==6, "Questionnaire metadata not supplied", ///
            "Nearest AnswerSet only (not linked by questionnaire): " + cond(trigger!="",trigger,"(unknown)"))))))
        foreach v in e_ac e_tg e_qt e_wl e_event e_final e_check e_rel {
            quietly replace `v' = subinstr(subinstr(subinstr(`v',"&","&amp;",.),"<","&lt;",.),">","&gt;",.)
        }

        quietly gen strL e_eventline = "<b>Historical answer event:</b> " + e_event
        quietly gen strL e_finalline = ""
        quietly replace e_finalline = "<b>Current final export:</b> " + e_final if e_final!=""
        quietly gen strL e_hist = "<b>Removal history:</b> " + strofreal(nrem) + ///
            " AnswerRemoved event(s) affected " + strofreal(nqrem) + ///
            " distinct question/roster instance(s)."
        quietly gen strL e_state = "<b>Current paradata state:</b> " + ///
            strofreal(nreanswered) + " answered again; " + strofreal(nopen) + ///
            " still appear removed; " + strofreal(nunknown) + " unknown."
        quietly gen strL e_action = "<b>Check in final .dta:</b> <span class=" + char(34) + "mono" + char(34) + ">" + e_check + "</span>. Reject only if a listed value is actually blank and should have been asked."
        quietly replace e_action = "<b>Priority check:</b> review the final .dta and interview history because multiple unresolved sequences or sections are involved." if tier=="A"
        quietly gen str24 e_dt = string(ts0/86400000, "%tdDD_Mon_CCYY")

        file write `fh' `"<h2>Removal histories requiring a final-data check</h2>"' _n
        file write `fh' `"<div class="note">Only unresolved histories are shown here. Fully re-answered cases are omitted from this action list and remain available in the Skip removals tab.</div>"' _n
        file write `fh' `"<section>"' _n
        quietly count if tier!="C"
        local nshow = r(N)
        file write `fh' `"<div class="note"><b>"' (strofreal(`nshow')) `"</b> case(s) require a final-data check.</div>"' _n
        if `nshow'>0 {
            quietly keep if tier!="C"
            local kk = min(15, _N)
            forvalues i = 1/`kk' {
                file write `fh' `"<div style="border-bottom:1px solid #eef0f2;padding:10px 0">"' _n
                file write `fh' `"<div style="font-size:13px"><span class="mono"><b>"' (interview__id[`i']) `"</b></span> &nbsp; enumerator <b>"' (e_ac[`i']) `"</b> &nbsp; "' (e_dt[`i']) `"</div>"' _n
                file write `fh' `"<div style="font-size:12.5px;font-weight:700;color:"' (cond(tier[`i']=="A","#8a1f1f","#7a5b00")) `"">"' (why[`i']) `"</div>"' _n
                file write `fh' `"<div style="font-size:12.5px;margin-top:4px">"' (e_eventline[`i']) `"</div>"' _n
                if e_finalline[`i']!="" file write `fh' `"<div style="font-size:12.5px;margin-top:4px;color:#173b5e;background:#edf5fb;padding:5px 7px;border-radius:5px">"' (e_finalline[`i']) `"</div>"' _n
                file write `fh' `"<div style="font-size:12.5px;margin-top:4px">"' (e_hist[`i']) `"</div>"' _n
                file write `fh' `"<div class="note" style="margin:4px 0 0">"' (e_state[`i']) `"</div>"' _n
                file write `fh' `"<div class="note" style="margin:4px 0 0;color:#333">"' (e_action[`i']) `"</div>"' _n
                file write `fh' `"<details style="margin-top:5px"><summary style="cursor:pointer;color:#556575;font-size:11.5px">Technical details</summary>"' _n
                file write `fh' `"<div class="note">"' (e_rel[`i']) `" &nbsp; Removal events: "' (strofreal(nrem[`i'])) `"</div>"' _n
                if e_qt[`i']!="" file write `fh' `"<div class="note"><span class="mono">"' (e_tg[`i']) `"</span>: &quot;"' (e_qt[`i']) `"&quot;</div>"' _n
                if e_wl[`i']!="" file write `fh' `"<div class="note">Affected questions: <span class="mono">"' (e_wl[`i']) (cond(length(wlc[`i'])>300," ...","")) `"</span></div>"' _n
                file write `fh' `"</details></div>"' _n
            }
        }
        else file write `fh' `"<div class="note" style="color:#1e6b34"><b>No final-data checks are indicated.</b> Every affected question was answered again in the paradata.</div>"' _n
        file write `fh' `"</section>"' _n
        restore
    }
    _suso_para_hesc `"`rolenote'"'
    local rnesc `"`r(out)'"'
    local veline ""
    if `hasve' local veline " Open validation errors count the questions whose last validity event is a failure."
    file write `fh' `"<div class="foot"><b>Method.</b> Timing uses `rnesc'. Active time sums inter-event gaps within each interview, capping every gap at `gapmins' minutes and zeroing workflow/session breaks. Initial CAPI preload AnswerSet events and non-interviewer roles are excluded from behavioural metrics but retained in historical state. Answer speed preserves timestamp milliseconds and is the gap preceding each AnswerSet on a newly reached question within a session; repeat answers on the same question (multi-select taps, list items, immediate revisions) are excluded from the speed clock. Peer speed compares each interview's timed questions with the survey-median seconds for those same questions, so it is unaffected by which sections an interview reached. Overlap counts device-clock minutes in which the same enumerator recorded answers in two or more interviews. Night uses device-local time; the team's modal timezone offset is `tzmodeh' h and interviews on a different or changing offset are marked clock-suspect. CAWI (web) interviews keep only churn, duration-outlier and workflow signals, since respondent-driven timing says nothing about the enumerator. Interview status is the workflow state at the last status event in the paradata. Duration outliers use a robust (median/MAD) z on log active time.`veline' Records with no interviewer activity (`nuntouchedc' of `nintsc' here, typically API-preloaded grid points) are excluded from all figures. Flags are screening signals for review, not evidence of fabrication.<br><b>Produced by</b> suso paradata report (suso v1.7.12) on `now'. Thresholds shown in the control panel are live and local to this page.</div>"' _n
    file write `fh' `"</div>"' _n

    * ---- embedded data ------------------------------------------------------------
    file write `fh' `"<script>"' _n
    file write `fh' `"var D={"meta":{"fastsecs":`fastsecs',"gapmins":`gapmins',"tzmode":`tzmodeh',"lite":`lite',"hasve":`hasve',"hascawi":`hascawi',"haskey":`haskey',"fdims":[`jfdims']},"' _n
    file write `fh' `""rows":["' _n
    quietly use `"`MERGED'"', clear
    quietly keep if started
    forvalues i = 1/`=_N' {
        _suso_jsonesc `"`=responsible[`i']'"'
        local rj `"`r(js)'"'
        _suso_jsonesc `"`=ikey[`i']'"'
        local kj `"`r(js)'"'
        local med = cond(missing(ans_med_s[`i']), "null", string(ans_med_s[`i'],"%12.2f"))
        local fsh = cond(missing(fast_share[`i']), "null", string(fast_share[`i'],"%12.3f"))
        local nsh = cond(missing(night_share[`i']), "null", string(night_share[`i'],"%12.3f"))
        local rtj = cond(missing(rt[`i']), "null", string(rt[`i'],"%12.2f"))
        local rbj = cond(missing(rbm[`i']), "null", string(rbm[`i'],"%12.1f"))
        local rej = cond(missing(rbe[`i']), "null", string(rbe[`i'],"%12.0f"))
        local vej = cond(missing(verr[`i']), "null", string(verr[`i'],"%12.0f"))
        local nqj = cond(missing(nq[`i']), "null", string(nq[`i'],"%12.0f"))
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
        local fjm ""
        foreach fvv of local fdimvars {
            local fval = cond(missing(f__`fvv'[`i']), "", strofreal(f__`fvv'[`i']))
            local fjm `"`fjm'`=cond(`"`fjm'"'=="","",",")'"`fvv'":"`fval'""'
        }
        if `"`fjm'"'!="" local fjm `","f":{`fjm'}"'
        local sep = cond(`i'==1, "", ",")
        file write `fh' `"`sep'{"id":"`=interview__id[`i']'","k":"`kj'","r":"`rj'","ws":"`=ws[`i']'"`fjm',"d0":"`=__d0[`i']'","m":`=iscawi[`i']',"nt":`=n_timed[`i']',"nc":`=n_completed[`i']',"act":`=string(active_min[`i'],"%12.2f")',"med":`med',"fsh":`fsh',"nsh":`nsh',"ch":`=string(churn[`i'],"%12.3f")',"cas":`=n_cascades[`i']',"rem":`=casc_removed[`i']',"wip":`=casc_questions[`i']',"cop":`=casc_open[`i']',"cr":`=casc_reanswered[`i']',"cu":`=casc_unknown[`i']',"fda":`=casc_finalanswered[`i']',"fad":`=casc_answered_disabled[`i']',"feb":`=casc_expectedblank[`i']',"fbe":`=casc_blank_enabled[`i']',"flu":`=casc_logicunknown[`i']',"fnd":`=casc_notindata[`i']',"fck":`=casc_finalcheck[`i']',"fdc":`=casc_datachecked[`i']',"fr":`=fr[`i']'"'
        file write `fh' `","rt":`rtj',"ov":`=ovm[`i']',"rj":`=n_rejected[`i']',"rb":`rbj',"re":`rej',"pc":`=pce[`i']',"ve":`vej',"nq":`nqj',"ss":`=sessions[`i']',"rs":`=n_restarted[`i']',"tz":`=cond(missing(tzh[`i']),"null",string(tzh[`i'],"%12.1f"))',"to":`=tzodd[`i']'`vecs'}"' _n
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
    file write `fh' `"  letters: ['S','B','T','N','C','Z','P','O'],"' _n
    file write `fh' `"  names: ['Speeding','Fast streak','Too short','Night work','Churn','Duration outlier','Faster than peers','Two at once'],"' _n
    file write `fh' `"  presets: {"' _n
    file write `fh' `"    standard:{burst:8,minact:10,n1:22,n2:6,nshare:0.25,churn:0.20,z:3.5,peer:0.35,ov:3,nmin:10},"' _n
    file write `fh' `"    lenient:{fs:1.5,burst:12,minact:7,n1:22,n2:6,nshare:0.35,churn:0.30,z:4,peer:0.25,ov:5,nmin:15},"' _n
    file write `fh' `"    strict:{fs:3,burst:6,minact:15,n1:22,n2:6,nshare:0.15,churn:0.15,z:3,peer:0.45,ov:2,nmin:8}"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  sum: function(a){ var s=0,i; for(i=0;i<a.length;i++) s+=a[i]; return s; },"' _n
    file write `fh' `"  f1: function(x,d){ if(x===null||x===undefined||isNaN(x)) return '.'; return x.toFixed(d===undefined?1:d); },"' _n
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
    file write `fh' `"  team: function(rows){"' _n
    file write `fh' `"    var med=[],nq=[],act=[],i,r;"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++){"' _n
    file write `fh' `"      r=rows[i];"' _n
    file write `fh' `"      act.push(r.act);"' _n
    file write `fh' `"      if(r.med!==null) med.push(r.med);"' _n
    file write `fh' `"      if(r.nq!==null&&r.nq!==undefined) nq.push(r.nq);"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    return {med:P.median(med), nq:P.median(nq), act:P.median(act)};"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  isCapi: function(row){ return row.m!==1; },"' _n
    file write `fh' `"  flagsFor: function(row,S,ctx){"' _n
    file write `fh' `"    var capi=P.isCapi(row);"' _n
    file write `fh' `"    var nsh=P.nightShare(row,S.n1,S.n2), z=P.zval(row,ctx);"' _n
    file write `fh' `"    return ["' _n
    file write `fh' `"      capi && row.med!==null && row.med<S.fs && row.nt>=S.nmin,"' _n
    file write `fh' `"      capi && row.fr>=S.burst && row.nt>=S.nmin,"' _n
    file write `fh' `"      capi && row.nc>0 && row.act<S.minact,"' _n
    file write `fh' `"      capi && nsh!==null && nsh>S.nshare && row.nt>=S.nmin,"' _n
    file write `fh' `"      row.ch!==null && row.ch>S.churn && row.nt>=S.nmin,"' _n
    file write `fh' `"      z!==null && Math.abs(z)>S.z,"' _n
    file write `fh' `"      capi && row.rt!==null && row.rt<S.peer && row.nt>=S.nmin,"' _n
    file write `fh' `"      capi && row.ov>=S.ov"' _n
    file write `fh' `"    ];"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  resub: function(row){ return row.rj>0 && row.re===0; },"' _n
    file write `fh' `"  softResub: function(row){"' _n
    file write `fh' `"    return row.rj>0 && row.re!==null && row.re>0 && row.re<=2 && row.rb!==null && row.rb<10;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  unresolvedRemoval: function(row){ return row.fdc===1 ? (row.fck||0)>0 : ((row.cop||0)+(row.cu||0))>0; },"' _n
    file write `fh' `"  tierFor: function(row){"' _n
    file write `fh' `"    if(row._r || row._f[7]) return 'A';"' _n
    file write `fh' `"    if(row._n>=3) return 'A';"' _n
    file write `fh' `"    if(row._n===2) return 'V';"' _n
    file write `fh' `"    if(row._n===1 && (P.unresolvedRemoval(row) || P.softResub(row))) return 'V';"' _n
    file write `fh' `"    if(P.softResub(row)) return 'V';"' _n
    file write `fh' `"    if(row._n===1) return 'W';"' _n
    file write `fh' `"    if(P.unresolvedRemoval(row)) return 'V';"' _n
    file write `fh' `"    return '';"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  evidence: function(row,S,team){"' _n
    file write `fh' `"    var out=[], f=row._f;"' _n
    file write `fh' `"    if(f[7]) out.push({t:'hard', s:'Answered this and another interview during the same minute on '+row.ov+' occasion(s) - one person cannot conduct two interviews at once.'});"' _n
    file write `fh' `"    if(row._r){"' _n
    file write `fh' `"      var w='Rejected, then re-completed ';"' _n
    file write `fh' `"      if(row.rb!==null) w+=P.f1(row.rb,0)+' min later ';"' _n
    file write `fh' `"      out.push({t:'hard', s:w+'with no answers changed.'});"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    else if(P.softResub(row)) out.push({t:'flag', s:'Rejected, re-completed after '+P.f1(row.rb,0)+' min with only '+row.re+' answer(s) changed.'});"' _n
    file write `fh' `"    if(f[0]) out.push({t:'flag', s:'Typical answer took '+P.f1(row.med,1)+' s across '+row.nt+' timed answers'+(team.med!==null?' (team typical '+P.f1(team.med,1)+' s)':'')+'.'});"' _n
    file write `fh' `"    if(f[6]) out.push({t:'flag', s:'Finished its questions in '+P.f1(100*row.rt,0)+'% of the time colleagues typically need on those same questions.'});"' _n
    file write `fh' `"    if(f[1]){"' _n
    file write `fh' `"      var wfs=P.fastShare(row,S.fs);"' _n
    file write `fh' `"      out.push({t:'flag', s:'A streak of '+row.fr+' consecutive questions each answered in under '+D.meta.fastsecs+' s'+(wfs!==null?(' ('+P.f1(100*wfs,0)+'% of all answers were that fast)'):'')+'.'});"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    if(f[2]){"' _n
    file write `fh' `"      var w2='Marked completed after only '+P.f1(row.act,1)+' min of active work';"' _n
    file write `fh' `"      if(row.nq!==null&&row.nq!==undefined&&team.nq!==null) w2+=' - '+row.nq+' distinct questions answered (team median '+P.f1(team.nq,0)+')';"' _n
    file write `fh' `"      out.push({t:'flag', s:w2+'.'});"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    if(f[3]){"' _n
    file write `fh' `"      var w3=P.f1(100*P.nightShare(row,S.n1,S.n2),0)+'% of answering happened between '+S.n1+':00 and '+S.n2+':00 device time.';"' _n
    file write `fh' `"      if(row.to===1) w3+=' Caution: this tablet clock is unreliable (offset differs from the team or changed mid-fieldwork).';"' _n
    file write `fh' `"      out.push({t:'flag', s:w3, cav:(row.to===1)});"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    if(f[4]) out.push({t:'flag', s:P.f1(100*row.ch,0)+' answers removed per 100 set.'});"' _n
    file write `fh' `"    if(f[5]) out.push({t:'flag', s:'Active time '+P.f1(row.act,1)+' min is far outside the survey-wide pattern.'});"' _n
    file write `fh' `"    if(P.unresolvedRemoval(row)) out.push({t:'flag', s:'Final-data review after a historical removal run: '+row.fda+' answered; '+row.fad+' answered while disabled; '+row.feb+' blank as expected because disabled; '+row.fbe+' blank while enabled; '+row.flu+' logic unknown; '+row.fnd+' not in supplied data.'});"' _n
    file write `fh' `"    else if(row.cas>0) out.push({t:'info', s:'Historical removal run resolved: '+row.fda+' answered and '+row.feb+' correctly blank because disabled. No action from this history alone.'});"' _n
    file write `fh' `"    if(row.m===1) out.push({t:'info', s:'Web (CAWI) interview - timing signals not applied.'});"' _n
    file write `fh' `"    if(row.to===1 && !f[3]){"' _n
    file write `fh' `"      if(row.tz!==null && D.meta.tzmode!==undefined && Math.abs(row.tz-D.meta.tzmode)<0.05)"' _n
    file write `fh' `"        out.push({t:'info', s:'The tablet clock offset changed during fieldwork on this interview - its hours are unreliable.'});"' _n
    file write `fh' `"      else out.push({t:'info', s:'Tablet clock offset '+(row.tz===null?'?':P.f1(row.tz,1))+' h differs from the team ('+P.f1(D.meta.tzmode,1)+' h).'});"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    if(row.pc>0 && row.rj===0) out.push({t:'info', s:'Edited '+row.pc+' answer(s) after completion without any rejection.'});"' _n
    file write `fh' `"    if(row.ve!==null && row.ve>0) out.push({t:'info', s:row.ve+' validation error(s) still open.'});"' _n
    file write `fh' `"    return out;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  filterRows: function(rows,resp,ws,fd,fv){"' _n
    file write `fh' `"    var out=[],i,r;"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++){"' _n
    file write `fh' `"      r=rows[i];"' _n
    file write `fh' `"      if(resp && r.r!==resp) continue;"' _n
    file write `fh' `"      if(ws){"' _n
    file write `fh' `"        if(ws==='APP'){ if(r.ws!=='Approved by HQ' && r.ws!=='Approved by Sup') continue; }"' _n
    file write `fh' `"        else if(r.ws!==ws) continue;"' _n
    file write `fh' `"      }"' _n
    file write `fh' `"      if(fd && fv){ if(!r.f || r.f[fd]!==fv) continue; }"' _n
    file write `fh' `"      out.push(r);"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    return out;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  aggregate: function(rows,S){"' _n
    file write `fh' `"    var ctx=P.zctx(rows), tot=[0,0,0,0,0,0,0,0], flagged=[], tiers={A:0,V:0,W:0}, i,j;"' _n
    file write `fh' `"    for(i=0;i<rows.length;i++){"' _n
    file write `fh' `"      var f=P.flagsFor(rows[i],S,ctx), n=0;"' _n
    file write `fh' `"      for(j=0;j<8;j++){ if(f[j]){tot[j]++;n++;} }"' _n
    file write `fh' `"      rows[i]._f=f; rows[i]._n=n;"' _n
    file write `fh' `"      rows[i]._r=P.resub(rows[i]);"' _n
    file write `fh' `"      rows[i]._t=P.tierFor(rows[i]);"' _n
    file write `fh' `"      if(rows[i]._t!==''){ flagged.push(rows[i]); tiers[rows[i]._t]++; }"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    var rank={A:0,V:1,W:2};"' _n
    file write `fh' `"    flagged.sort(function(a,b){"' _n
    file write `fh' `"      if(rank[a._t]!==rank[b._t]) return rank[a._t]-rank[b._t];"' _n
    file write `fh' `"      if(b._n!==a._n) return b._n-a._n;"' _n
    file write `fh' `"      if(b.wip!==a.wip) return b.wip-a.wip;"' _n
    file write `fh' `"      var am=a.med===null?1e9:a.med, bm=b.med===null?1e9:b.med;"' _n
    file write `fh' `"      return am-bm;"' _n
    file write `fh' `"    });"' _n
    file write `fh' `"    return {tot:tot, flagged:flagged, tiers:tiers, n:rows.length, ctx:ctx};"' _n
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
    file write `fh' `"      if(!m[r.r]) m[r.r]={r:r.r,n:0,fl:0,ov:0,act:[],med:[],fsh:[],nsh:[]};"' _n
    file write `fh' `"      var g=m[r.r], f=P.flagsFor(r,S,ctx), any=false, j;"' _n
    file write `fh' `"      for(j=0;j<8;j++) if(f[j]) any=true;"' _n
    file write `fh' `"      if(P.resub(r)) any=true;"' _n
    file write `fh' `"      g.n++; if(any||P.unresolvedRemoval(r)) g.fl++;"' _n
    file write `fh' `"      g.ov+=r.ov;"' _n
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
    file write `fh' `"    out.sort(function(a,b){ if(b.share!==a.share) return b.share-a.share; return b.n-a.n; });"' _n
    file write `fh' `"    return out;"' _n
    file write `fh' `"  },"' _n
    file write `fh' `"  csv: function(flagged,S){"' _n
    file write `fh' `"    var Q=String.fromCharCode(34);"' _n
    file write `fh' `"    function cell(x){"' _n
    file write `fh' `"      if(x===null||x===undefined) return '';"' _n
    file write `fh' `"      var s=String(x);"' _n
    file write `fh' `"      if(s.indexOf(',')>=0||s.indexOf(Q)>=0||s.indexOf('\n')>=0) return Q+s.split(Q).join(Q+Q)+Q;"' _n
    file write `fh' `"      return s;"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    var head=['tier','interview_key','interview_id','enumerator','status','first_day','flags','active_min','sec_per_answer','fast_share','fast_run','night_share','churn','peer_ratio','overlap_min','rejections','resubmit_min','resubmit_edits','cascades','questions_affected','post_completion_edits','open_errors','questions_answered'];"' _n
    file write `fh' `"    var lines=[head.join(',')], i, r, j, pat;"' _n
    file write `fh' `"    var tname={A:'INVESTIGATE',V:'VERIFY',W:'WATCH'};"' _n
    file write `fh' `"    for(i=0;i<flagged.length;i++){"' _n
    file write `fh' `"      r=flagged[i]; pat='';"' _n
    file write `fh' `"      for(j=0;j<8;j++) if(r._f[j]) pat+=P.letters[j];"' _n
    file write `fh' `"      if(r._r) pat+='R';"' _n
    file write `fh' `"      lines.push([tname[r._t],cell(r.k),cell(r.id),cell(r.r),cell(r.ws),cell(r.d0),pat,"' _n
    file write `fh' `"        P.f1(r.act,1),P.f1(r.med,1),P.f1(P.fastShare(r,S.fs),2),r.fr,P.f1(P.nightShare(r,S.n1,S.n2),2),"' _n
    file write `fh' `"        P.f1(r.ch,2),P.f1(r.rt,2),r.ov,r.rj,P.f1(r.rb,0),(r.re===null?'':r.re),r.cas,r.wip,r.pc,"' _n
    file write `fh' `"        (r.ve===null?'':r.ve),(r.nq===null||r.nq===undefined?'':r.nq)].join(','));"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    return lines.join('\n');"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"};"' _n
    file write `fh' `"if (typeof module!=='undefined' && module.exports) module.exports=P;"' _n
    file write `fh' _n
    file write `fh' `"/* ---------------- DOM layer (browser only) ---------------- */"' _n
    file write `fh' `"if (typeof document!=='undefined') {"' _n
    file write `fh' _n
    file write `fh' `"var Q=String.fromCharCode(34);"' _n
    file write `fh' `"var expOpen={};"' _n
    file write `fh' `"var lastA=null, lastS=null, lastTeam=null;"' _n
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
    file write `fh' `"function copyText(t){"' _n
    file write `fh' `"  var ta=document.createElement('textarea');"' _n
    file write `fh' `"  ta.value=t; ta.style.position='fixed'; ta.style.left='-999px';"' _n
    file write `fh' `"  document.body.appendChild(ta); ta.select();"' _n
    file write `fh' `"  try{ document.execCommand('copy'); }catch(e){}"' _n
    file write `fh' `"  document.body.removeChild(ta);"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"function svgBars(counts,labels,hi,opts){"' _n
    file write `fh' `"  opts=opts||{};"' _n
    file write `fh' `"  function at(n,v){ return ' '+n+'='+Q+v+Q; }"' _n
    file write `fh' `"  var w=opts.w||940, hgt=opts.hgt||170, lstep=opts.lstep||1, showv=opts.vals||false;"' _n
    file write `fh' `"  var k=counts.length, maxc=0, i;"' _n
    file write `fh' `"  for(i=0;i<k;i++) if(counts[i]>maxc) maxc=counts[i];"' _n
    file write `fh' `"  if(maxc<=0||k===0) return '<p class=\"nodata\">Nothing to plot for this selection.</p>';"' _n
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
    file write `fh' `"    ws:   el('c_ws').value,"' _n
    file write `fh' `"    fd:   el('c_fd').value,"' _n
    file write `fh' `"    fv:   el('c_fv').value,"' _n
    file write `fh' `"    fs:   Math.max(0.5,parseFloat(el('c_fs').value)||2),"' _n
    file write `fh' `"    burst:Math.max(3,parseInt(el('c_burst').value,10)||8),"' _n
    file write `fh' `"    minact:parseFloat(el('c_minact').value)||10,"' _n
    file write `fh' `"    n1:   parseInt(el('c_n1').value,10),"' _n
    file write `fh' `"    n2:   parseInt(el('c_n2').value,10),"' _n
    file write `fh' `"    nshare:(parseFloat(el('c_nshare').value)||25)/100,"' _n
    file write `fh' `"    churn:(parseFloat(el('c_churn').value)||20)/100,"' _n
    file write `fh' `"    z:    parseFloat(el('c_z').value)||3.5,"' _n
    file write `fh' `"    peer:(parseFloat(el('c_peer').value)||35)/100,"' _n
    file write `fh' `"    ov:   Math.max(1,parseInt(el('c_ov').value,10)||3),"' _n
    file write `fh' `"    nmin: Math.max(3,parseInt(el('c_nmin').value,10)||10),"' _n
    file write `fh' `"    top:  Math.max(1,parseInt(el('c_top').value,10)||25)"' _n
    file write `fh' `"  };"' _n
    file write `fh' `"}"' _n
    file write `fh' `"function applyPreset(p){"' _n
    file write `fh' `"  if(p==='custom'||!P.presets[p]) return;"' _n
    file write `fh' `"  var t=P.presets[p];"' _n
    file write `fh' `"  el('c_fs').value=(t.fs!==undefined)?t.fs:D.meta.fastsecs;"' _n
    file write `fh' `"  el('c_burst').value=t.burst;"' _n
    file write `fh' `"  el('c_minact').value=t.minact;"' _n
    file write `fh' `"  el('c_n1').value=t.n1; el('c_n2').value=t.n2;"' _n
    file write `fh' `"  el('c_nshare').value=Math.round(t.nshare*100);"' _n
    file write `fh' `"  el('c_churn').value=Math.round(t.churn*100);"' _n
    file write `fh' `"  el('c_z').value=t.z;"' _n
    file write `fh' `"  el('c_peer').value=Math.round(t.peer*100);"' _n
    file write `fh' `"  el('c_ov').value=t.ov;"' _n
    file write `fh' `"  el('c_nmin').value=t.nmin;"' _n
    file write `fh' `"}"' _n
    file write `fh' `"function resetSettings(){"' _n
    file write `fh' `"  el('c_resp').value='';"' _n
    file write `fh' `"  el('c_ws').value='';"' _n
    file write `fh' `"  el('c_fd').value='';"' _n
    file write `fh' `"  fvOptions();"' _n
    file write `fh' `"  el('c_preset').value='standard';"' _n
    file write `fh' `"  applyPreset('standard');"' _n
    file write `fh' `"  el('c_top').value=25;"' _n
    file write `fh' `"  expOpen={};"' _n
    file write `fh' `"  renderAll();"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"function fvOptions(){"' _n
    file write `fh' `"  var dim=el('c_fd').value, s='<option value='+Q+Q+'>-</option>', i, j, cnt={};"' _n
    file write `fh' `"  if(dim && D.meta && D.meta.fdims){"' _n
    file write `fh' `"    for(i=0;i<D.rows.length;i++){"' _n
    file write `fh' `"      var rv=(D.rows[i].f&&D.rows[i].f[dim])?D.rows[i].f[dim]:'';"' _n
    file write `fh' `"      if(rv) cnt[rv]=(cnt[rv]||0)+1;"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    for(i=0;i<D.meta.fdims.length;i++){"' _n
    file write `fh' `"      if(D.meta.fdims[i].v!==dim) continue;"' _n
    file write `fh' `"      var vv=D.meta.fdims[i].vals;"' _n
    file write `fh' `"      for(j=0;j<vv.length;j++){"' _n
    file write `fh' `"        var lab=(vv[j].l&&vv[j].l!==vv[j].c)?(vv[j].c+' '+vv[j].l):vv[j].c;"' _n
    file write `fh' `"        s+='<option value='+Q+esc(vv[j].c)+Q+'>'+esc(lab)+' ('+(cnt[vv[j].c]||0)+')</option>';"' _n
    file write `fh' `"      }"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  el('c_fv').innerHTML=s;"' _n
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
    file write `fh' `"  var s='<tr><th class=\"srt\" onclick=\"qSort(String.fromCharCode(118))\">question</th>'+"' _n
    file write `fh' `"        '<th class=\"r srt\" onclick=\"qSort(String.fromCharCode(110))\">answers</th>'+"' _n
    file write `fh' `"        '<th class=\"r srt\" onclick=\"qSort(String.fromCharCode(110,105))\">interviews</th>'+"' _n
    file write `fh' `"        '<th class=\"r srt\" onclick=\"qSort(String.fromCharCode(109,101,100))\">median s</th>'+"' _n
    file write `fh' `"        '<th class=\"r srt\" onclick=\"qSort(String.fromCharCode(112,57,48))\">p90 s</th>'+"' _n
    file write `fh' `"        '<th class=\"r srt\" onclick=\"qSort(String.fromCharCode(102,115,104))\">fast share</th></tr>';"' _n
    file write `fh' `"  var k=Math.min(rows.length,40);"' _n
    file write `fh' `"  for(i=0;i<k;i++){"' _n
    file write `fh' `"    var q=rows[i];"' _n
    file write `fh' `"    s+='<tr><td class=\"mono\">'+esc(q.v)+'</td><td class=\"r\">'+fmtc(q.n)+'</td><td class=\"r\">'+fmtc(q.ni)+"' _n
    file write `fh' `"       '</td><td class=\"r\">'+fmt(q.med)+'</td><td class=\"r\">'+fmt(q.p90)+'</td><td class=\"r\">'+fmt(q.fsh,2)+'</td></tr>';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  el('t_q').innerHTML=s;"' _n
    file write `fh' `"  el('q_more').textContent = rows.length>k ? ('Showing '+k+' of '+rows.length+' questions - refine the search to see others.') : '';"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"function chipsFor(r){"' _n
    file write `fh' `"  var s='',j;"' _n
    file write `fh' `"  if(r._r) s+='<span class='+Q+'chip hard'+Q+' title='+Q+'Rejected and re-completed with no answers changed'+Q+'>Resubmitted unchanged</span>';"' _n
    file write `fh' `"  for(j=0;j<8;j++){"' _n
    file write `fh' `"    if(!r._f[j]) continue;"' _n
    file write `fh' `"    var cls=(j===7)?'chip hard':'chip';"' _n
    file write `fh' `"    s+='<span class='+Q+cls+Q+'>'+P.names[j]+'</span>';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  if(P.unresolvedRemoval(r)) s+='<span class='+Q+'chip'+Q+' title='+Q+'Historical removal run with unresolved final-data assessment'+Q+'>Final-data check</span>';"' _n
    file write `fh' `"  else if(r.cas>0) s+='<span class='+Q+'chip info'+Q+' title='+Q+'Historical removal run resolved by final data and logic; no action'+Q+'>Removal history resolved</span>';"' _n
    file write `fh' `"  if(r.m===1) s+='<span class='+Q+'chip info'+Q+'>CAWI</span>';"' _n
    file write `fh' `"  if(r.to===1) s+='<span class='+Q+'chip info'+Q+' title='+Q+'Tablet timezone differs from the team or changed - hours unreliable'+Q+'>Clock suspect</span>';"' _n
    file write `fh' `"  return s;"' _n
    file write `fh' `"}"' _n
    file write `fh' `"function detailHtml(r,S,team){"' _n
    file write `fh' `"  var ev=P.evidence(r,S,team), s='', i;"' _n
    file write `fh' `"  s+='<div class='+Q+'facts'+Q+'><b>Interview:</b> <span class='+Q+'mono'+Q+'>'+esc(r.id)+'</span>'+"' _n
    file write `fh' `"     '<span class='+Q+'cpy'+Q+' data-t='+Q+esc(r.id)+Q+'>copy id</span>';"' _n
    file write `fh' `"  if(r.k) s+=' &nbsp; <b>Key:</b> <span class='+Q+'mono'+Q+'>'+esc(r.k)+'</span><span class='+Q+'cpy'+Q+' data-t='+Q+esc(r.k)+Q+'>copy key</span>';"' _n
    file write `fh' `"  s+=' &nbsp; <b>Status:</b> '+esc(r.ws||'-')+' &nbsp; <b>First day:</b> '+esc(r.d0||'-')+"' _n
    file write `fh' `"     ' &nbsp; <b>Sessions:</b> '+r.ss+' &nbsp; <b>Restarts:</b> '+r.rs+' &nbsp; <b>Rejections:</b> '+r.rj+"' _n
    file write `fh' `"     ' &nbsp; <b>Answers:</b> '+fmtc(r.nt)+' timed'+((r.nq!==null&&r.nq!==undefined)?(' / '+fmtc(r.nq)+' questions'):'')+"' _n
    file write `fh' `"     ((r.tz!==null)?(' &nbsp; <b>Device offset:</b> '+fmt(r.tz,1)+' h'):'')+'</div>';"' _n
    file write `fh' `"  for(i=0;i<ev.length;i++){"' _n
    file write `fh' `"    var cls=(ev[i].t==='hard')?'ev hard':'ev';"' _n
    file write `fh' `"    var pre=(ev[i].t==='hard')?'<b style='+Q+'color:#8a1f1f'+Q+'>! </b>':((ev[i].t==='info')?'<span style='+Q+'color:#888'+Q+'>i </span>':'<span style='+Q+'color:#C9A227'+Q+'>&#9679; </span>');"' _n
    file write `fh' `"    s+='<div class='+Q+cls+Q+'>'+pre+esc(ev[i].s)+'</div>';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  if(!D.meta.lite && (r.h||r.g)){"' _n
    file write `fh' `"    s+='<div style='+Q+'display:flex;flex-wrap:wrap;gap:18px;margin-top:8px'+Q+'>';"' _n
    file write `fh' `"    if(r.h){"' _n
    file write `fh' `"      var labH=[],hiH=[],x;"' _n
    file write `fh' `"      for(x=0;x<24;x++){ labH.push(String(x)); if(P.inWindow(x,S.n1,S.n2)) hiH.push(x); }"' _n
    file write `fh' `"      s+='<div style='+Q+'flex:1 1 320px'+Q+'><div class='+Q+'legend'+Q+'>Answers by hour (device time)</div>'+svgBars(r.h,labH,hiH,{w:460,hgt:100,lstep:3})+'</div>';"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    if(r.g){"' _n
    file write `fh' `"      var labG=[],hiG=[],y;"' _n
    file write `fh' `"      for(y=0;y<21;y++){ labG.push(y<20?String(y):'20+'); if(y<S.fs) hiG.push(y); }"' _n
    file write `fh' `"      s+='<div style='+Q+'flex:1 1 320px'+Q+'><div class='+Q+'legend'+Q+'>Seconds per answer</div>'+svgBars(r.g,labG,hiG,{w:460,hgt:100,lstep:4})+'</div>';"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    s+='</div>';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  return s;"' _n
    file write `fh' `"}"' _n
    file write `fh' `"function renderWorst(){"' _n
    file write `fh' `"  var A=lastA, S=lastS, team=lastTeam;"' _n
    file write `fh' `"  if(!A) return;"' _n
    file write `fh' `"  var s='<tr><th></th><th>interview</th><th>enumerator</th><th>day</th><th>signals</th><th class=\"r\">act min</th><th class=\"r\">sec/ans</th></tr>';"' _n
    file write `fh' `"  var F=A.flagged, kk=Math.min(F.length,S.top), i;"' _n
    file write `fh' `"  var tlab={A:'Investigate',V:'Verify',W:'Watch'};"' _n
    file write `fh' `"  for(i=0;i<kk;i++){"' _n
    file write `fh' `"    var r=F[i];"' _n
    file write `fh' `"    var keyc=r.k?('<span class='+Q+'mono'+Q+'><b>'+esc(r.k)+'</b></span>'):('<span class='+Q+'mono'+Q+'>'+esc(r.id.substring(0,8))+'</span>');"' _n
    file write `fh' `"    s+='<tr class='+Q+'wrow'+Q+' data-i='+Q+i+Q+'>'+"' _n
    file write `fh' `"       '<td><span class='+Q+'tier '+r._t+Q+'>'+tlab[r._t]+'</span></td>'+"' _n
    file write `fh' `"       '<td>'+keyc+'</td>'+"' _n
    file write `fh' `"       '<td>'+esc(r.r)+'</td>'+"' _n
    file write `fh' `"       '<td>'+esc(r.d0||'-')+'</td>'+"' _n
    file write `fh' `"       '<td>'+chipsFor(r)+'</td>'+"' _n
    file write `fh' `"       '<td class=\"r\">'+fmt(r.act)+'</td>'+"' _n
    file write `fh' `"       '<td class=\"r\">'+fmt(r.med)+'</td></tr>';"' _n
    file write `fh' `"    if(expOpen[r.id]) s+='<tr class='+Q+'wdet'+Q+'><td colspan='+Q+'7'+Q+'>'+detailHtml(r,S,team)+'</td></tr>';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  el('t_worst').innerHTML=s;"' _n
    file write `fh' `"  el('w_none').textContent = F.length===0 ? 'Nothing to review for this selection - no signals and no cascades.' : (F.length>kk?('Showing '+kk+' of '+F.length+' - raise Show top to see more.'):'');"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"function renderAll(){"' _n
    file write `fh' `"  var S=settings();"' _n
    file write `fh' `"  var rows=P.filterRows(D.rows,S.resp,S.ws,S.fd,S.fv);"' _n
    file write `fh' `"  var A=P.aggregate(rows,S);"' _n
    file write `fh' `"  var team=P.team(rows);"' _n
    file write `fh' `"  lastA=A; lastS=S; lastTeam=team;"' _n
    file write `fh' `"  var scope=S.resp?('enumerator '+S.resp):'all enumerators';"' _n
    file write `fh' `"  if(S.ws) scope+=(S.ws==='APP')?', approved interviews':(', status '+S.ws);"' _n
    file write `fh' `"  if(S.fd && S.fv) scope+=', '+S.fd+' = '+S.fv;"' _n
    file write `fh' _n
    file write `fh' `"  el('k_started').textContent=fmtc(A.n);"' _n
    file write `fh' `"  el('k_inv').textContent=fmtc(A.tiers.A);"' _n
    file write `fh' `"  el('k_ver').textContent=fmtc(A.tiers.V);"' _n
    file write `fh' `"  var acts=[],i;"' _n
    file write `fh' `"  for(i=0;i<rows.length;i++) acts.push(rows[i].act);"' _n
    file write `fh' `"  el('k_medact').textContent=fmt(P.median(acts));"' _n
    file write `fh' `"  el('k_medans').textContent=fmt(team.med);"' _n
    file write `fh' _n
    file write `fh' `"  var verdict, vc, tA=A.tiers.A, tV=A.tiers.V, tW=A.tiers.W;"' _n
    file write `fh' `"  if(tA>0){ verdict=fmtc(tA)+' interview(s) need investigation, '+fmtc(tV)+' to verify and '+fmtc(tW)+' to watch, out of '+fmtc(A.n)+' for '+scope+'.'; vc='bad'; }"' _n
    file write `fh' `"  else if(tV>0){ verdict=fmtc(tV)+' interview(s) to verify and '+fmtc(tW)+' to watch, out of '+fmtc(A.n)+' for '+scope+' - no hard evidence at these thresholds.'; vc='warn'; }"' _n
    file write `fh' `"  else if(tW>0){ verdict='Only single, isolated signals ('+fmtc(tW)+' interview(s) to watch) for '+scope+'.'; vc='warn'; }"' _n
    file write `fh' `"  else { verdict='No behaviour signals raised for '+scope+' at the current sensitivity.'; vc='ok'; }"' _n
    file write `fh' `"  el('verdict').textContent=verdict;"' _n
    file write `fh' `"  el('verdict').className='verdict '+vc;"' _n
    file write `fh' _n
    file write `fh' `"  el('ch_flags').innerHTML=svgBars(A.tot,"' _n
    file write `fh' `"    ['S speed','B streak','T short','N night','C churn','Z outlier','P peers','O overlap'],[7],"' _n
    file write `fh' `"    {hgt:150,vals:true})+'<div class='+Q+'legend'+Q+'>S sustained speeding &nbsp; B a run of consecutive fast answers &nbsp; T completed too quickly &nbsp; N night work &nbsp; C answer churn &nbsp; Z duration outlier &nbsp; P far faster than peers on the same questions &nbsp; O two interviews in the same minute</div>';"' _n
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
    file write `fh' `"  else el('ch_hour').innerHTML='<p class=\"nodata\">Hour detail not embedded for this survey size.</p>';"' _n
    file write `fh' _n
    file write `fh' `"  var DT=P.dailyTotals(D.daily,S.resp), dc=[], dl=[], dstep=Math.max(1,Math.floor(DT.length/8));"' _n
    file write `fh' `"  for(i=0;i<DT.length;i++){ dc.push(DT[i].c); dl.push(i%dstep===0?DT[i].d.substring(5):''); }"' _n
    file write `fh' `"  el('ch_daily').innerHTML=svgBars(dc,dl,[],{lstep:1});"' _n
    file write `fh' _n
    file write `fh' `"  var L=P.league(rows,S), s='<tr><th>enumerator</th><th class=\"r\">interviews</th><th class=\"r\">med active min</th><th class=\"r\">med sec/ans</th><th class=\"r\" title=\"enumerator median sec per answer over team median: 0.5 means twice as fast as the team\">vs team</th><th class=\"r\">fast share</th><th class=\"r\">night share</th><th class=\"r\" title=\"minutes answering two interviews at once, summed\">overlap</th><th class=\"r\">flagged</th><th style=\"width:110px\">flag share</th></tr>';"' _n
    file write `fh' `"  var k=Math.min(L.length,30);"' _n
    file write `fh' `"  for(i=0;i<k;i++){"' _n
    file write `fh' `"    var g=L[i];"' _n
    file write `fh' `"    var vst=(g.medmed!==null&&team.med!==null&&team.med>0)?(g.medmed/team.med):null;"' _n
    file write `fh' `"    s+=(g.fl>0?'<tr class=\"hot\">':'<tr>')+'<td>'+esc(g.r)+'</td><td class=\"r\">'+fmtc(g.n)+'</td><td class=\"r\">'+fmt(g.medact)+"' _n
    file write `fh' `"       '</td><td class=\"r\">'+fmt(g.medmed)+'</td><td class=\"r\">'+fmt(vst,2)+'</td><td class=\"r\">'+fmt(g.mfsh,2)+'</td><td class=\"r\">'+fmt(g.mnsh,2)+"' _n
    file write `fh' `"       '</td><td class=\"r\">'+fmtc(g.ov)+'</td><td class=\"r\">'+fmtc(g.fl)+'</td><td><span class=\"bar\" style=\"width:'+Math.round(100*g.share)+'px\"></span> '+fmt(100*g.share)+'%</td></tr>';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  el('t_league').innerHTML=s;"' _n
    file write `fh' `"  el('l_more').textContent = L.length>k ? ('Top '+k+' of '+L.length+' enumerators by flag share.') : '';"' _n
    file write `fh' _n
    file write `fh' `"  renderWorst();"' _n
    file write `fh' `"  renderQuestions();"' _n
    file write `fh' `"}"' _n
    file write `fh' _n
    file write `fh' `"function initControls(){"' _n
    file write `fh' `"  var rs={}, i, names=[];"' _n
    file write `fh' `"  for(i=0;i<D.rows.length;i++) rs[D.rows[i].r]=1;"' _n
    file write `fh' `"  for(var k in rs){ if(rs.hasOwnProperty(k)&&k!=='') names.push(k); }"' _n
    file write `fh' `"  names.sort();"' _n
    file write `fh' `"  var s='<option value=\"\">All enumerators ('+names.length+')</option>';"' _n
    file write `fh' `"  for(i=0;i<names.length;i++) s+='<option>'+esc(names[i])+'</option>';"' _n
    file write `fh' `"  el('c_resp').innerHTML=s;"' _n
    file write `fh' `"  var wsm={}, wnames=[];"' _n
    file write `fh' `"  for(i=0;i<D.rows.length;i++){ var w=D.rows[i].ws||''; if(w) wsm[w]=(wsm[w]||0)+1; }"' _n
    file write `fh' `"  for(var k2 in wsm){ if(wsm.hasOwnProperty(k2)) wnames.push(k2); }"' _n
    file write `fh' `"  wnames.sort();"' _n
    file write `fh' `"  var so='<option value='+Q+Q+'>All statuses</option>';"' _n
    file write `fh' `"  if(wsm['Approved by HQ']||wsm['Approved by Sup']) so+='<option value='+Q+'APP'+Q+'>Approved only (Sup + HQ)</option>';"' _n
    file write `fh' `"  for(i=0;i<wnames.length;i++) so+='<option value='+Q+esc(wnames[i])+Q+'>'+esc(wnames[i])+' ('+wsm[wnames[i]]+')</option>';"' _n
    file write `fh' `"  el('c_ws').innerHTML=so;"' _n
    file write `fh' `"  var fds=(D.meta&&D.meta.fdims)?D.meta.fdims:[];"' _n
    file write `fh' `"  if(fds.length){"' _n
    file write `fh' `"    var fo='<option value='+Q+Q+'>None</option>';"' _n
    file write `fh' `"    for(i=0;i<fds.length;i++) fo+='<option>'+esc(fds[i].v)+'</option>';"' _n
    file write `fh' `"    el('c_fd').innerHTML=fo;"' _n
    file write `fh' `"    fvOptions();"' _n
    file write `fh' `"    el('c_fd').addEventListener('change',function(){ fvOptions(); renderAll(); });"' _n
    file write `fh' `"  } else {"' _n
    file write `fh' `"    el('ctl_fd').style.display='none';"' _n
    file write `fh' `"    el('ctl_fv').style.display='none';"' _n
    file write `fh' `"  }"' _n
    file write `fh' `"  var hsel='';"' _n
    file write `fh' `"  for(i=0;i<24;i++) hsel+='<option>'+i+'</option>';"' _n
    file write `fh' `"  el('c_n1').innerHTML=hsel; el('c_n2').innerHTML=hsel;"' _n
    file write `fh' `"  el('c_n1').value=22; el('c_n2').value=6;"' _n
    file write `fh' `"  el('c_fs').value=D.meta.fastsecs;"' _n
    file write `fh' `"  el('c_preset').value='standard';"' _n
    file write `fh' `"  el('c_adv').addEventListener('click',function(){"' _n
    file write `fh' `"    var a=el('advrow');"' _n
    file write `fh' `"    a.style.display=(a.style.display==='none')?'flex':'none';"' _n
    file write `fh' `"  });"' _n
    file write `fh' `"  el('c_preset').addEventListener('change',function(){ applyPreset(el('c_preset').value); renderAll(); });"' _n
    file write `fh' `"  var simp=['c_resp','c_ws','c_fv','c_top'];"' _n
    file write `fh' `"  for(i=0;i<simp.length;i++) el(simp[i]).addEventListener('change',renderAll);"' _n
    file write `fh' `"  var adv=['c_fs','c_burst','c_minact','c_n1','c_n2','c_nshare','c_churn','c_z','c_peer','c_ov','c_nmin'];"' _n
    file write `fh' `"  for(i=0;i<adv.length;i++) el(adv[i]).addEventListener('change',function(){ el('c_preset').value='custom'; renderAll(); });"' _n
    file write `fh' `"  el('c_q').addEventListener('input',renderQuestions);"' _n
    file write `fh' `"  el('c_reset').addEventListener('click',resetSettings);"' _n
    file write `fh' `"  el('c_csv').addEventListener('click',function(){"' _n
    file write `fh' `"    if(!lastA) return;"' _n
    file write `fh' `"    var body=P.csv(lastA.flagged,lastS);"' _n
    file write `fh' `"    var a=document.createElement('a');"' _n
    file write `fh' `"    a.href='data:text/csv;charset=utf-8,'+encodeURIComponent(body);"' _n
    file write `fh' `"    a.download='suso_review_list.csv';"' _n
    file write `fh' `"    document.body.appendChild(a); a.click(); document.body.removeChild(a);"' _n
    file write `fh' `"  });"' _n
    file write `fh' `"  el('t_worst').addEventListener('click',function(ev){"' _n
    file write `fh' `"    var t=ev.target||ev.srcElement;"' _n
    file write `fh' `"    if(t && t.className && String(t.className).indexOf('cpy')>=0){"' _n
    file write `fh' `"      copyText(t.getAttribute('data-t')||'');"' _n
    file write `fh' `"      t.textContent='copied';"' _n
    file write `fh' `"      return;"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"    while(t && t!==this && (!t.getAttribute || t.getAttribute('data-i')===null)) t=t.parentNode;"' _n
    file write `fh' `"    if(t && t.getAttribute && t.getAttribute('data-i')!==null){"' _n
    file write `fh' `"      var r=lastA.flagged[parseInt(t.getAttribute('data-i'),10)];"' _n
    file write `fh' `"      if(r){ expOpen[r.id]=!expOpen[r.id]; renderWorst(); }"' _n
    file write `fh' `"    }"' _n
    file write `fh' `"  });"' _n
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
    if `ncawi'>0 di as txt "  `ncawi' CAWI (web) interview(s) detected - timing flags are suppressed for them."
    di as txt "  timing basis: `rolenote'."
    di as txt "  in memory: one row per record (timing + flags at defaults + cascades + new signals + started marker)."
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

    * javacall runs inside Stata's JVM, whose process working directory is not
    * guaranteed to equal Stata's current working directory. Resolve a relative
    * questionnaire path here, before it crosses the Java boundary. This keeps
    * Windows paths with spaces and either slash style safe and deterministic.
    local file = subinstr(`"`file'"', "\", "/", .)
    local qxpwd = subinstr(`"`c(pwd)'"', "\", "/", .)
    local qxabs 0
    * Absolute after slash normalization: /root, //server/share or C:/path.
    if substr(`"`file'"',1,1)=="/"  local qxabs 1
    if substr(`"`file'"',2,2)==":/" local qxabs 1
    if !`qxabs' {
        if substr(`"`qxpwd'"',length(`"`qxpwd'"'),1)=="/" ///
            local file `"`qxpwd'`file'"'
        else local file `"`qxpwd'/`file'"'
    }
    confirm file `"`file'"'
    di as txt "suso paradata: parsing questionnaire HTML ..."

    * The hierarchy-aware parser is implemented in the packaged Java bridge.
    * Keeping it out of the ado's Mata block prevents load-time compilation
    * failures while retaining section, subsection and item-level conditions.
    _suso_jar
    tempfile QXCSV
    local qxcsv = subinstr(`"`QXCSV'"', "\", "/", .)
    capture macro drop SUSO_QX_FILE SUSO_QX_OUT SUSO_QX_CWD             ///
        SUSO_QX_RESOLVED SUSO_QX_RC SUSO_QX_MSG
    global SUSO_QX_FILE `"`file'"'
    global SUSO_QX_OUT  `"`qxcsv'"'
    global SUSO_QX_CWD  `"`qxpwd'"'
    global SUSO_QX_RESOLVED ""
    global SUSO_QX_RC ""
    global SUSO_QX_MSG ""
    capture noisily javacall org.worldbank.suso.Stata qxmeta, classpath("$SUSO_JAR")
    local jrc = _rc
    local qxrc "$SUSO_QX_RC"
    local qxmsg `"$SUSO_QX_MSG"'
    local qxresolved `"$SUSO_QX_RESOLVED"'
    capture macro drop SUSO_QX_FILE SUSO_QX_OUT SUSO_QX_CWD                     ///
        SUSO_QX_RESOLVED SUSO_QX_RC SUSO_QX_MSG
    if `jrc' | "`qxrc'"!="0" {
        di as err "suso paradata qx: questionnaire parser failed."
        if `"`qxmsg'"'!="" di as err "  `qxmsg'"
        if `"`qxresolved'"'!="" di as err `"  resolved path: `qxresolved'"'
        exit 459
    }
    capture confirm file `"`qxcsv'"'
    if _rc {
        di as err "suso paradata qx: Java parser did not create its metadata file."
        exit 459
    }

    import delimited using `"`qxcsv'"', delimiter(comma) varnames(1)             ///
        stringcols(_all) bindquote(strict) encoding(utf-8) clear
    quietly destring qx_nval qx_nopts, replace force
    foreach v in qx_var qx_section qx_subsection qx_type qx_text                ///
        qx_section_enable qx_group_enable qx_item_enable qx_parent_enable       ///
        qx_enable qx_enable_deps qx_calc qx_valmsg qx_opts qx_optvals qx_optmap ///
        qx_section_tri qx_group_tri qx_item_tri {
        capture confirm string variable `v'
        if _rc {
            di as err "suso paradata qx: parser output is missing `v'."
            exit 459
        }
    }
    if _N==0 {
        di as err "suso paradata qx: no questions found — expected a Survey Solutions questionnaire preview HTML file."
        exit 459
    }

    label variable qx_var             "variable name"
    label variable qx_section         "section"
    label variable qx_subsection      "subsection/group"
    label variable qx_type            "question type"
    label variable qx_text            "question text"
    label variable qx_section_enable  "section enabling condition"
    label variable qx_group_enable    "subsection/group enabling condition"
    label variable qx_item_enable     "item-level enabling condition"
    label variable qx_parent_enable   "combined parent enabling condition"
    label variable qx_enable          "effective enabling condition"
    label variable qx_enable_deps     "direct and calculated-variable dependencies"
    label variable qx_calc            "calculated-variable expression"
    label variable qx_nval            "number of validation rules"
    label variable qx_valmsg          "first validation message"
    label variable qx_opts            "answer options (first 8 display; map stores first 60)"
    label variable qx_optvals         "answer option values (first 60)"
    label variable qx_optmap          "answer value-label map (internal)"
    label variable qx_nopts           "number of answer options"
    label variable qx_section_tri     "section condition translated for final-data evaluation"
    label variable qx_group_tri       "group condition translated for final-data evaluation"
    label variable qx_item_tri        "item condition translated for final-data evaluation"
    char _dta[suso_paradata] qx

    quietly count if qx_enable!=""
    local ne = r(N)
    quietly count if qx_nval>0
    local nv = r(N)
    di as txt "suso paradata: parsed " as res _N as txt " questions ("             ///
        as res "`ne'" as txt " with effective skip logic, " as res "`nv'" as txt " with validations)."
    di as txt "  inherited section/subsection conditions are included in qx_enable."
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
    syntax [if] , QX(string) DATA(string) [ SAVing(string) replace MISScodes(numlist) TOP(integer 10) HTML(string) STatus(string) FILTERS(string) ]
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
    quietly bysort qx_var (qx_section): keep if _n==1
    quietly count
    local ncb = r(N)
    forvalues i = 1/`ncb' {
        local v_`i'  = qx_var[`i']
        local c_`i'  = c_tr[`i']
        local t_`i'  = qx_type[`i']
        local ov_`i' = qx_optvals[`i']
        local no_`i' = qx_nopts[`i']
    }
    tempfile CB
    rename qx_var qvar
    quietly keep qvar qx_section qx_type qx_text qx_enable
    quietly save `"`CB'"'

    * ---- data: normalise SuSo sentinels so missing() means unanswered ------------
    di as txt "suso paradata: loading exported data and normalising missing codes ..."
    quietly use `"`data'"', clear
    capture confirm variable interview__id
    if _rc {
        di as err "suso paradata check: data() must be a Survey Solutions main export file (interview__id not found)."
        exit 459
    }
    * optional record restriction: any Stata expression via the if qualifier
    if `"`if'"'!="" {
        capture keep `if'
        if _rc {
            di as err `"suso paradata check: the if expression could not be applied: `if'"'
            exit 198
        }
        if _N==0 {
            di as err "suso paradata check: no records match the if expression."
            exit 2000
        }
        di as txt "  restricted by expression: " as res `"`if'"' as txt " -> " as res _N as txt " records."
    }

    * optional restriction by interview status; status(approved) = 120 + 130
    if `"`status'"'!="" {
        capture confirm numeric variable interview__status
        if _rc {
            di as err "suso paradata check: status() given but interview__status is not in the data."
            exit 111
        }
        local stnums `"`status'"'
        if lower(strtrim(`"`status'"'))=="approved" local stnums "120 130"
        capture numlist "`stnums'"
        if _rc {
            di as err "suso paradata check: status() takes a list of status codes or the word approved."
            exit 198
        }
        tempvar kp
        quietly gen byte `kp' = 0
        foreach s of numlist `stnums' {
            quietly replace `kp' = 1 if interview__status==`s'
        }
        quietly keep if `kp'
        quietly drop `kp'
        if _N==0 {
            di as err "suso paradata check: no records match status(`status')."
            exit 2000
        }
        di as txt "  restricted to interview__status in {" as res "`stnums'" as txt "}: " as res _N as txt " records."
    }
    local nobs = _N
    * status inventory for the dashboard (per-status count vectors)
    local slist ""
    local jmeta ""
    capture confirm numeric variable interview__status
    if !_rc {
        quietly levelsof interview__status, local(slist)
        if `:word count `slist'' > 12 local slist ""
        foreach s of local slist {
            local lb : label (interview__status) `s'
            local lb = subinstr(subinstr(`"`lb'"', char(34), "", .), char(92), "", .)
            quietly count if interview__status==`s'
            local jmeta `"`jmeta'`=cond(`"`jmeta'"'=="","",",")'{"c":`s',"l":"`lb'","n":`r(N)'}"'
        }
    }
    * dynamic filter dimensions: per-value count vectors for chosen variables
    local fdimvars ""
    local jfdims ""
    if `"`filters'"'!="" {
        foreach fvv of local filters {
            capture confirm numeric variable `fvv'
            if _rc {
                di as txt "  filters(): " as res "`fvv'" as txt " not found or not numeric - skipped."
                continue
            }
            quietly levelsof `fvv', local(fl)
            local nfl : word count `fl'
            if `nfl'==0 | `nfl'>20 {
                di as txt "  filters(): " as res "`fvv'" as txt " has `nfl' distinct values (limit 20) - skipped."
                continue
            }
            local __fvbudget = 0
            foreach z of local fdimvars {
                local __fvbudget = `__fvbudget' + `:word count `fdl_`z'''
            }
            if `__fvbudget' + `nfl' > 40 {
                di as txt "  filters(): value budget exceeded (40 across all variables) - " as res "`fvv'" as txt " skipped."
                continue
            }
            local fdimvars "`fdimvars' `fvv'"
            local fdl_`fvv' "`fl'"
            local jv1 ""
            foreach s of local fl {
                local lb : label (`fvv') `s'
                local lb = subinstr(subinstr(`"`lb'"', char(34), "", .), char(92), "", .)
                quietly count if `fvv'==`s'
                local jv1 `"`jv1'`=cond(`"`jv1'"'=="","",",")'{"c":"`s'","l":"`lb'","n":`r(N)'}"'
            }
            local jfdims `"`jfdims'`=cond(`"`jfdims'"'=="","",",")'{"v":"`fvv'","vals":[`jv1']}"'
        }
        local fdimvars = strtrim("`fdimvars'")
    }
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
        long n_on long n_off long n_und long n_vund long n_viol long n_imiss      ///
        long n_bad str244 badv str2000 jstat str2000 jfilt using `"`RES'"'
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
            post `P' ("`v_`i''") ("not in file") (.) (.) (.) (.) (.) (.) (.) ("") ("") ("")
            continue
        }
        local isnum 1
        capture confirm numeric variable `v_`i''
        if _rc local isnum 0
        local anse = cond(`isnum', "(!missing(`v_`i''))", `"(`v_`i''!="")"')
        local nund 0
        local nvu 0
        local f_on ""
        local f_un ""
        local f_vi ""
        local f_im ""
        if `"`c_`i''"'=="" {
            local ++k_nocond
            local st "always on"
            quietly count if !`anse'
            local nim = r(N)
            local non = `nobs'
            local nof 0
            local nvl 0
            foreach s of local slist {
                quietly count if interview__status==`s'
                local f_on "`f_on',`r(N)'"
                local f_un "`f_un',0"
                local f_vi "`f_vi',0"
                quietly count if !`anse' & interview__status==`s'
                local f_im "`f_im',`r(N)'"
            }
        }
        else {
            capture drop `en'
            capture quietly gen byte `en' = (`c_`i'')
            if _rc {
                local ++k_noev
                if `:list sizeof badlist' < 12 local badlist "`badlist' `v_`i''"
                post `P' ("`v_`i''") ("not evaluable") (.) (.) (.) (.) (.) (.) (.) ("") ("") ("")
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
            quietly count if missing(`en') & `anse'
            local nvu = r(N)
            if `non' + `nof' + `nund' != _N {
                di as err "suso paradata check: internal partition failure on `v_`i'' (`non'+`nof'+`nund' != `=_N') - please report this."
            }
            foreach s of local slist {
                quietly count if `en'==1 & interview__status==`s'
                local f_on "`f_on',`r(N)'"
                quietly count if missing(`en') & interview__status==`s'
                local f_un "`f_un',`r(N)'"
                quietly count if `en'==0 & `anse' & interview__status==`s'
                local f_vi "`f_vi',`r(N)'"
                quietly count if `en'==1 & !`anse' & interview__status==`s'
                local f_im "`f_im',`r(N)'"
            }
        }
        local nbd 0
        local bvs ""
        if `isnum' & `no_`i''>0 & `no_`i''<=60 & strpos(lower("`t_`i''"),"single-select")>0 {
            local vl : subinstr local ov_`i' " " ",", all
            if "`vl'"!="" {
                capture quietly count if !missing(`v_`i'') & !inlist(`v_`i'', `vl')
                if !_rc local nbd = r(N)
                if `nbd'>0 {
                    preserve
                    quietly keep if !missing(`v_`i'') & !inlist(`v_`i'', `vl')
                    quietly contract `v_`i'', freq(__bc)
                    gsort -__bc `v_`i''
                    forvalues b = 1/`=min(5,_N)' {
                        local bvs "`bvs' `=strofreal(`v_`i''[`b'])' (x`=__bc[`b']')"
                    }
                    restore
                }
            }
        }
        local f_bd ""
        foreach s of local slist {
            local bs 0
            if `nbd'>0 {
                capture quietly count if !missing(`v_`i'') & !inlist(`v_`i'', `vl') & interview__status==`s'
                if !_rc local bs = r(N)
            }
            local f_bd "`f_bd',`bs'"
        }
        local jfilt ""
        foreach fvv of local fdimvars {
            local jf1 ""
            foreach s of local fdl_`fvv' {
                if `"`c_`i''"'=="" {
                    quietly count if `fvv'==`s'
                    local o1 = r(N)
                    local u1 0
                    local x1 0
                    quietly count if !`anse' & `fvv'==`s'
                    local m1 = r(N)
                }
                else {
                    quietly count if `en'==1 & `fvv'==`s'
                    local o1 = r(N)
                    quietly count if missing(`en') & `fvv'==`s'
                    local u1 = r(N)
                    quietly count if `en'==0 & `anse' & `fvv'==`s'
                    local x1 = r(N)
                    quietly count if `en'==1 & !`anse' & `fvv'==`s'
                    local m1 = r(N)
                }
                local b1 0
                if `nbd'>0 {
                    capture quietly count if !missing(`v_`i'') & !inlist(`v_`i'', `vl') & `fvv'==`s'
                    if !_rc local b1 = r(N)
                }
                local jf1 `"`jf1'`=cond(`"`jf1'"'=="","",",")'"`s'":[`o1',`u1',`x1',`m1',`b1']"'
            }
            local jfilt `"`jfilt'`=cond(`"`jfilt'"'=="","",",")'"`fvv'":{`jf1'}"'
        }
        if `"`jfilt'"'!="" local jfilt `","fv":{`jfilt'}"'
        local jfrag ""
        if "`slist'"!="" {
            local jfrag `","ons":[`=substr("`f_on'",2,.)'],"uns":[`=substr("`f_un'",2,.)'],"vis":[`=substr("`f_vi'",2,.)'],"ims":[`=substr("`f_im'",2,.)'],"bds":[`=substr("`f_bd'",2,.)']"'
        }
        post `P' ("`v_`i''") ("`st'") (`non') (`nof') (`nund') (`nvu') (`nvl') (`nim') (`nbd') (strtrim("`bvs'")) (`"`jfrag'"') (`"`jfilt'"')
    }
    postclose `P'
    quietly use `"`RES'"', clear
    quietly merge 1:1 qvar using `"`CB'"', keep(master match) nogenerate
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
    quietly summarize n_vund
    local tvund = r(sum)
    di as txt "  answers on DISABLED questions (hard skip violations) : " as res "`tviol'"
    di as txt "  answered while the gate itself is unanswered          : " as res "`tvund'"
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
    else {
        quietly summarize n_off
        di as txt _n "  no hard skip violations: " as res %12.0fc r(sum) as txt " disabled question-cases were"
        di as txt "  checked and none carries an answer. SuSo deletes answers when questions are"
        di as txt "  disabled, so violations here mean version changes or API writes - the practical"
        di as txt "  signal is the answered-while-gate-unanswered count above."
    }
    quietly count if n_vund>0 & !missing(n_vund)
    if r(N)>0 {
        tempvar sk2
        quietly gen double `sk2' = cond(missing(n_vund), -1, n_vund)
        gsort -`sk2' qvar
        di as txt _n "  answered while the gate itself is unanswered (top `top'):"
        di as txt "  {ul:variable                }  {ul:answered}  {ul:undetermined}"
        forvalues i = 1/`=min(`top',_N)' {
            if n_vund[`i']>0 & !missing(n_vund[`i']) {
                local vv : di %-24s abbrev(qvar[`i'],24)
                di as txt "  " as res "`vv'" as txt "  " %8.0f `=n_vund[`i']' "  " %12.0f `=n_und[`i']'
            }
        }
        di as txt "  a clean interview flow cannot produce these - preloads or version changes."
        quietly drop `sk2'
    }
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
    di as txt "  referenced numeric question was itself unanswered; n_vund counts the"
    di as txt "  suspicious subset of those that nevertheless carry an answer - impossible"
    di as txt "  in a clean interview flow (preloads or a questionnaire version change)."
    di as txt "  data in memory = one row per codebook question (merge/save as needed)."
    di as txt "{hline 72}"

    * ---- dynamic dashboard ------------------------------------------------------
    if `"`html'"'!="" {
        if "`replace'"=="" {
            capture confirm new file `"`html'"'
            if _rc {
                di as err "suso: html() file already exists. Use -replace-."
                exit 602
            }
        }
        * JSON rows built in expression-land: escape backslash, quote, control chars
        foreach v in qvar qstatus qx_section qx_type qx_text qx_enable badv {
            quietly gen strL e_`v' = subinstr(subinstr(`v', char(92), char(92)+char(92), .), char(34), char(92)+char(34), .)
            quietly replace e_`v' = subinstr(subinstr(subinstr(e_`v', char(10), " ", .), char(13), " ", .), char(9), " ", .)
        }
        sort qvar
        quietly gen strL j_row = cond(_n>1, ",", "")                                        ///
            + "{" + char(34)+"v"+char(34)  + ":" + char(34) + e_qvar + char(34)             ///
            + "," + char(34)+"st"+char(34) + ":" + char(34) + e_qstatus + char(34)          ///
            + "," + char(34)+"s"+char(34)  + ":" + char(34) + substr(e_qx_section,1,120) + char(34) ///
            + "," + char(34)+"t"+char(34)  + ":" + char(34) + substr(e_qx_type,1,60) + char(34)     ///
            + "," + char(34)+"on"+char(34) + ":" + cond(missing(n_on), "null", strofreal(n_on))     ///
            + "," + char(34)+"und"+char(34)+ ":" + cond(missing(n_und), "null", strofreal(n_und))   ///
            + "," + char(34)+"vu"+char(34) + ":" + cond(missing(n_vund), "null", strofreal(n_vund)) ///
            + "," + char(34)+"vi"+char(34) + ":" + cond(missing(n_viol), "null", strofreal(n_viol)) ///
            + "," + char(34)+"im"+char(34) + ":" + cond(missing(n_imiss), "null", strofreal(n_imiss)) ///
            + "," + char(34)+"bd"+char(34) + ":" + cond(missing(n_bad), "null", strofreal(n_bad))   ///
            + "," + char(34)+"sh"+char(34) + ":" + cond(missing(imiss_share), "null", strtrim(string(imiss_share, "%9.4f"))) ///
            + "," + char(34)+"q"+char(34)  + ":" + char(34) + substr(e_qx_text,1,400) + char(34)    ///
            + "," + char(34)+"e"+char(34)  + ":" + char(34) + substr(e_qx_enable,1,300) + char(34)  ///
            + "," + char(34)+"bv"+char(34) + ":" + char(34) + e_badv + char(34) + jstat + jfilt + "}"
        _suso_para_hesc `"`data'"'
        local dsrc `"`r(out)'"'
        if `"`if'"'!="" {
            _suso_para_hesc `"`if'"'
            local dsrc `"`dsrc' &nbsp;-&nbsp; restricted: `r(out)'"'
        }
        local nobsc : di %12.0fc `nobs'
        local nobsc = trim("`nobsc'")
        local wst ""
        if "$SUSO_WS"!="" local wst " — $SUSO_WS"
        local now = trim("`c(current_date)' `c(current_time)'")
        tempname hf
        quietly file open `hf' using `"`html'"', write replace text
    file write `hf' `"<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Data QC - Skip Logic and Values</title><style>"' _n
    file write `hf' `"body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:#f4f5f7;color:#1a1a1a}"' _n
    file write `hf' `".logobar{background:#fff;padding:10px 28px;border-bottom:1px solid #e0e0e0}"' _n
    file write `hf' `".logobar .wbtxt{font-size:13px;letter-spacing:.06em;color:#002244;font-weight:600}.logobar .wbtxt span{color:#8a8a8a;font-weight:400}"' _n
    file write `hf' `".mast{background:#002244;color:#fff;padding:18px 28px}.mast h1{margin:0;font-size:21px;font-weight:600}.mast .sub{color:#c9d4e0;font-size:12px;margin-top:5px;word-break:break-all}"' _n
    file write `hf' `".wrap{max-width:1040px;margin:0 auto;padding:16px 28px 40px}"' _n
    file write `hf' `".cards{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0 4px}"' _n
    file write `hf' `".card{flex:1 1 130px;background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:10px 13px;border-top:3px solid #002244}"' _n
    file write `hf' `".card.dim{border-top-color:#9aa7b5}.card.warn{border-top-color:#C9A227}"' _n
    file write `hf' `".card .v{font-size:20px;font-weight:700;color:#002244}.card .k{font-size:11px;color:#666;margin-top:2px;text-transform:uppercase;letter-spacing:.04em}"' _n
    file write `hf' `".panel{background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:12px 16px;margin:12px 0;display:flex;flex-wrap:wrap;gap:14px;align-items:flex-end;position:sticky;top:0;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.06)}"' _n
    file write `hf' `".ctrl{display:flex;flex-direction:column;gap:3px}"' _n
    file write `hf' `".ctrl label{font-size:10.5px;color:#555;text-transform:uppercase;letter-spacing:.03em}"' _n
    file write `hf' `".ctrl input,.ctrl select{font-size:13px;padding:4px 6px;border:1px solid #c9cfd6;border-radius:5px;min-width:64px}"' _n
    file write `hf' `"#c_q{min-width:200px}#c_sec{min-width:180px}"' _n
    file write `hf' `"h2{font-size:15px;color:#002244;border-bottom:2px solid #C9A227;padding-bottom:4px;margin:22px 0 6px}"' _n
    file write `hf' `".note{font-size:12px;color:#555;margin:2px 0 8px}"' _n
    file write `hf' `"section{background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:10px 16px 12px;margin-top:8px}"' _n
    file write `hf' `".hrow{display:flex;align-items:center;gap:8px;margin:3px 0;font-size:12px}"' _n
    file write `hf' `".hlab{width:200px;text-align:right;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}"' _n
    file write `hf' `".htrack{flex:1;background:#eef0f2;border-radius:3px;height:12px;overflow:hidden}"' _n
    file write `hf' `".hbar{display:block;height:12px;background:#002244}"' _n
    file write `hf' `".hval{width:120px;white-space:nowrap}"' _n
    file write `hf' `"details.qrow{background:#fff;border:1px solid #e3e6ea;border-radius:6px;margin:4px 0}"' _n
    file write `hf' `".qrow summary{display:flex;gap:10px;align-items:center;padding:7px 12px;cursor:pointer;font-size:12.5px;flex-wrap:wrap;list-style:none}"' _n
    file write `hf' `".qrow summary::-webkit-details-marker{display:none}"' _n
    file write `hf' `".qv{min-width:150px;font-weight:700;color:#002244}"' _n
    file write `hf' `".qsec{color:#777;font-size:11px;flex:1;min-width:120px}"' _n
    file write `hf' `".qn{color:#444;font-size:11.5px;white-space:nowrap}"' _n
    file write `hf' `".strack{display:inline-block;width:60px;background:#eef0f2;height:8px;border-radius:2px;vertical-align:middle;margin-right:4px}"' _n
    file write `hf' `".sbar{display:block;height:8px;background:#C9A227}"' _n
    file write `hf' `".qbody{padding:4px 14px 10px;border-top:1px solid #eef0f2;font-size:12px;color:#333}"' _n
    file write `hf' `".qt{margin:6px 0}.qm{color:#666;margin:3px 0;font-size:11.5px}"' _n
    file write `hf' `".chip{font-size:10px;border-radius:9px;padding:2px 8px;text-transform:uppercase;letter-spacing:.03em}"' _n
    file write `hf' `".chip.ok{background:#eaf0f7;color:#002244}.chip.dim{background:#f0f0f0;color:#666}"' _n
    file write `hf' `".chip.warn{background:#fdf6e3;color:#7a5b00}.chip.off{background:#f7f7f7;color:#999}"' _n
    file write `hf' `".mono{font-family:Consolas,monospace}.nodata{color:#888;font-size:12px}"' _n
    file write `hf' `".legend2{font-size:11.5px;color:#555;background:#fff;border:1px solid #e3e6ea;border-radius:8px;padding:8px 12px;margin:10px 0;line-height:1.5}"' _n
    file write `hf' `".verdict{font-size:13px;font-weight:600;border-radius:8px;padding:10px 14px;margin:10px 0;border:1px solid}"' _n
    file write `hf' `".verdict.ok{background:#eef7f0;border-color:#bfe0c8;color:#1e6b34}.verdict.warn{background:#fdf6e3;border-color:#ecd9a0;color:#7a5b00}.verdict.bad{background:#fbeeee;border-color:#e6c3c3;color:#8a1f1f}"' _n
    file write `hf' `".foot{font-size:11px;color:#777;margin-top:24px;line-height:1.5}"' _n
    file write `hf' `"#l_more{font-size:11.5px;color:#8a6d00}"' _n
    file write `hf' `"</style></head><body>"' _n
    file write `hf' `"<div class="logobar"><!-- wbLogo slot: replace content with the base64 banner img -->"' _n
    file write `hf' `"<span class="wbtxt">THE WORLD BANK <span>| Development Economics - Policy Indicators</span> &nbsp;-&nbsp; ENTERPRISE SURVEYS <span>- What Businesses Experience</span></span></div>"' _n
    file write `hf' `"<div class="mast"><h1>Data QC — Skip Logic and Values`wst'</h1>"' _n
    file write `hf' `"<div class="sub">Generated `now' &nbsp;-&nbsp; `dsrc'</div></div>"' _n
    file write `hf' `"<div class="wrap">"' _n
    file write `hf' `"<div class="cards">"' _n
    file write `hf' `"<div class="card dim"><div class="v">`nobsc'</div><div class="k">records audited</div></div>"' _n
    file write `hf' `"<div class="card"><div class="v">`k_eval'</div><div class="k">conditions evaluated</div></div>"' _n
    file write `hf' `"<div class="card dim"><div class="v">`k_nocond'</div><div class="k">always on</div></div>"' _n
    file write `hf' `"<div class="card warn"><div class="v">`k_noev'</div><div class="k">not evaluable</div></div>"' _n
    file write `hf' `"<div class="card dim"><div class="v">`k_absent'</div><div class="k">not in this file</div></div>"' _n
    file write `hf' `"</div>"' _n
    file write `hf' `"<div class="panel">"' _n
    file write `hf' `"<div class="ctrl"><label>Search variable or text</label><input id="c_q" type="text" placeholder="e.g. a3 or sales"></div>"' _n
    file write `hf' `"<div class="ctrl"><label>Section</label><select id="c_sec"></select></div>"' _n
    file write `hf' `"<div class="ctrl"><label>Check status</label><select id="c_st"><option value="">All</option><option>evaluated</option><option value="always on">always asked</option><option>not evaluable</option><option>not in file</option></select></div>"' _n
    file write `hf' `"<div class="ctrl" id="ctl_ist"><label>Interview status</label><select id="c_ist"></select></div>"' _n
    file write `hf' `"<div class="ctrl" id="ctl_fd"><label>Filter variable</label><select id="c_fd"></select></div>"' _n
    file write `hf' `"<div class="ctrl" id="ctl_fv"><label>= value</label><select id="c_fv"></select></div>"' _n
    file write `hf' `"<div class="ctrl"><label>Min share % (chart)</label><input id="c_minsh" type="number" min="0" max="100" step="1" value="0"></div>"' _n
    file write `hf' `"<div class="ctrl"><label>Sort questions by</label><select id="c_sort"><option value="hard">hard problems first</option><option value="sh">worst nonresponse share</option><option value="im">most unanswered</option><option value="vi">most violations</option><option value="bd">most out-of-list</option><option value="v">variable name</option></select></div>"' _n
    file write `hf' `"<div class="ctrl"><label>Problems only</label><input id="c_prob" type="checkbox" style="width:20px;height:20px"></div>"' _n
    file write `hf' `"</div>"' _n
    file write `hf' `"<div class="legend2"><b>Reading the counts:</b> asked = the skip logic says the question applies to the record &nbsp;&middot;&nbsp; viol = answered while the logic says it should be off (hard problem) &nbsp;&middot;&nbsp; unans = applies but no answer was recorded &nbsp;&middot;&nbsp; bad codes = a value outside the option list &nbsp;&middot;&nbsp; undetermined = the enabling condition references an unanswered question</div>"' _n
    file write `hf' `"<div id="v_chk" class="verdict ok"></div>"' _n
    file write `hf' `"<div class="cards">"' _n
    file write `hf' `"<div class="card"><div class="v" id="k_recs">-</div><div class="k">records in view</div></div>"' _n
    file write `hf' `"<div class="card"><div class="v" id="k_shown">-</div><div class="k">questions in view</div></div>"' _n
    file write `hf' `"<div class="card warn"><div class="v" id="k_imiss">-</div><div class="k">unanswered when enabled</div></div>"' _n
    file write `hf' `"<div class="card warn"><div class="v" id="k_viol">-</div><div class="k">answers on disabled qs</div></div>"' _n
    file write `hf' `"<div class="card warn"><div class="v" id="k_bad">-</div><div class="k">out-of-list values</div></div>"' _n
    file write `hf' `"<div class="card warn"><div class="v" id="k_vund">-</div><div class="k">answered, gate unanswered</div></div>"' _n
    file write `hf' `"</div>"' _n
    file write `hf' `"<h2>Item nonresponse (enabled but unanswered)</h2>"' _n
    file write `hf' `"<div class="note">Top questions by unanswered share among records where the question was enabled (10+ enabled records). Service and desk questions often sit at 100% - use the filters or search to focus on interview content, and raise Min share to cut noise.</div>"' _n
    file write `hf' `"<section id="ch_imiss"></section>"' _n
    file write `hf' `"<div id="sec_viol">"' _n
    file write `hf' `"<h2>Answers on disabled questions</h2>"' _n
    file write `hf' `"<div class="note">Hard skip violations: an answer is present although the skip logic disables the question. These enter via preloading, API writes, or questionnaire version changes.</div>"' _n
    file write `hf' `"<section id="ch_viol"></section>"' _n
    file write `hf' `"</div>"' _n
    file write `hf' `"<div id="sec_vund">"' _n
    file write `hf' `"<h2>Answered while the gate is unanswered</h2>"' _n
    file write `hf' `"<div class="note">An answer exists although the question controlling it was never answered - impossible in a clean interview flow. These come from preloading or questionnaire version changes and are the practical skip-violation signal in Survey Solutions exports.</div>"' _n
    file write `hf' `"<section id="ch_vund"></section>"' _n
    file write `hf' `"</div>"' _n
    file write `hf' `"<div id="sec_bad">"' _n
    file write `hf' `"<h2>Single-select values outside the option list</h2>"' _n
    file write `hf' `"<div class="note">Values not in the questionnaire option list - open the question below to see which values (often special codes missing from the instrument definition).</div>"' _n
    file write `hf' `"<section id="ch_bad"></section>"' _n
    file write `hf' `"</div>"' _n
    file write `hf' `"<h2>Questions</h2>"' _n
    file write `hf' `"<div class="note">Click any row for the question text, its skip condition, and the offending values. <span id="l_more"></span></div>"' _n
    file write `hf' `"<div id="list"></div>"' _n
    file write `hf' `"<div class="foot"><b>Method.</b> Enabling conditions from the questionnaire HTML were translated from C# to Stata; conditions whose numeric referents are unanswered are scored undetermined and excluded from both counts (C# treats null as false, Stata treats missing as infinity). Missing codes normalised: `misscodes' and the ##N/A## string sentinel. Untranslatable conditions are labelled, never guessed. Produced by suso paradata check (suso v1.7.12) on `now'.</div>"' _n
    file write `hf' `"</div><script>"' _n
    file write `hf' `"var D={"meta":{"statuses":[`jmeta'],"fdims":[`jfdims']},"rows":["' _n
    forvalues i = 1/`=_N' {
        file write `hf' (j_row[`i']) _n
    }
    file write `hf' `"]};"' _n
    file write `hf' `"/* suso paradata check - dynamic dashboard engine */"' _n
    file write `hf' `"var C = {"' _n
    file write `hf' `"  deriveF: function(rows, dim, val){"' _n
    file write `hf' `"    var out=[], i, r, cell;"' _n
    file write `hf' `"    for(i=0;i<rows.length;i++){"' _n
    file write `hf' `"      r=rows[i];"' _n
    file write `hf' `"      if(!r.fv || !r.fv[dim] || !r.fv[dim][val]){ out.push(r); continue; }"' _n
    file write `hf' `"      cell=r.fv[dim][val];"' _n
    file write `hf' `"      out.push({v:r.v, st:r.st, s:r.s, t:r.t, q:r.q, e:r.e, bv:r.bv, vu:cell[1]>0?null:r.vu,"' _n
    file write `hf' `"        on:cell[0], und:cell[1], vi:cell[2], im:cell[3], bd:cell[4],"' _n
    file write `hf' `"        sh:cell[0]>0?cell[3]/cell[0]:null});"' _n
    file write `hf' `"    }"' _n
    file write `hf' `"    return out;"' _n
    file write `hf' `"  },"' _n
    file write `hf' `"  recsF: function(meta, dim, val){"' _n
    file write `hf' `"    if(!meta || !meta.fdims) return null;"' _n
    file write `hf' `"    var i, j;"' _n
    file write `hf' `"    for(i=0;i<meta.fdims.length;i++){"' _n
    file write `hf' `"      if(meta.fdims[i].v!==dim) continue;"' _n
    file write `hf' `"      for(j=0;j<meta.fdims[i].vals.length;j++)"' _n
    file write `hf' `"        if(meta.fdims[i].vals[j].c===val) return meta.fdims[i].vals[j].n;"' _n
    file write `hf' `"    }"' _n
    file write `hf' `"    return null;"' _n
    file write `hf' `"  },"' _n
    file write `hf' `"  derive: function(rows, meta, sel){"' _n
    file write `hf' `"    if(sel==='' || !meta || !meta.statuses || !meta.statuses.length) return rows;"' _n
    file write `hf' `"    var idxs=[], i, j;"' _n
    file write `hf' `"    if(sel==='APP'){"' _n
    file write `hf' `"      for(i=0;i<meta.statuses.length;i++) if(meta.statuses[i].c===120||meta.statuses[i].c===130) idxs.push(i);"' _n
    file write `hf' `"    } else if(sel==='FIELD'){"' _n
    file write `hf' `"      for(i=0;i<meta.statuses.length;i++) if(meta.statuses[i].c>=65) idxs.push(i);"' _n
    file write `hf' `"    } else idxs.push(parseInt(sel,10));"' _n
    file write `hf' `"    var out=[];"' _n
    file write `hf' `"    for(i=0;i<rows.length;i++){"' _n
    file write `hf' `"      var r=rows[i];"' _n
    file write `hf' `"      if(!r.ons){ out.push(r); continue; }"' _n
    file write `hf' `"      var d={v:r.v, st:r.st, s:r.s, t:r.t, q:r.q, e:r.e, bv:r.bv, vu:r.vu, on:0, und:0, vi:0, im:0, bd:0, sh:null};"' _n
    file write `hf' `"      for(j=0;j<idxs.length;j++){"' _n
    file write `hf' `"        var k=idxs[j];"' _n
    file write `hf' `"        d.on+=r.ons[k]||0; d.und+=(r.uns?r.uns[k]:0)||0; d.vi+=(r.vis?r.vis[k]:0)||0;"' _n
    file write `hf' `"        d.im+=(r.ims?r.ims[k]:0)||0; d.bd+=(r.bds?r.bds[k]:0)||0;"' _n
    file write `hf' `"      }"' _n
    file write `hf' `"      d.sh = d.on>0 ? d.im/d.on : null;"' _n
    file write `hf' `"      out.push(d);"' _n
    file write `hf' `"    }"' _n
    file write `hf' `"    return out;"' _n
    file write `hf' `"  },"' _n
    file write `hf' `"  recs: function(meta, sel){"' _n
    file write `hf' `"    if(!meta || !meta.statuses || !meta.statuses.length) return null;"' _n
    file write `hf' `"    var i, t=0;"' _n
    file write `hf' `"    if(sel===''){ for(i=0;i<meta.statuses.length;i++) t+=meta.statuses[i].n||0; return t; }"' _n
    file write `hf' `"    if(sel==='APP'){"' _n
    file write `hf' `"      for(i=0;i<meta.statuses.length;i++) if(meta.statuses[i].c===120||meta.statuses[i].c===130) t+=meta.statuses[i].n||0;"' _n
    file write `hf' `"      return t;"' _n
    file write `hf' `"    }"' _n
    file write `hf' `"    if(sel==='FIELD'){"' _n
    file write `hf' `"      for(i=0;i<meta.statuses.length;i++) if(meta.statuses[i].c>=65) t+=meta.statuses[i].n||0;"' _n
    file write `hf' `"      return t;"' _n
    file write `hf' `"    }"' _n
    file write `hf' `"    var k=parseInt(sel,10);"' _n
    file write `hf' `"    return meta.statuses[k] ? (meta.statuses[k].n||0) : null;"' _n
    file write `hf' `"  },"' _n
    file write `hf' `"  filt: function(rows, S){"' _n
    file write `hf' `"    var out=[], i, r, q;"' _n
    file write `hf' `"    for(i=0;i<rows.length;i++){"' _n
    file write `hf' `"      r=rows[i];"' _n
    file write `hf' `"      if(S.sec && r.s!==S.sec) continue;"' _n
    file write `hf' `"      if(S.st && r.st!==S.st) continue;"' _n
    file write `hf' `"      if(S.prob && !((r.vi||0)>0 || (r.im||0)>0 || (r.bd||0)>0 || (r.vu||0)>0)) continue;"' _n
    file write `hf' `"      if(S.q){"' _n
    file write `hf' `"        q=S.q.toLowerCase();"' _n
    file write `hf' `"        if(r.v.toLowerCase().indexOf(q)<0 && (r.q||'').toLowerCase().indexOf(q)<0) continue;"' _n
    file write `hf' `"      }"' _n
    file write `hf' `"      out.push(r);"' _n
    file write `hf' `"    }"' _n
    file write `hf' `"    return out;"' _n
    file write `hf' `"  },"' _n
    file write `hf' `"  srt: function(rows, key){"' _n
    file write `hf' `"    var out=rows.slice();"' _n
    file write `hf' `"    if(key==='v'){ out.sort(function(a,b){ return a.v<b.v?-1:1; }); return out; }"' _n
    file write `hf' `"    if(key==='hard'){"' _n
    file write `hf' `"      out.sort(function(a,b){"' _n
    file write `hf' `"        var ah=(a.vi||0)+(a.bd||0)+(a.vu||0), bh=(b.vi||0)+(b.bd||0)+(b.vu||0);"' _n
    file write `hf' `"        if(bh!==ah) return bh-ah;"' _n
    file write `hf' `"        var as2=(a.sh===null||a.sh===undefined)?-1:a.sh, bs2=(b.sh===null||b.sh===undefined)?-1:b.sh;"' _n
    file write `hf' `"        if(bs2!==as2) return bs2-as2;"' _n
    file write `hf' `"        return a.v<b.v?-1:1;"' _n
    file write `hf' `"      });"' _n
    file write `hf' `"      return out;"' _n
    file write `hf' `"    }"' _n
    file write `hf' `"    out.sort(function(a,b){"' _n
    file write `hf' `"      var av=a[key], bv=b[key];"' _n
    file write `hf' `"      if(av===null||av===undefined) av=-1;"' _n
    file write `hf' `"      if(bv===null||bv===undefined) bv=-1;"' _n
    file write `hf' `"      if(bv!==av) return bv-av;"' _n
    file write `hf' `"      return a.v<b.v?-1:1;"' _n
    file write `hf' `"    });"' _n
    file write `hf' `"    return out;"' _n
    file write `hf' `"  },"' _n
    file write `hf' `"  kpis: function(rows){"' _n
    file write `hf' `"    var t={n:rows.length, im:0, vi:0, bd:0, vu:0}, i;"' _n
    file write `hf' `"    for(i=0;i<rows.length;i++){"' _n
    file write `hf' `"      t.im+=rows[i].im||0; t.vi+=rows[i].vi||0; t.bd+=rows[i].bd||0; t.vu+=rows[i].vu||0;"' _n
    file write `hf' `"    }"' _n
    file write `hf' `"    return t;"' _n
    file write `hf' `"  },"' _n
    file write `hf' `"  topBy: function(rows, key, minOn, minSh, n){"' _n
    file write `hf' `"    var out=[], i, r;"' _n
    file write `hf' `"    for(i=0;i<rows.length;i++){"' _n
    file write `hf' `"      r=rows[i];"' _n
    file write `hf' `"      if(!(r[key]>0)) continue;"' _n
    file write `hf' `"      if(minOn && !((r.on||0)>=minOn)) continue;"' _n
    file write `hf' `"      if(minSh && !((r.sh||0)>=minSh)) continue;"' _n
    file write `hf' `"      out.push(r);"' _n
    file write `hf' `"    }"' _n
    file write `hf' `"    out=C.srt(out, key==='im'?'sh':key);"' _n
    file write `hf' `"    return out.slice(0, n||15);"' _n
    file write `hf' `"  }"' _n
    file write `hf' `"};"' _n
    file write `hf' `"if (typeof module!=='undefined' && module.exports) module.exports=C;"' _n
    file write `hf' _n
    file write `hf' `"if (typeof document!=='undefined') {"' _n
    file write `hf' `"var Q=String.fromCharCode(34);"' _n
    file write `hf' `"function at(n,v){ return ' '+n+'='+Q+v+Q; }"' _n
    file write `hf' `"function el(id){ return document.getElementById(id); }"' _n
    file write `hf' `"function esc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }"' _n
    file write `hf' `"function fc(x){"' _n
    file write `hf' `"  if(x===null||x===undefined) return '.';"' _n
    file write `hf' `"  var s=String(Math.round(x)), o='', c=0, i;"' _n
    file write `hf' `"  for(i=s.length-1;i>=0;i--){ o=s.charAt(i)+o; c++; if(c%3===0&&i>0) o=','+o; }"' _n
    file write `hf' `"  return o;"' _n
    file write `hf' `"}"' _n
    file write `hf' `"function pct(x){ return (x===null||x===undefined)?'.':(100*x).toFixed(1)+'%'; }"' _n
    file write `hf' _n
    file write `hf' `"function settings(){"' _n
    file write `hf' `"  return {"' _n
    file write `hf' `"    q: el('c_q').value.trim(),"' _n
    file write `hf' `"    sec: el('c_sec').value,"' _n
    file write `hf' `"    st: el('c_st').value,"' _n
    file write `hf' `"    prob: el('c_prob').checked,"' _n
    file write `hf' `"    ist: el('c_ist').value,"' _n
    file write `hf' `"    fd:  el('c_fd').value,"' _n
    file write `hf' `"    fv:  el('c_fv').value,"' _n
    file write `hf' `"    minsh: (parseFloat(el('c_minsh').value)||0)/100,"' _n
    file write `hf' `"    sort: el('c_sort').value"' _n
    file write `hf' `"  };"' _n
    file write `hf' `"}"' _n
    file write `hf' _n
    file write `hf' `"function hbars(cont, rows, key, denomNote){"' _n
    file write `hf' `"  if(!rows.length){ el(cont).innerHTML='<p class='+Q+'nodata'+Q+'>Nothing above the current thresholds.</p>'; return; }"' _n
    file write `hf' `"  var max=0, i;"' _n
    file write `hf' `"  for(i=0;i<rows.length;i++) if(rows[i][key]>max) max=rows[i][key];"' _n
    file write `hf' `"  var s='';"' _n
    file write `hf' `"  for(i=0;i<rows.length;i++){"' _n
    file write `hf' `"    var r=rows[i], w=Math.max(2, Math.round(100*r[key]/max));"' _n
    file write `hf' `"    var val=(key==='im') ? (fc(r.im)+' ('+pct(r.sh)+')') : fc(r[key]);"' _n
    file write `hf' `"    s+='<div class='+Q+'hrow'+Q+'><span class='+Q+'hlab mono'+Q+'>'+esc(r.v)+'</span>'+"' _n
    file write `hf' `"       '<span class='+Q+'htrack'+Q+'><span class='+Q+'hbar'+Q+at('style','width:'+w+'%')+'></span></span>'+"' _n
    file write `hf' `"       '<span class='+Q+'hval'+Q+'>'+val+'</span></div>';"' _n
    file write `hf' `"  }"' _n
    file write `hf' `"  el(cont).innerHTML=s;"' _n
    file write `hf' `"}"' _n
    file write `hf' _n
    file write `hf' `"function chip(st){"' _n
    file write `hf' `"  var cl = st==='evaluated'?'ok':(st==='always on'?'dim':(st==='not evaluable'?'warn':'off'));"' _n
    file write `hf' `"  var lab = st==='always on' ? 'always asked' : st;"' _n
    file write `hf' `"  return '<span class='+Q+'chip '+cl+Q+'>'+esc(lab)+'</span>';"' _n
    file write `hf' `"}"' _n
    file write `hf' _n
    file write `hf' `"function renderList(rows, S){"' _n
    file write `hf' `"  var k=Math.min(rows.length, 250), s='', i;"' _n
    file write `hf' `"  for(i=0;i<k;i++){"' _n
    file write `hf' `"    var r=rows[i];"' _n
    file write `hf' `"    var shb = (r.sh!=null && r.on>0)"' _n
    file write `hf' `"      ? '<span class='+Q+'strack'+Q+'><span class='+Q+'sbar'+Q+at('style','width:'+Math.round(100*Math.min(r.sh,1))+'%')+'></span></span>'+pct(r.sh)"' _n
    file write `hf' `"      : '';"' _n
    file write `hf' `"    s+='<details class='+Q+'qrow'+Q+'><summary>'+"' _n
    file write `hf' `"       '<span class='+Q+'mono qv'+Q+'>'+esc(r.v)+'</span>'+chip(r.st)+"' _n
    file write `hf' `"       '<span class='+Q+'qsec'+Q+'>'+esc(r.s||'')+'</span>'+"' _n
    file write `hf' `"       '<span class='+Q+'qn'+Q+'>asked '+fc(r.on)+'</span>'+"' _n
    file write `hf' `"       '<span class='+Q+'qn'+Q+(r.vi>0?' style='+Q+'color:#a33;font-weight:700'+Q:'')+'>viol '+fc(r.vi)+'</span>'+"' _n
    file write `hf' `"       '<span class='+Q+'qn'+Q+'>unans '+fc(r.im)+' '+shb+'</span>'+"' _n
    file write `hf' `"       '<span class='+Q+'qn'+Q+(r.bd>0?' style='+Q+'color:#7a5b00;font-weight:700'+Q:'')+'>bad codes '+fc(r.bd)+'</span>'+"' _n
    file write `hf' `"       '</summary><div class='+Q+'qbody'+Q+'>'+"' _n
    file write `hf' `"       (r.q?('<div class='+Q+'qt'+Q+'>&quot;'+esc(r.q)+'&quot;</div>'):'')+"' _n
    file write `hf' `"       (r.t?('<div class='+Q+'qm'+Q+'>Type: '+esc(r.t)+'</div>'):'')+"' _n
    file write `hf' `"       (r.e?('<div class='+Q+'qm'+Q+'>Asked only when: <span class='+Q+'mono'+Q+'>'+esc(r.e)+'</span></div>'):'')+"' _n
    file write `hf' `"       (r.bv?('<div class='+Q+'qm'+Q+'>Out-of-list values (count): <span class='+Q+'mono'+Q+'>'+esc(r.bv)+'</span></div>'):'')+"' _n
    file write `hf' `"       ((r.und>0)?('<div class='+Q+'qm'+Q+'>'+fc(r.und)+' records undetermined (a referenced question was unanswered)'+((r.vu>0)?(' - <b>'+fc(r.vu)+' of them carry an answer anyway</b>, which a clean interview flow cannot produce'):'')+'.</div>'):'')+"' _n
    file write `hf' `"       '</div></details>';"' _n
    file write `hf' `"  }"' _n
    file write `hf' `"  el('list').innerHTML=s || '<p class='+Q+'nodata'+Q+'>No questions match the filters.</p>';"' _n
    file write `hf' `"  el('l_more').textContent = rows.length>k ? ('Showing '+k+' of '+rows.length+' questions - refine the filters.') : '';"' _n
    file write `hf' `"}"' _n
    file write `hf' _n
    file write `hf' `"function fvOptions(){"' _n
    file write `hf' `"  var dim=el('c_fd').value, Q3=String.fromCharCode(34), s='<option value='+Q3+Q3+'>-</option>', i, j;"' _n
    file write `hf' `"  if(dim && D.meta && D.meta.fdims){"' _n
    file write `hf' `"    for(i=0;i<D.meta.fdims.length;i++){"' _n
    file write `hf' `"      if(D.meta.fdims[i].v!==dim) continue;"' _n
    file write `hf' `"      var vv=D.meta.fdims[i].vals;"' _n
    file write `hf' `"      for(j=0;j<vv.length;j++){"' _n
    file write `hf' `"        var lab=(vv[j].l&&vv[j].l!==vv[j].c)?(vv[j].c+' '+vv[j].l):vv[j].c;"' _n
    file write `hf' `"        s+='<option value='+Q3+esc(vv[j].c)+Q3+'>'+esc(lab)+' ('+fc(vv[j].n)+')</option>';"' _n
    file write `hf' `"      }"' _n
    file write `hf' `"    }"' _n
    file write `hf' `"  }"' _n
    file write `hf' `"  el('c_fv').innerHTML=s;"' _n
    file write `hf' `"}"' _n
    file write `hf' `"function renderAll(){"' _n
    file write `hf' `"  var S=settings();"' _n
    file write `hf' `"  var rows0;"' _n
    file write `hf' `"  if(S.fd && S.fv) rows0=C.deriveF(D.rows, S.fd, S.fv);"' _n
    file write `hf' `"  else rows0=C.derive(D.rows, D.meta, S.ist);"' _n
    file write `hf' `"  var rows=C.filt(rows0, S);"' _n
    file write `hf' `"  var K=C.kpis(rows);"' _n
    file write `hf' `"  el('k_shown').textContent=fc(K.n);"' _n
    file write `hf' `"  var rc=(S.fd&&S.fv)?C.recsF(D.meta,S.fd,S.fv):C.recs(D.meta,S.ist);"' _n
    file write `hf' `"  el('k_recs').textContent = rc===null ? '-' : fc(rc);"' _n
    file write `hf' `"  el('k_imiss').textContent=fc(K.im);"' _n
    file write `hf' `"  el('k_viol').textContent=fc(K.vi);"' _n
    file write `hf' `"  el('k_bad').textContent=fc(K.bd);"' _n
    file write `hf' `"  el('k_vund').textContent=fc(K.vu);"' _n
    file write `hf' `"  var hard=(K.vi||0)+(K.bd||0)+(K.vu||0), vtx, vcl;"' _n
    file write `hf' `"  var scope = S.ist==='FIELD' ? 'records with fieldwork done' : (S.ist==='' ? 'ALL records including not-yet-started ones' : 'the selected status');"' _n
    file write `hf' `"  if(hard>0){"' _n
    file write `hf' `"    vtx='Hard problems: '+fc(K.vi)+' answer(s) on disabled questions, '+fc(K.bd)+' out-of-list value(s), '+fc(K.vu)+' undetermined-with-answer, across '+fc(K.n)+' question(s) in view. Item nonresponse: '+fc(K.im)+' unanswered enabled cell(s). Scope: '+scope+'.';"' _n
    file write `hf' `"    vcl='bad';"' _n
    file write `hf' `"  } else {"' _n
    file write `hf' `"    vtx='No hard problems in this view. The workload is item nonresponse: '+fc(K.im)+' unanswered enabled cell(s) across '+fc(K.n)+' question(s). Scope: '+scope+'.';"' _n
    file write `hf' `"    vcl=(K.im>0)?'warn':'ok';"' _n
    file write `hf' `"  }"' _n
    file write `hf' `"  el('v_chk').textContent=vtx;"' _n
    file write `hf' `"  el('v_chk').className='verdict '+vcl;"' _n
    file write `hf' `"  hbars('ch_imiss', C.topBy(rows,'im',10,S.minsh,15), 'im');"' _n
    file write `hf' `"  var tv=C.topBy(rows,'vi',0,0,15);"' _n
    file write `hf' `"  el('sec_viol').style.display = tv.length ? '' : 'none';"' _n
    file write `hf' `"  if(tv.length) hbars('ch_viol', tv, 'vi');"' _n
    file write `hf' `"  var tb=C.topBy(rows,'bd',0,0,15);"' _n
    file write `hf' `"  el('sec_bad').style.display = tb.length ? '' : 'none';"' _n
    file write `hf' `"  if(tb.length) hbars('ch_bad', tb, 'bd');"' _n
    file write `hf' `"  var tu=C.topBy(rows,'vu',0,0,15);"' _n
    file write `hf' `"  el('sec_vund').style.display = tu.length ? '' : 'none';"' _n
    file write `hf' `"  if(tu.length) hbars('ch_vund', tu, 'vu');"' _n
    file write `hf' `"  renderList(C.srt(rows, S.sort), S);"' _n
    file write `hf' `"}"' _n
    file write `hf' _n
    file write `hf' `"function init(){"' _n
    file write `hf' `"  var i;"' _n
    file write `hf' `"  var sts=(D.meta&&D.meta.statuses)?D.meta.statuses:[];"' _n
    file write `hf' `"  if(sts.length){"' _n
    file write `hf' `"    var hasApp=false, o='<option value='+Q+Q+'>All statuses</option>';"' _n
    file write `hf' `"    var hasField=false;"' _n
    file write `hf' `"    for(i=0;i<sts.length;i++){ if(sts[i].c===120||sts[i].c===130) hasApp=true; if(sts[i].c>=65) hasField=true; }"' _n
    file write `hf' `"    if(hasField) o+='<option value='+Q+'FIELD'+Q+'>Fieldwork done (completed + rejected + approved)</option>';"' _n
    file write `hf' `"    if(hasApp) o+='<option value='+Q+'APP'+Q+'>Approved only (Sup + HQ)</option>';"' _n
    file write `hf' `"    for(i=0;i<sts.length;i++) o+='<option value='+Q+i+Q+'>'+esc(sts[i].l||String(sts[i].c))+' ('+fc(sts[i].n)+')</option>';"' _n
    file write `hf' `"    el('c_ist').innerHTML=o;"' _n
    file write `hf' `"    if(hasField) el('c_ist').value='FIELD';"' _n
    file write `hf' `"  } else {"' _n
    file write `hf' `"    el('ctl_ist').style.display='none';"' _n
    file write `hf' `"  }"' _n
    file write `hf' `"  var secs={};"' _n
    file write `hf' `"  for(i=0;i<D.rows.length;i++) if(D.rows[i].s) secs[D.rows[i].s]=1;"' _n
    file write `hf' `"  var names=Object.keys(secs).sort(), s='<option value='+Q+Q+'>All sections</option>';"' _n
    file write `hf' `"  for(i=0;i<names.length;i++) s+='<option>'+esc(names[i])+'</option>';"' _n
    file write `hf' `"  el('c_sec').innerHTML=s;"' _n
    file write `hf' `"  var fds=(D.meta&&D.meta.fdims)?D.meta.fdims:[];"' _n
    file write `hf' `"  if(fds.length){"' _n
    file write `hf' `"    var Q4=String.fromCharCode(34), fo='<option value='+Q4+Q4+'>None</option>';"' _n
    file write `hf' `"    for(i=0;i<fds.length;i++) fo+='<option>'+esc(fds[i].v)+'</option>';"' _n
    file write `hf' `"    el('c_fd').innerHTML=fo;"' _n
    file write `hf' `"    fvOptions();"' _n
    file write `hf' `"  } else {"' _n
    file write `hf' `"    el('ctl_fd').style.display='none';"' _n
    file write `hf' `"    el('ctl_fv').style.display='none';"' _n
    file write `hf' `"  }"' _n
    file write `hf' `"  el('c_fd').addEventListener('change',function(){ fvOptions(); if(el('c_fd').value) el('c_ist').value=''; renderAll(); });"' _n
    file write `hf' `"  el('c_ist').addEventListener('change',function(){ if(el('c_ist').value){ el('c_fd').value=''; fvOptions(); } renderAll(); });"' _n
    file write `hf' `"  var ids=['c_q','c_sec','c_st','c_prob','c_minsh','c_sort','c_fv'];"' _n
    file write `hf' `"  for(i=0;i<ids.length;i++){"' _n
    file write `hf' `"    el(ids[i]).addEventListener('change',renderAll);"' _n
    file write `hf' `"    el(ids[i]).addEventListener('input',renderAll);"' _n
    file write `hf' `"  }"' _n
    file write `hf' `"  renderAll();"' _n
    file write `hf' `"}"' _n
    file write `hf' `"init();"' _n
    file write `hf' `"}"' _n
    file write `hf' _n
    file write `hf' `"</script></body></html>"' _n
    file close `hf'
    local fullh `"`html'"'
    if strpos(`"`html'"',"/")==0 & strpos(`"`html'"',"\")==0 local fullh `"`c(pwd)'/`html'"'
    di as txt "  dashboard written: " as res `"`fullh'"'
    di as txt `"               {browse "`fullh'":Click to open in your browser}"'
    }

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
    return scalar nvund   = `tvund'
    return scalar nimiss  = `timiss'
    return scalar nbadval = `tbad'
    return scalar nevaluated = `k_eval'
    return scalar nnoteval   = `k_noev'
end

* ---- suite: the three QC pages combined into one tabbed, self-contained HTML ----
* Tab 1 Behaviour (interactive paradata report), tab 2 Skip/removal review (supervisor
* review page), tab 3 Data QC (skip logic + option values vs the exported data).
* Each page is embedded in its own sandboxed iframe (srcdoc), so their scripts,
* styles and element ids cannot collide; the outer file remains one offline HTML.
program _suso_para_suite, rclass
    version 14.2
    syntax [if] [, SAVing(string) replace TITle(string) QX(string) DATA(string)  ///
        GAPMins(real 30) FASTsecs(real 2) ALLRoles LITEcap(integer 15000)         ///
        CASCade(integer 3) WINdow(real 60) TOP(integer 15)                         ///
        MISScodes(numlist) STatus(string) FILTERS(string) VARS(string) ]
    _suso_para_need events

    * Resolve suite paths against Stata's working directory before any nested
    * command or Java call. The JVM may use a different process directory.
    local suitepwd = subinstr(`"`c(pwd)'"', "\", "/", .)
    if `"`qx'"'!="" {
        local qx = subinstr(`"`qx'"', "\", "/", .)
        local qxabs 0
        if substr(`"`qx'"',2,1)==":" local qxabs 1
        if substr(`"`qx'"',1,1)=="/" local qxabs 1
        if !`qxabs' {
            if substr(`"`suitepwd'"',-1,1)=="/" local qx `"`suitepwd'`qx'"'
            else local qx `"`suitepwd'/`qx'"'
        }
    }
    if `"`data'"'!="" {
        local data = subinstr(`"`data'"', "\", "/", .)
        local dataabs 0
        if substr(`"`data'"',2,1)==":" local dataabs 1
        if substr(`"`data'"',1,1)=="/" local dataabs 1
        if !`dataabs' {
            if substr(`"`suitepwd'"',-1,1)=="/" local data `"`suitepwd'`data'"'
            else local data `"`suitepwd'/`data'"'
        }
    }
    if `"`saving'"'!="" {
        local saving = subinstr(`"`saving'"', "\", "/", .)
        local saveabs 0
        if substr(`"`saving'"',2,1)==":" local saveabs 1
        if substr(`"`saving'"',1,1)=="/" local saveabs 1
        if !`saveabs' {
            if substr(`"`suitepwd'"',-1,1)=="/" local saving `"`suitepwd'`saving'"'
            else local saving `"`suitepwd'/`saving'"'
        }
    }

    if `"`saving'"'=="" local saving "suso_qc_suite.html"
    if "`replace'"=="" {
        capture confirm new file `"`saving'"'
        if _rc {
            di as err "suso: file already exists. Use -replace-."
            exit 602
        }
    }
    if `"`data'"'!="" & `"`qx'"'=="" {
        di as err "suso paradata suite: the Data QC tab needs the questionnaire — add qx(file.html)."
        exit 198
    }
    if `"`qx'"'!="" {
        capture confirm file `"`qx'"'
        if _rc {
            di as err `"suso paradata suite: questionnaire HTML not found: `qx'"'
            exit 601
        }
    }
    if `"`data'"'!="" {
        capture confirm file `"`data'"'
        if _rc {
            di as err `"suso paradata suite: data file not found: `data'"'
            exit 601
        }
    }
    if `"`title'"'=="" {
        local title "Survey QC Suite"
        if "$SUSO_WS"!="" local title "Survey QC Suite — $SUSO_WS"
    }
    di as txt "suso paradata: building the QC suite ..."
    di as txt "  code build: 1.7.12-RUNKEYMISSFIX"
    tempfile EVX T1 T2 T3
    quietly save `"`EVX'"'

    di as txt "  [1/3] behaviour report"
    capture noisily _suso_para_report , saving(`"`T1'"') replace qx(`"`qx'"')     ///
        data(`"`data'"') filters(`"`filters'"') vars(`"`vars'"')                  ///
        gapmins(`gapmins') fastsecs(`fastsecs') `allroles'                        ///
        cascade(`cascade') window(`window') litecap(`litecap')
    local rc1 = _rc
    if `rc1' {
        quietly use `"`EVX'"', clear
        di as err "suso paradata suite: Behaviour tab failed (rc=`rc1')."
        exit `rc1'
    }
    local nstarted = r(nstarted)
    local ncasc    = r(ncascades)

    di as txt "  [2/3] skip/removal review"
    quietly use `"`EVX'"', clear
    capture noisily _suso_para_skips , cascade(`cascade') window(`window')       ///
        top(`top') qx(`"`qx'"') data(`"`data'"') html(`"`T2'"') ///
        vars(`"`vars'"') replace
    local rc2 = _rc
    if `rc2' {
        quietly use `"`EVX'"', clear
        di as err "suso paradata suite: Skip/removal tab failed (rc=`rc2')."
        exit `rc2'
    }
    local t2p `"`T2'"'
    local note2 ""
    capture confirm file `"`T2'"'
    if _rc {
        local t2p ""
        local note2 "No compact AnswerRemoved runs were detected in the paradata - nothing to review here."
    }

    local t3p ""
    local note3 "Run the suite with data(mainexport.dta) to add this tab: it audits the exported data against the questionnaire skip logic and option lists."
    local nviol .
    if `"`data'"'!="" {
        di as txt "  [3/3] data QC dashboard"
        local xopt ""
        if "`misscodes'"!="" local xopt "`xopt' misscodes(`misscodes')"
        if `"`status'"'!=""  local xopt `"`xopt' status(`status')"'
        if `"`filters'"'!="" local xopt `"`xopt' filters(`filters')"'
        capture noisily _suso_para_check `if' , qx(`"`qx'"') data(`"`data'"')    ///
            html(`"`T3'"') replace top(`top') `xopt'
        local rc3 = _rc
        if `rc3' {
            quietly use `"`EVX'"', clear
            di as err "suso paradata suite: Data QC tab failed (rc=`rc3')."
            exit `rc3'
        }
        local nviol = r(nviol)
        local t3p `"`T3'"'
        local note3 ""
    }
    else di as txt "  [3/3] data QC dashboard skipped (no data() given)"

    _suso_para_hesc `"`title'"'
    local etitle `"`r(out)'"'
    local sub "Generated `c(current_date)' `c(current_time)'"
    if "$SUSO_BASE"!="" local sub "`sub' - $SUSO_BASE"
    local t1p `"`T1'"'
    mata: _suso_suite_write(st_local("saving"), st_local("etitle"), st_local("sub"), ///
        st_local("t1p"), st_local("t2p"), st_local("t3p"),                           ///
        st_local("note2"), st_local("note3"))

    quietly use `"`EVX'"', clear
    local fullp `"`saving'"'
    if strpos(`"`saving'"',"/")==0 & strpos(`"`saving'"',"\")==0 local fullp `"`c(pwd)'/`saving'"'
    di as txt "suso paradata: QC suite written to " as res `"`fullp'"'
    di as txt `"               {browse "`fullp'":Click to open in your browser}"'
    di as txt "  tabs: Behaviour (interactive) | Skip/removal review | Data QC"
    di as txt "  events left in memory, unchanged."
    return local  suite `"`fullp'"'
    return scalar nstarted  = `nstarted'
    return scalar ncascades = `ncasc'
    if `"`data'"'!="" return scalar nviol = `nviol'
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
    di as txt    "     suso paradata skips                      {txt}// historical removal runs + final-state review"
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
    di as res _n "  paradata  " as txt " get  load  timing  flags  skips  report  qx  check  suite"
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
    string scalar s, tail, ch, cursec, v, ti, ty, en, ms, op, omap, rest, pat
    string colvector Cvar, Csec, Cty, Cti, Cen, Cms, Cop, Cov, Comap, chunks, anum, atxt, ovals, olabs
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

    Cvar = Csec = Cty = Cti = Cen = Cms = Cop = Cov = Comap = J(0,1,"")
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
            while (rows(olabs)<60 & ustrregexm(rest, pat)) {
                olabs = olabs \ _suso_qx_clean(ustrregexs(1))
                rest = ustrregexrf(rest, pat, "")
            }
            op = ""
            omap = ""
            for (p=1; p<=min((rows(ovals), rows(olabs), 60)); p++) {
                if (p<=8) op = op + (p>1 ? " | " : "") + ovals[p] + " " + olabs[p]
                omap = omap + (p>1 ? char(29) : "") + ovals[p] + char(30) + olabs[p]
            }
            Cvar = Cvar \ substr(v,1,80)
            Csec = Csec \ substr(cursec,1,200)
            Cty  = Cty  \ ty
            Cti  = Cti  \ ti
            Cen  = Cen  \ en
            Cms  = Cms  \ ms
            Cop  = Cop  \ substr(op,1,800)
            Cov  = Cov  \ substr(invtokens(ovals'), 1, 800)
            Comap = Comap \ omap
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
    (void) st_addvar("strL",   "qx_optmap")
    (void) st_addvar("int",    "qx_nopts")
    st_sstore(., "qx_var", Cvar)
    st_sstore(., "qx_section", Csec)
    st_sstore(., "qx_type", Cty)
    st_sstore(., "qx_text", Cti)
    st_sstore(., "qx_enable", Cen)
    st_sstore(., "qx_valmsg", Cms)
    st_sstore(., "qx_opts", Cop)
    st_sstore(., "qx_optvals", Cov)
    st_sstore(., "qx_optmap", Comap)
    st_store(., "qx_nopts", Cno)
    st_store(., "qx_nval", Cnv)
}

string scalar _suso_qx_code_norm(string scalar s0)
{
    string scalar s
    real scalar x
    s = strtrim(s0)
    if (ustrregexm(s, "^[+-]?[0-9]+([.][0-9]+)?$")) {
        x = strtoreal(s)
        if (x < .) return(strtrim(strofreal(x, "%21.0g")))
    }
    return(s)
}

string scalar _suso_qx_optlabel(string scalar omap, string scalar val)
{
    string colvector pairs, one
    string scalar target
    real scalar i
    if (omap=="" | val=="") return("")
    target = _suso_qx_code_norm(val)
    pairs = _suso_qx_split(omap, char(29))
    for (i=1; i<=rows(pairs); i++) {
        one = _suso_qx_split(pairs[i], char(30))
        if (rows(one)>=2) {
            if (_suso_qx_code_norm(one[1])==target) return(one[2])
        }
    }
    return("")
}

void _suso_qx_apply_labels(string scalar oldv, string scalar newv,
    string scalar mapv, string scalar oldout, string scalar newout)
{
    real scalar i, n
    string colvector ov, nv, mp, ol, nl
    n = st_nobs()
    if (n==0) return
    ov = st_sdata(., oldv)
    nv = st_sdata(., newv)
    mp = st_sdata(., mapv)
    ol = nl = J(n,1,"")
    for (i=1; i<=n; i++) {
        ol[i] = _suso_qx_optlabel(mp[i], ov[i])
        nl[i] = _suso_qx_optlabel(mp[i], nv[i])
    }
    st_sstore(., oldout, ol)
    st_sstore(., newout, nl)
}

string scalar _suso_suite_read(string scalar fn)
{
    real scalar fh, n
    string scalar s
    fh = _fopen(fn, "r")
    if (fh < 0) return("")
    fseek(fh, 0, 1)
    n = ftell(fh)
    fseek(fh, 0, -1)
    s = fread(fh, n)
    fclose(fh)
    return(s)
}

string scalar _suso_suite_esc(string scalar s0)
{
    string scalar s
    s = subinstr(s0, "&", "&amp;")
    s = subinstr(s, char(34), "&quot;")
    return(s)
}

void _suso_suite_pane(real scalar fh, real scalar k, string scalar src, string scalar note)
{
    string scalar disp
    disp = (k==1 ? "block" : "none")
    fwrite(fh, `"<div class="pane" id="p"' + strofreal(k) + `"" style="display:"' + disp + `"">"')
    if (src != "") {
        fwrite(fh, `"<iframe srcdoc=""')
        fwrite(fh, _suso_suite_esc(_suso_suite_read(src)))
        fwrite(fh, `""></iframe>"')
    }
    else fwrite(fh, `"<div class="empty">"' + note + `"</div>"')
    fwrite(fh, "</div>" + char(10))
}

void _suso_suite_write(string scalar fout, string scalar title, string scalar sub,
    string scalar f1, string scalar f2, string scalar f3,
    string scalar note2, string scalar note3)
{
    real scalar fh
    fh = fopen(fout, "w")
    fwrite(fh, `"<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>"' + title + "</title><style>" + char(10))
    fwrite(fh, "html,body{margin:0;height:100%;font-family:Segoe UI,Arial,sans-serif;background:#f4f5f7;color:#1a1a1a}" + char(10))
    fwrite(fh, ".logobar{background:#fff;padding:9px 24px;border-bottom:1px solid #e0e0e0}" + char(10))
    fwrite(fh, ".logobar .wbtxt{font-size:12.5px;letter-spacing:.06em;color:#002244;font-weight:600}.logobar .wbtxt span{color:#8a8a8a;font-weight:400}" + char(10))
    fwrite(fh, ".mast{background:#002244;color:#fff;padding:12px 24px 0}" + char(10))
    fwrite(fh, ".mast h1{margin:0;font-size:19px;font-weight:600}.mast .sub{color:#c9d4e0;font-size:11.5px;margin:3px 0 9px}" + char(10))
    fwrite(fh, ".tabs{display:flex;gap:4px}" + char(10))
    fwrite(fh, ".tb{background:#0a3560;color:#c9d4e0;border:0;border-radius:7px 7px 0 0;padding:8px 18px;font-size:13px;cursor:pointer}" + char(10))
    fwrite(fh, ".tb.on{background:#f4f5f7;color:#002244;font-weight:700}" + char(10))
    fwrite(fh, ".pane iframe{display:block;width:100%;height:calc(100vh - 118px);border:0;background:#f4f5f7}" + char(10))
    fwrite(fh, ".empty{padding:40px;color:#666;font-size:14px;max-width:640px}" + char(10))
    fwrite(fh, "</style></head><body>" + char(10))
    fwrite(fh, `"<div class="logobar"><!-- wbLogo slot: replace content with the base64 banner img -->"' + char(10))
    fwrite(fh, `"<span class="wbtxt">THE WORLD BANK <span>| Development Economics - Policy Indicators</span> &nbsp;-&nbsp; ENTERPRISE SURVEYS <span>- What Businesses Experience</span></span></div>"' + char(10))
    fwrite(fh, `"<div class="mast"><h1>"' + title + "</h1>" + `"<div class="sub">"' + sub + "</div>" + char(10))
    fwrite(fh, `"<div class="tabs"><button class="tb on" id="b1">Behaviour</button><button class="tb" id="b2">Skip/removal review</button><button class="tb" id="b3">Data QC</button></div></div>"' + char(10))
    _suso_suite_pane(fh, 1, f1, "")
    _suso_suite_pane(fh, 2, f2, note2)
    _suso_suite_pane(fh, 3, f3, note3)
    fwrite(fh, "<script>" + char(10))
    fwrite(fh, "function sh(k){var i;for(i=1;i<=3;i++){document.getElementById('p'+i).style.display=(i===k)?'block':'none';document.getElementById('b'+i).className=(i===k)?'tb on':'tb';}}" + char(10))
    fwrite(fh, "document.getElementById('b1').addEventListener('click',function(){sh(1);});" + char(10))
    fwrite(fh, "document.getElementById('b2').addEventListener('click',function(){sh(2);});" + char(10))
    fwrite(fh, "document.getElementById('b3').addEventListener('click',function(){sh(3);});" + char(10))
    fwrite(fh, "</script></body></html>" + char(10))
    fclose(fh)
}

end
