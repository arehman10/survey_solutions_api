{smcl}
{vieweralsosee "[D] import" "help import"}{...}
{viewerjumpto "Quick start" "suso##quickstart"}{...}
{viewerjumpto "Syntax" "suso##syntax"}{...}
{viewerjumpto "Connection setup" "suso##setup"}{...}
{viewerjumpto "Configuration options" "suso##configopts"}{...}
{viewerjumpto "Exports" "suso##export"}{...}
{viewerjumpto "Backup" "suso##backup"}{...}
{viewerjumpto "Common options" "suso##common"}{...}
{viewerjumpto "Pagination" "suso##pagination"}{...}
{viewerjumpto "Paradata commands" "suso##paradata"}{...}
{viewerjumpto "Behaviour report" "suso##report"}{...}
{viewerjumpto "Combined QC suite" "suso##suite"}{...}
{viewerjumpto "Report options" "suso##options"}{...}
{viewerjumpto "Timing and flags" "suso##timing"}{...}
{viewerjumpto "Skips and removals" "suso##skips"}{...}
{viewerjumpto "Final-data checks" "suso##check"}{...}
{viewerjumpto "Questionnaire metadata" "suso##qx"}{...}
{viewerjumpto "API command reference" "suso##subcommands"}{...}
{viewerjumpto "Maps" "suso##maps"}{...}
{viewerjumpto "Server changes and confirmation" "suso##destructive"}{...}
{viewerjumpto "Stored results" "suso##results"}{...}
{viewerjumpto "Examples" "suso##examples"}{...}
{viewerjumpto "Troubleshooting" "suso##troubleshooting"}{...}
{viewerjumpto "Requirements" "suso##requirements"}{...}
{viewerjumpto "Author" "suso##author"}{...}

{marker description}{...}
{title:suso - Survey Solutions from Stata}

{pstd}
Use {cmd:suso} to download Survey Solutions data directly into your Stata
workflow. You can also manage assignments and interviews, back up a workspace,
and analyse paradata. Start below with a basic Stata data download.{p_end}

{pstd}
You will need your server's base URL, workspace short name, API account,
and the questionnaire GUID and version. The first example shows how to
configure these and download your data.{p_end}

{pstd}
{bf:Save your current dataset first.} Commands that load data or create result
tables replace the data in memory. The {cmd:paradata suite} command restores
the loaded events after it creates the reports.{p_end}

{pstd}
{help suso##quickstart:Download data} | {help suso##export:Export options} |
{help suso##paradata:Paradata} | {help suso##subcommands:API commands} |
{help suso##troubleshooting:Troubleshooting}{p_end}

{marker quickstart}{...}
{title:Quick start: download your survey data}

{pstd}
Replace the example server, account, questionnaire and file paths with your
own. Paste the commands into a do-file. The {cmd:///} at the end of a line
continues the command on the next line in a do-file.{p_end}

{dlgtab:1. Connect to your Survey Solutions server}

{pstd}
Use the base server URL and workspace short name supplied for your survey.
The example hostname is a placeholder.{p_end}

{p 8 8 2}{cmd:suso config, server("https://survey.example.invalid") ///}{p_end}
{p 12 12 2}{cmd:workspace("primary") user("API_USER")}{p_end}
{p 8 8 2}{cmd:suso login}{p_end}
{p 8 8 2}{cmd:suso ping}{p_end}

{pstd}
{cmd:login} opens a masked credentials prompt. {cmd:ping} checks that Stata
can connect. Settings apply to the current Stata session.{p_end}

{dlgtab:2. Choose the questionnaire}

{pstd}
List the questionnaires and identify the GUID and version you want.
{cmd:all} retrieves every page. This command replaces the dataset in memory,
so save any current work first.{p_end}

{p 8 8 2}{cmd:suso questionnaire list, all}{p_end}
{p 8 8 2}{cmd:browse}{p_end}

{pstd}
Set those values as your session defaults. The values below are examples:{p_end}

{p 8 8 2}{cmd:suso config, ///}{p_end}
{p 12 12 2}{cmd:guid("76732117-1b19-4c82-bd39-1e34a781a2e9") qver(11)}{p_end}

{dlgtab:3. Download and extract Stata data}

{pstd}
Choose an existing folder for your ZIP. This command starts the export,
waits for it to finish, downloads the ZIP, and extracts it:{p_end}

{p 8 8 2}{cmd:suso export get, type(STATA) ///}{p_end}
{p 12 12 2}{cmd:saving("C:/survey/data.zip") ///}{p_end}
{p 12 12 2}{cmd:unzipto("C:/survey/export") replace}{p_end}
{p 8 8 2}{cmd:return list}{p_end}

{pstd}
The default includes all interview statuses. Add
{cmd:istatus(ApprovedBySupervisor)} if you want only that status.
For an encrypted export, add {opt unzipw("archive_password")}.
See {help suso##export:Exports} for other formats and download options.{p_end}

{dlgtab:4. Open the exported dataset}

{pstd}
The files are now in {cmd:C:/survey/export}. Extraction does not load them
automatically. Find your main {cmd:.dta} file in that folder and open it;
replace {cmd:main.dta} below with its actual filename:{p_end}

{p 8 8 2}{cmd:use "C:/survey/export/main.dta", clear}{p_end}

{pstd}
Keep roster datasets as separate files until you are ready to link them to
the main data. For event timing and behaviour reports, continue to
{help suso##paradata:Paradata analysis} later in this help file.{p_end}

{marker syntax}{...}
{title:Syntax}

{p 8 8 2}
{cmd:suso} {it:command_group} {it:action} [{cmd:,} {it:options}]{p_end}

{pstd}
For example, {cmd:suso interview list, status(Completed) all} uses the
{cmd:interview} group and the {cmd:list} action. Put options after a comma.
Square brackets in syntax descriptions mean optional input; do not type them.
Quote file paths and text that contain spaces.{p_end}

{pstd}
The API command reference lists options beside each action. For example,
{cmd:get} with {opt id()} under {cmd:assignment} means
{cmd:suso assignment get, id(123)}. Use full option names in your do-files;
underlined prefixes in option descriptions show permitted abbreviations.{p_end}

{pstd}
Utilities do not take a separate action:{p_end}

{phang}{cmd:suso doctor, strict}{break}
Check the Stata/Java environment and package compatibility.{p_end}

{phang}{cmd:suso config, show}{break}
Show session settings with the password masked.{p_end}

{phang}{cmd:suso config, clear}{break}
Clear session settings.{p_end}

{phang}{cmd:suso examples}{break}
Print command recipes. Use this help file for the complete workflows.{p_end}

{phang}{cmd:suso endpoints}{break}
Print the available API command groups and actions.{p_end}

{marker setup}{...}
{title:Connection setup}

{pstd}
Configure the server and workspace once per Stata session. Use a dedicated
Survey Solutions API account with the permissions needed for your work.
Local paradata analysis does not require this step.{p_end}

{p 8 8 2}{cmd:suso config, server("https://survey.example.invalid") ///}{p_end}
{p 12 12 2}{cmd:workspace("primary") user("API_USER")}{p_end}
{p 8 8 2}{cmd:suso login}{p_end}
{p 8 8 2}{cmd:suso ping}{p_end}

{pstd}
If credentials are missing, the first server command prompts for them.
In batch mode, supply credentials beforehand with {opt user()} and
{opt password()}, or the supported {cmd:SUSO_PASSWORD} environment variable.
Bearer authentication uses {opt auth(bearer)} and {opt token()}.
Settings are stored only for the current Stata session.{p_end}

{pstd}
Set a default questionnaire after obtaining its GUID and version from
{cmd:suso questionnaire list}. Substitute your questionnaire's values:{p_end}

{p 8 8 2}{cmd:suso config, ///}{p_end}
{p 12 12 2}{cmd:guid("76732117-1b19-4c82-bd39-1e34a781a2e9") qver(11)}{p_end}

{pstd}
Later commands can omit {opt guid()} and {opt qver()} when these defaults
are set. File paths are relative to Stata's working directory unless you
supply a full path; use {cmd:pwd} to see that directory.{p_end}

{marker configopts}{...}
{title:Configuration options}

{pstd}
For {cmd:suso config}:{p_end}

{phang}
{opt server(url)}{break}
base server URL, e.g. {cmd:https://demo.mysurvey.solutions}{p_end}

{phang}
{opt w:orkspace(name)}{break}
workspace short name (path segment), e.g. {cmd:primary}{p_end}

{phang}
{opt u:ser(name)}{break}
API user name{p_end}

{phang}
{opt p:assword(pw)}{break}
API user password{p_end}

{phang}
{opt token(t)}{break}
use a bearer token instead of user/password{p_end}

{phang}
{opt auth(type)}{break}
authentication scheme: {cmd:basic} (default) or {cmd:bearer}{p_end}

{phang}
{opt jar(path)}{break}
full path to {cmd:suso.jar} (only if not on the adopath){p_end}

{phang}
{opt guid(id)}{break}
default questionnaire GUID for later commands{p_end}

{phang}
{opt qver(#)}{break}
default questionnaire version{p_end}

{phang}
{opt exportpw(string)}{break}
archive password when the server encrypts exports (Export Encryption); used automatically by {cmd:export get}/{cmd:download} and {cmd:paradata get}/{cmd:load} when no {opt unzipw()} is given{p_end}

{phang}
{opt proxyh:ost(h)}{break}
proxy host (corporate networks){p_end}

{phang}
{opt proxyport(#)}{break}
proxy port{p_end}

{phang}
{opt proxyuser(u)}{break}
proxy user{p_end}

{phang}
{opt proxypass(p)}{break}
proxy password{p_end}

{phang}
{opt insecure}{break}
skip TLS certificate-chain verification for non-download requests only; file downloads require verified TLS{p_end}

{phang}
{opt noinsecure}{break}
re-enable TLS verification{p_end}

{phang}
{opt connt:imeout(ms)}{break}
connection timeout in milliseconds (default 30000){p_end}

{phang}
{opt readt:imeout(ms)}{break}
deadline for receiving the complete response, including its body, in milliseconds per request/redirect hop (default 300000); timed-out downloads do not replace an existing destination file{p_end}

{phang}
{opt max:rows(#)}{break}
safety cap on rows fetched by one paginated API {cmd:list, all} call (default 100000); it does not limit exports or paradata{p_end}

{phang}
{opt audit:file(path)}{break}
destination for selected destructive-action records; read-only/paradata commands do not create it{p_end}

{phang}
{opt show}{break}
display the current configuration (password masked){p_end}

{phang}
{opt clear}{break}
clear all session configuration{p_end}

{marker export}{...}
{title:Exports}

{pstd}
{cmd:export get} starts a job, waits for it to finish, and downloads the
archive. Set {opt guid()} and {opt qver()} first, or pass them on the command.
For a Stata export:{p_end}

{p 8 8 2}{cmd:suso export get, type(STATA) ///}{p_end}
{p 12 12 2}{cmd:saving("C:/survey/data.zip") unzip replace}{p_end}

{pstd}
Supported types are {cmd:STATA}, {cmd:SPSS}, {cmd:Tabular}, {cmd:Binary},
{cmd:DDI}, and {cmd:Paradata}. Use {opt istatus()} to choose interview status,
{opt from()} and {opt to()} to bound export dates, {opt pollsecs()} for the
polling interval in seconds, and {opt jobtimeout()} for the preparation budget
in seconds. {cmd:export get} defaults to 10-second polling and a 3,600-second
preparation budget.{p_end}

{dlgtab:Extract an archive}

{phang}{opt unzip}{break}
Extract after downloading. The default folder is named after the archive.{p_end}

{phang}{opt unzipto(directory)}{break}
Extract to this exact directory, including when it already exists.
This option also requests extraction.{p_end}

{phang}{opt unzipw(password)}{break}
Supply the archive password and request extraction. Alternatively set
{opt exportpw()} once with {cmd:suso config}.{p_end}

{marker zip_password}{...}
{pmore}
Stata expands macros before {cmd:suso} receives the password. For the literal
password {cmd:qa$QA_LITERAL}, enter {cmd:unzipw("qa\$QA_LITERAL")}.
The same rule applies to {cmd:suso config, exportpw("qa\$QA_LITERAL")}.
Quotes alone do not prevent macro expansion.{p_end}

{pmore}
Prefix a literal opening backtick with a backslash too: for the password
{cmd:qa`QA_LITERAL'pw}, enter {cmd:unzipw("qa\`QA_LITERAL'pw")}.
Keep a literal backslash-asterisk sequence unchanged: the password
{cmd:qa\*pw} is entered as {cmd:unzipw("qa\*pw")}.{p_end}

{pstd}
To extract a ZIP already on disk, without contacting the server:{p_end}

{p 8 8 2}{cmd:suso export extract, file("C:/survey/data.zip") ///}{p_end}
{p 12 12 2}{cmd:unzipto("C:/survey/export")}{p_end}

{pstd}
Extraction does not load the exported datasets into Stata. Use {cmd:use} to
open the appropriate {cmd:.dta} file. The ZIP remains on disk.{p_end}

{dlgtab:Manage the export steps separately}

{pstd}
Store the job ID immediately, before another command changes {cmd:r()}:{p_end}

{p 8 8 2}{cmd:suso export start, type(STATA)}{p_end}
{p 8 8 2}{cmd:local jobid "`r(jobid)'"}{p_end}
{p 8 8 2}{cmd:suso export status, id(`jobid')}{p_end}

{pstd}
Repeat the status command until the job reports {cmd:Completed} and
{cmd:hasexportfile} is true. Completed exports with no matching data have no
archive to download. When a file is available, run:{p_end}

{p 8 8 2}{cmd:suso export download, id(`jobid') ///}{p_end}
{p 12 12 2}{cmd:saving("C:/survey/data.zip") replace unzip}{p_end}

{pstd}
Preparation messages distinguish queued, preparing, and ready states. The
server percentage may restart between stages; it is not download progress.
If downloading fails, retain the job ID and retry {cmd:export download}
instead of creating a new job. A just-completed archive may need a short wait
before its download endpoint is ready.{p_end}

{dlgtab:Existing files and recovery}

{pstd}
Downloads require verified HTTPS. A successful {opt replace} download keeps
an independent copy of the previous file at {cmd:r(backup)}. A failed transfer
does not replace an existing destination file.{p_end}

{pstd}
Extraction verifies archive entries before installing them. Unrelated files
remain in the target folder. Replaced files are backed up under
{cmd:.suso-backups} in that folder; {cmd:r(unzip_backup)} identifies the backup.
{cmd:r(unzipdir)} gives the actual extraction directory and {cmd:r(manifest)}
identifies the file/hash manifest. An interrupted extraction can leave recovery
material that must be resolved before another extraction; retain it when
investigating an error.{p_end}

{marker backup}{...}
{title:Backup}

{phang}
{cmd:suso backup ,} {opt dir(folder)} [{opt types(STATA Paradata ...)} {opt istatus(All)} {opt nometa}
{opt pollsecs(10)} {opt jobtimeout(3600)} {opt noe:xports} {opt noq:uestionnaires} {opt now:orkspace}]{p_end}

{pmore}
Archives a whole workspace into {it:folder} using the existing verbs: a questionnaire
list ({cmd:questionnaires_list.dta}) plus one JSON document per version; one export zip
per questionnaire-version per {opt types()} entry (start {it:->} poll {it:->} download, with
empty jobs skipped and per-job failures tolerated); and {cmd:assignments.dta} +
{cmd:supervisors.dta}. Returns {cmd:r(ok)}, {cmd:r(skipped)}, {cmd:r(failed)}. Your current
data is preserved/restored. Each run uses a fresh child directory inside the
requested {opt dir()}. The requested root is returned in {cmd:r(root)} and
the run's child directory in {cmd:r(dir)}. No sibling outside the root is used.
Example: {cmd:suso backup , dir("C:/archive/mysurvey") types(STATA Paradata)}.{p_end}

{marker common}{...}
{title:Common options}

{phang}
{opt guid(id)} and {opt qver(#)} identify a questionnaire. They may be omitted
when a default has been set with {cmd:suso config , guid() qver()}.{p_end}

{phang}
{opt all} on a paginated API {cmd:list} command that accepts it fetches {bf:every} matching record by paging
through the server; without {opt all} only the first page is returned.
See {help suso##pagination:Pagination}.{p_end}

{phang}
{opt saving(filename)} (with {opt replace}) writes a downloaded artifact
(export archive, interview/questionnaire PDF, statistics file). Relative paths
resolve against the Stata working directory ({helpb pwd}).{p_end}

{phang}
{opt confirm} is required to proceed with most destructive verbs;
see {help suso##destructive:Destructive operations}.{p_end}

{phang}
{opt verbose} prints the HTTP method, URL and status for the request {hline 1}
the first thing to add when a call behaves unexpectedly.{p_end}

{marker pagination}{...}
{title:Pagination}

{pstd}
Paginated API lists that accept {opt all} fetch the {bf:first page} by
default. {cmd:workspace list} does not use {opt all}; {cmd:maps list} pages
automatically. Add {opt all} to
page through and return every matching record. {cmd:suso} learns the server's
effective page size automatically (Survey Solutions caps some lists, e.g.
interviews at 40 per page) and keeps requesting pages until the reported total
is reached, so {opt all} is reliable even when the server returns fewer rows than
requested. The {opt maxrows()} configuration value is a safety ceiling on the
total number of rows a single {opt all} call will load.{p_end}

{marker paradata}{...}
{title:Paradata: choose your workflow}

{pstd}
Paradata records what happened during an interview. Use the complete event
export for timing, removal histories and behaviour review. Keep intervening
events; use {opt vars()} to focus questions. Flags are review prompts, not proof
of misconduct.{p_end}

{phang}
{bf:Build an HTML report:} {help suso##report:report} creates the Behaviour page;
{help suso##suite:suite} combines Behaviour, Skips and optional Data QC.{p_end}

{phang}
{bf:Work with Stata tables:} {help suso##timing:timing and flags} summarize
activity; {help suso##skips:skips} inventories answer removals.{p_end}

{phang}
{bf:Check final answers:} {help suso##check:check} compares the main data export
with the questionnaire. It does not require loaded paradata.{p_end}

{pstd}
Save your current work before loading data. After success, {cmd:get}/{cmd:load}
leave event rows; {cmd:timing}, {cmd:flags}, {cmd:skips}, {cmd:report}, {cmd:qx}
and {cmd:check} leave their result tables. {cmd:suite} restores the loaded events.
Reload events before another event-based command.{p_end}

{dlgtab:Load a local file}

{p 8 12 2}
{cmd:suso paradata load, file("C:/survey/paradata.tab")}{p_end}
{p 8 12 2}
{cmd:save "C:/survey/events.dta", replace}{p_end}

{pstd}
{opt file()} accepts a ZIP or tab-delimited {cmd:.tab}, {cmd:.tsv} or {cmd:.txt}
file. Alternatively, use {opt dir("folder")} for an extracted folder. The folder
must contain {cmd:paradata.tab} or exactly one {cmd:.tab} file. To reuse prepared
events saved as a Stata dataset, use {cmd:use "C:/survey/events.dta", clear}.
No server configuration or API credentials are needed for local analysis.{p_end}

{pstd}
For a ZIP, {opt dir()} chooses the extraction folder; otherwise extraction uses
a folder beside the ZIP with its base name. {opt unzipw("password")} supplies
the archive password. {opt pwd()} is a synonym; explicit {opt unzipw()} takes
precedence, followed by {opt pwd()}, then configured {opt exportpw()}.
Import or schema errors preserve the previously loaded dataset.{p_end}

{dlgtab:Download and load from the server}

{p 8 12 2}
{cmd:suso paradata get} [{cmd:,} {opt saving(path.zip)} {opt dir(folder)}
{opt guid(id)} {opt qver(#)} {opt istatus(status)} {opt from(date)} {opt to(date)}
{opt pollsecs(#)} {opt jobtimeout(#)} {opt unzipw(password)} {opt pwd(password)}
{opt reduced} {opt replace} {opt verbose}]{p_end}

{pstd}
Configure the connection and questionnaire first. {cmd:get} requests a Paradata
export, waits, downloads, extracts and loads it. Defaults are all interview
statuses, polling every 10 seconds, a 3600-second job timeout, and an automatically
named ZIP in the working directory. Dates use {cmd:YYYY-MM-DD}. The ZIP remains
on disk; after extraction failure, retry with {cmd:load}. Prefer full exports:
{opt reduced} omits event context used in QC.{p_end}

{marker report}{...}
{title:Behaviour report}

{p 8 12 2}
{cmd:suso paradata report} [{cmd:,} {opt saving(file.html)} {opt replace}
{opt title(text)} {opt qx(file.html)} {opt data(main.dta)}
{opt startvar(name)} {opt endvar(name)} {opt filters(varlist)} {opt vars(patterns)}
{opt gapmins(#)} {opt fastsecs(#)} {opt allroles} {opt cascade(#)} {opt window(#)}
{opt litecap(#)} {opt misscodes(numlist)} {opt hqurl(url)}]{p_end}

{pstd}
Run directly after loading events. The report contains a review queue, actor and
question timing, removal evidence, filters and CSV exports. It opens offline in
a browser. The default filename is {cmd:suso_paradata_qc.html}; the default title
is {cmd:Paradata QC report}, with the configured workspace appended when present.
After success, Stata holds one row per interview with combined QC results.
Use {cmd:save} if you want to keep that table.{p_end}

{p 8 12 2}
{cmd:suso paradata load, file("C:/survey/paradata.tab")}{p_end}
{p 8 12 2}
{cmd:suso paradata report, qx("C:/survey/questionnaire.html") ///}{break}
{cmd:    saving("C:/survey/behaviour.html") replace}{p_end}

{dlgtab:Question wording and interview clocks}

{pstd}
{opt qx()} must name the matching Survey Solutions questionnaire preview HTML.
It supplies question wording on hover or keyboard focus, question order, sections
and questionnaire relationships. A variable absent from that questionnaire has
an explicit unavailable-label message.{p_end}

{pstd}
Use {opt startvar(name)} and {opt endvar(name)} to select your questionnaire's
interview start/end fields. Supply both together, as distinct single identifiers
with the exact case used in the events. Each permits letters, digits and
underscores, begins with a letter or underscore, and has at most 80 characters.
The pair overrides automatic detection and works without {opt qx()}.
These are questionnaire variable names, not columns to create in Stata.{p_end}

{p 8 12 2}
{cmd:suso paradata load, file("C:/survey/paradata.tab")}{p_end}
{p 8 12 2}
{cmd:suso paradata report, qx("C:/survey/questionnaire.html") ///}{break}
{cmd:    startvar(a14hmindmy) endvar(a15hmindmy) ///}{break}
{cmd:    saving("C:/survey/behaviour.html") replace}{p_end}

{pstd}
Replace those two example names with your own fields. Without an explicit pair,
the command uses clear questionnaire boundary metadata and conservative name
matching. Missing captures and incompatible time bases remain unknown.{p_end}

{dlgtab:Read and use the report}

{pstd}
Start with {bf:What needs attention}, then open a row's evidence. The queue uses
{bf:Investigate}, {bf:Verify} and {bf:Watch} priorities. It considers individual
contributors, workflow and multiple risk domains. Its eight behaviour signals
include speed, fast streaks, short duration, night work, churn, duration outliers,
peer speed and overlap. It is not a ranking of the six Stata flags alone.{p_end}

{pstd}
The review list shows {bf:Date} immediately after the reason for review and opens
with the most recent interview starts first. Click the date heading to reverse
the order. The date comes from the first dated interviewing activity in event
order, using its local date when available and UTC otherwise. Undated interviews
stay last in either direction; later corrections do not change the start date.{p_end}

{pstd}
With {opt qx()}, {bf:Question-order deviations} identifies earlier-position
questions first answered after a later-position question. It considers first-pass
field answers and counts each base question once across roster rows. Later edits,
reanswers and work after first completion are excluded. Missing or ambiguous
positions and uncertain event sequences limit assessment; absent mapping is not
a clean pass. Skips alone are not deviations, and legitimate branching can
produce a signal, so these are {bf:Watch} items for review.{p_end}

{pstd}
Use the review check selector for question order, short interviews, either check
or both checks. Short means first-pass active minutes strictly below
{bf:Min first-pass active min}; equality is not short and zero disables the
short check. Missing or unreliable timing is not classified as short. Changing
the threshold refreshes the list and its CSV export.{p_end}

{pstd}
Separate {bf:Investigate} evidence identifies pauses during interviewing,
comparable end-before-start values, and clock revisions of at least 60 seconds
when the immediately preceding valid capture was by the same known actor.
Normal terminal pauses are excluded, but a pause lasting at least 60 seconds
before completion is still reviewed. These checks do not establish intent.{p_end}

{pstd}
Browser filters and thresholds change the HTML view; they do not change Stata's
QC table. Hover or focus variable names for wording. Export the displayed review
queue to CSV. The raw-history explorer requires selecting a matching local
{cmd:paradata.tab}; that file is read locally and is not uploaded. Raw events are
not embedded in the report, so a recipient needs their own authorized copy.
Open interview/assignment links use the browser's Headquarters session.{p_end}

{pstd}
Event history has {bf:Top} and {bf:Back to review} controls. Returning to the review
list preserves its filters and selected interview. {bf:No Responsible Actor} is
unchecked when event history opens; select it to include those events.{p_end}

{marker suite}{...}
{title:Combined QC suite}

{p 8 12 2}
{cmd:suso paradata suite} [{cmd:if} {it:expression}] [{cmd:,}
{opt saving(file.html)} {opt replace} {opt title(text)} {opt qx(file.html)}
{opt data(main.dta)} {opt startvar(name)} {opt endvar(name)}
{opt gapmins(#)} {opt fastsecs(#)} {opt allroles} {opt cascade(#)} {opt window(#)}
{opt litecap(#)} {opt top(#)} {opt misscodes(numlist)} {opt status(status)}
{opt filters(varlist)} {opt vars(patterns)} {opt hqurl(url)}]{p_end}

{pstd}
The suite contains Behaviour and Skips tabs. Add both {opt qx()} and {opt data()}
for Data QC; neither is required for the basic suite. {opt data()} requires
{opt qx()}. The default output is {cmd:suso_qc_suite.html}; the default title is
{cmd:Survey QC Suite}, with the workspace appended when present. Events are
restored in memory after the command.{p_end}

{p 8 12 2}
{cmd:suso paradata load, file("C:/survey/paradata.tab")}{p_end}
{p 8 12 2}
{cmd:suso paradata suite, qx("C:/survey/questionnaire.html") ///}{break}
{cmd:    data("C:/survey/main.dta") ///}{break}
{cmd:    saving("C:/survey/qc_suite.html") replace}{p_end}

{pstd}
Suite {cmd:if} and {opt status()} restrict {bf:Data QC only}. They do not subset
Behaviour events or the final evidence used for removal review. {cmd:report}
does not accept {cmd:if} or {opt status()}. For a narrower Behaviour population,
load complete histories for the intended interviews.{p_end}

{marker options}{...}
{title:Options shared by paradata workflows}

{phang}
{opt data(main.dta)} supplies final answers, current status, assignment IDs and
filter values. Use the main Survey Solutions Stata export containing
{cmd:interview__id}. With {opt data()}, status comes from {cmd:interview__status};
otherwise Behaviour uses the last recognized workflow event.{p_end}

{phang}
{opt vars("patterns")} selects question names or space-separated wildcards,
for example {cmd:vars("employment* sales*")}. It focuses question/removal detail,
while retaining full interview lifecycle and risk calculations. It is not an
interview filter. On {cmd:timing}, it affects question timing only.{p_end}

{phang}
{opt filters(varlist)} adds live controls from numeric {opt data()} fields, with
at most 20 nonmissing values per field and 40 overall. Unsupported fields are
skipped with messages. Behaviour actor/status controls synchronize with Skips;
variable/value controls do not automatically restrict Skips. Data QC browser
status and variable breakdowns are alternatives, not joint filters.{p_end}

{phang}
{opt gapmins(#)} is the positive finite timing-gap limit in minutes; default 30.
{opt fastsecs(#)} is the fast-answer cutoff in seconds; default 2, allowed 0.5
through 10 in steps of 0.5. {opt allroles} broadens interviewer-role analysis;
it does not make preload or unreliable timing valid.{p_end}

{phang}
{opt cascade(#)} is the minimum compact-removal count; default 3, integer at
least 1. {opt window(#)} is its positive finite time window in seconds; default
60. These settings classify compact histories without dropping other histories.
{opt top(#)} limits printed lists, not HTML case inventories; default 15 for
{cmd:flags}, {cmd:skips} and {cmd:suite}, and 10 for {cmd:check}. It must be a
nonnegative integer.{p_end}

{phang}
{opt litecap(#)} controls report/suite size; default 15000, nonnegative integer.
When qualifying field-answer interviews exceed it, detailed hour/gap vectors are
omitted and speed/share and night-window controls use build-time settings.
{cmd:litecap(0)} requests this mode for any nonempty qualifying population.
Fast streaks retain their build-time cutoff in either mode.{p_end}

{phang}
{opt misscodes(numlist)} is accepted by {cmd:report}, {cmd:suite}, {cmd:skips}
and {cmd:check}. It replaces the default numeric missing list {cmd:-999999999};
include that value yourself if still needed. Stata missing values remain missing.
Numeric codes do not convert text such as {cmd:"-9"}; the string sentinel
{cmd:##N/A##} is treated as missing. Source data files are not changed.{p_end}

{phang}
{opt hqurl("https://server/workspace")} overrides the configured workspace root
for browser interview/assignment links. Use a plain HTTP(S) workspace URL.
Credentials are not embedded. Normal report controls work offline; following
a Headquarters link contacts that server.{p_end}

{phang}
{opt saving()}, {opt html()} and {opt messages()} name outputs. Paths resolve
against Stata's working directory; quote paths containing spaces. Create the
destination folder first. Add {opt replace} to overwrite an existing output.
Reports contain interview-level information; share them as survey data.{p_end}

{marker timing}{...}
{title:Timing tables and six Stata flags}

{p 8 12 2}
{cmd:suso paradata timing} [{cmd:,} {opt by(level)} {opt gapmins(#)}
{opt fastsecs(#)} {opt allroles} {opt vars(patterns)}]{p_end}

{pstd}
{opt by(interview)} is the default. {opt by(question)} summarizes first-pass
question timing; {opt by(interviewer)} summarizes actors. Each replaces events
with its summary table. Active time estimates eligible within-session intervals;
it excludes pauses, workflow/session boundaries, actor handoffs and long gaps.
First-pass timing ends at first interviewer completion. Later work remains in
total/workflow metrics. Invalid timing remains unavailable.{p_end}

{p 8 12 2}
{cmd:suso paradata flags} [{cmd:,} {opt gapmins(#)} {opt fastsecs(#)} {opt allroles}
{opt minactive(#)} {opt burstrun(#)} {opt nightshare(#)} {opt churn(#)}
{opt zcut(#)} {opt top(#)} {opt saving(file.dta)} {opt replace}]{p_end}

{pstd}
Input may be events or a compatible interview timing/flags table. Output is
one row per interview with six {cmd:f_*} indicators and {cmd:n_flags}:
{cmd:f_speed} for median answer gaps below {opt fastsecs(2)};
{cmd:f_burst} for fast runs of at least {opt burstrun(8)};
{cmd:f_short} for completed first-pass active time below {opt minactive(5)} minutes;
{cmd:f_night} for night share above {opt nightshare(0.25)};
{cmd:f_churn} for removals/answers above {opt churn(0.20)}; and
{cmd:f_outlier} for an absolute robust duration score above {opt zcut(3.5)}.
Rate/streak flags require at least 10 supporting answers; duration outliers need
at least 10 eligible positive durations and nonzero median absolute deviation.
Mode and timing safeguards also apply. {opt minactive()} and {opt churn()} must
be nonnegative, {opt burstrun()} a positive integer, {opt zcut()} positive, and
{opt nightshare()} between 0 and 1. Churn may exceed 1.{p_end}

{pstd}
On existing interview tables, omitted timing options retain the table's settings.
Flag thresholds can be changed directly. Reload events to change {opt gapmins()},
{opt fastsecs()} or role scope. Question/interviewer summaries cannot be used as
input to {cmd:flags}. The compatibility option {opt burstshare()} accepts -1 or
0 to 1; fast runs are defined by {opt burstrun()}, not that share.{p_end}

{marker skips}{...}
{title:Answer-removal review}

{p 8 12 2}
{cmd:suso paradata skips} [{cmd:,} {opt qx(file.html)} {opt data(main.dta)}
{opt cascade(#)} {opt window(#)} {opt top(#)} {opt vars(patterns)} {opt allroles}
{opt misscodes(numlist)} {opt full} {opt saving(file.dta)}
{opt messages(file.txt)} {opt html(file.html)} {opt hqurl(url)} {opt replace}]{p_end}

{pstd}
Requires events and leaves an interview-level removal table. Every consecutive
same-actor {cmd:AnswerRemoved} run is retained, including singletons and unknown
timing. Compact histories meet the count/window thresholds and have a nearby
question-named answer. A past removal does not establish that today's value is
missing. {opt qx()} supplies wording and logic; {opt data()} supplies final-state
evidence. {opt full} prints detailed cases up to {opt top()} and includes those
details in the text output.{p_end}
{p 8 12 2}
{cmd:suso paradata load, file("C:/survey/paradata.tab")}{p_end}
{p 8 12 2}
{cmd:suso paradata skips, qx("C:/survey/questionnaire.html") ///}{break}
{cmd:    data("C:/survey/main.dta") ///}{break}
{cmd:    html("C:/survey/removals.html") replace}{p_end}

{marker check}{...}
{title:Check the final data}

{p 8 12 2}
{cmd:suso paradata check} [{cmd:if} {it:expression}]{cmd:,}
{opt qx(file.html)} {opt data(main.dta)} [{opt status(status)}
{opt misscodes(numlist)} {opt filters(varlist)} {opt top(#)}
{opt saving(file.dta)} {opt html(file.html)} {opt replace}]{p_end}

{pstd}
Both input files are required; loaded events are unnecessary. {cmd:if} is
evaluated against {opt data()}. {opt status(approved)} selects Supervisor- and
Headquarters-approved records (120 and 130); a numeric status list is also
accepted. No command-level status restriction is applied by default.{p_end}

{pstd}
Checks cover enabled-but-missing answers, answered disabled questions,
undetermined enablement and invalid single-select codes. Unsupported logic
remains unknown. This does not execute every Survey Solutions validation rule.
The result in memory is one row per codebook question. {opt saving()} saves it;
{opt html()} writes the dashboard. No HTML is written without {opt html()}.
The HTML's initial status view can be narrower than the command population;
browser selections do not change the Stata audit table.{p_end}
{p 8 12 2}
{cmd:suso paradata check, qx("C:/survey/questionnaire.html") ///}{break}
{cmd:    data("C:/survey/main.dta") status(approved) ///}{break}
{cmd:    html("C:/survey/data_qc.html") replace}{p_end}

{marker qx}{...}
{title:Inspect questionnaire metadata}

{p 8 12 2}
{cmd:suso paradata qx, file(}{it:questionnaire.html}{cmd:)}
[{opt saving(file.dta)} {opt replace}]{p_end}

{pstd}
Reads a Survey Solutions questionnaire preview HTML locally through the Java
backend. The metadata table replaces memory and includes names, wording,
sections, types, inherited conditions and option values. {cmd:r(nq)} is the
parsed row count. A separate {cmd:qx} call is unnecessary before other commands:
pass their {opt qx()} option and they load the metadata internally.{p_end}

{marker subcommands}{...}
{title:API command reference}

{pstd}
Choose a group below, then use its action with the shown options after a comma.
Required identifiers are shown beside the action; optional filters follow in
parentheses. Server permissions determine which actions you can perform.{p_end}

{pstd}
{help suso##assignment:Assignments} | {help suso##interview:Interviews} |
{help suso##questionnaire:Questionnaires} | {help suso##export:Exports} |
{help suso##maps:Maps}{p_end}

{marker assignment}{...}
{dlgtab:Assignments}

{pstd}{cmd:suso assignment} {it:action}{p_end}

{phang}
{cmd:list}{break}
assignments; filters {opt searchby()} {opt resp:onsible()} {opt sup:ervisor()} {opt order()} {opt archived} {opt guid()} {opt qver()} {opt all}{p_end}

{phang}
{cmd:get} {opt id()}{break}
one assignment{p_end}

{phang}
{cmd:history} {opt id()}{break}
assignment history ({opt start()} {opt length()}){p_end}

{phang}
{cmd:quantitysettings} {opt id()}{break}
quantity settings for an assignment{p_end}

{phang}
{cmd:create} {opt resp:onsible()}{break}
create an assignment ({opt quant:ity()} {opt email()} {opt pass:word()} {opt webmode} {opt audio} {opt comm:ents()} {opt target:area()} {opt ident:ifying()}){p_end}

{phang}
{cmd:assign} {opt id()} {opt resp:onsible()}{break}
reassign an assignment{p_end}

{phang}
{cmd:quantity} {opt id()} {opt n()}{break}
change interview quantity{p_end}

{phang}
{cmd:close} {opt id()}{break}
close an assignment{p_end}

{phang}
{cmd:archive} {opt id()} {opt confirm}{break}
Archive an assignment{p_end}

{phang}
{cmd:unarchive} {opt id()}{break}
unarchive an assignment{p_end}

{phang}
{cmd:audio} {opt id()} [{opt on} {opt off}]{break}
get or set audio recording{p_end}

{phang}
{cmd:targetarea} {opt id()} {opt area()}{break}
set the target area{p_end}


{marker interview}{...}
{dlgtab:Interviews}

{pstd}{cmd:suso interview} {it:action}{p_end}

{phang}
{cmd:list}{break}
interviews; filters {opt status()} {opt guid()} {opt qver()} {opt id()} {opt all}{p_end}

{phang}
{cmd:get} {opt id()}{break}
interview answers (loaded as data){p_end}

{phang}
{cmd:stats} {opt id()}{break}
interview statistics{p_end}

{phang}
{cmd:history} {opt id()}{break}
interview event history (loaded as data){p_end}

{phang}
{cmd:pdf} {opt id()} {opt saving()}{break}
download the interview PDF{p_end}

{phang}
{cmd:approve} {opt id()}{break}
supervisor approve ({opt comment()}){p_end}

{phang}
{cmd:reject} {opt id()}{break}
supervisor reject ({opt comment()} {opt resp:onsible()}){p_end}

{phang}
{cmd:hqapprove} {opt id()}{break}
HQ approve{p_end}

{phang}
{cmd:hqreject} {opt id()}{break}
HQ reject{p_end}

{phang}
{cmd:hqunapprove} {opt id()}{break}
HQ unapprove{p_end}

{phang}
{cmd:assign} {opt id()}{break}
Assign to an interviewer. Supply one of {opt resp:onsible()}, {opt responsibleid()}, or {opt responsiblename()}.{p_end}

{phang}
{cmd:assignsupervisor} {opt id()}{break}
Assign to a supervisor. Supply one of {opt resp:onsible()}, {opt responsibleid()}, or {opt responsiblename()}.{p_end}

{phang}
{cmd:comment} {opt id()} {opt question()} {opt comment()}{break}
comment on a question{p_end}

{phang}
{cmd:commentbyvar} {opt id()} {opt var:iable()} {opt comment()}{break}
comment by variable ({opt roster:vector()}){p_end}

{phang}
{cmd:delete} {opt id()}{break}
delete an interview {it:(destructive)}{p_end}


{marker questionnaire}{...}
{dlgtab:Questionnaires}

{pstd}{cmd:suso questionnaire} {it:action}{p_end}

{phang}
{cmd:list}{break}
questionnaires on the server ({opt all}){p_end}

{phang}
{cmd:get}{break}
details for {opt guid()} {opt qver()}{p_end}

{phang}
{cmd:document} {opt saving()}{break}
download the questionnaire document (PDF){p_end}

{phang}
{cmd:interviews}{break}
interviews for a questionnaire ({opt all}){p_end}

{phang}
{cmd:audio} [{opt get} {opt on} {opt off}]{break}
get/set audio recording for a questionnaire{p_end}

{phang}
{cmd:criticality} [{opt get} {opt level()}]{break}
get/set criticality level{p_end}


{dlgtab:Export jobs}

{pstd}{cmd:suso export} {it:action}{p_end}

{phang}
{cmd:list}{break}
existing export jobs ({opt type()} {opt istatus()} {opt estatus()} {opt hasfile} {opt all}){p_end}

{phang}
{cmd:start} {opt type()}{break}
start an export ({opt istatus()} {opt guid()} {opt qver()} {opt from()} {opt to()} {opt meta}|{opt nometa} {opt paradatareduced}){p_end}

{phang}
{cmd:status} {opt id()}{break}
poll an export job's status{p_end}

{phang}
{cmd:download} {opt id()} {opt saving()}{break}
download a completed export archive; add {opt unzip} (or {opt unzipw(pw)} for password-protected archives, {opt unzipto(dir)} for the target folder) to extract it{p_end}

{phang}
{cmd:extract} {opt file()} [{opt unzipto()} {opt unzipw()}]{break}
extract an existing export ZIP locally, without server requests or changing the active dataset{p_end}

{phang}
{cmd:get} {opt type()} {opt saving()}{break}
one-shot {cmd:start} {it:->} poll {it:->} {cmd:download} ({opt saving()} {opt unzip} {opt unzipw()} {opt unzipto()} {opt from()} {opt to()} {opt pollsecs()} {opt jobtimeout()}){p_end}

{phang}
{cmd:cancel} {opt id()}{break}
cancel/delete an export job {it:(destructive)}{p_end}


{pstd}
{opt type()} is one of {cmd:STATA}, {cmd:SPSS}, {cmd:Tabular}, {cmd:Binary},
{cmd:DDI}, {cmd:Paradata}. See {help suso##export:Export workflow}.

{dlgtab:Maps}

{pstd}{cmd:suso maps} {it:action}. See {help suso##maps:Maps}.{p_end}

{phang}
{cmd:list}{break}
list maps on the server ({opt workspace()}){p_end}

{phang}
{cmd:upload} {opt file()}{break}
upload a map file ({opt name()} to override the stored name){p_end}

{phang}
{cmd:delete} {opt name()}{break}
delete one map {it:(destructive)}{p_end}

{phang}
{cmd:deleteall}{break}
delete {bf:every} map in the workspace {it:(destructive; dry-run unless confirmed)}{p_end}

{phang}
{cmd:assign} {opt name()} {opt user()}{break}
give an interviewer access to a map{p_end}

{phang}
{cmd:unassign} {opt name()} {opt user()}{break}
remove an interviewer's access{p_end}


{dlgtab:Users, supervisors, and interviewers}

{pstd}Prefix the actions below with {cmd:suso}.{p_end}

{phang}
{cmd:user get} {opt id()}{break}
user details{p_end}

{phang}
{cmd:user create} {opt role()} {opt u:sername()} {opt p:assword()}{break}
create a user ({opt full:name()} {opt phone()} {opt email()} {opt supervisor()}){p_end}

{phang}
{cmd:user archive} {opt id()} {opt confirm}{break}
Archive a user and that user's interviewers{p_end}

{phang}
{cmd:user unarchive} {opt id()}{break}
unarchive a user{p_end}

{phang}
{cmd:supervisor list}{break}
supervisors ({opt all}){p_end}

{phang}
{cmd:supervisor get} {opt id()}{break}
supervisor details{p_end}

{phang}
{cmd:supervisor interviewers} {opt id()}{break}
interviewers under a supervisor ({opt all}){p_end}

{phang}
{cmd:interviewer get} {opt id()}{break}
interviewer details{p_end}

{phang}
{cmd:interviewer actionslog} {opt id()}{break}
interviewer action log ({opt start()} {opt end()}){p_end}


{dlgtab:Workspaces, settings, and statistics}

{pstd}Prefix the actions below with {cmd:suso}.{p_end}

{phang}
{cmd:workspace list}{break}
workspaces ({opt includedisabled}){p_end}

{phang}
{cmd:workspace get|status} {opt name()}{break}
workspace details/status{p_end}

{phang}
{cmd:workspace create} {opt name()} {opt display:name()}{break}
create a workspace{p_end}

{phang}
{cmd:workspace update} {opt name()} {opt display:name()}{break}
rename a workspace{p_end}

{phang}
{cmd:workspace enable|disable} {opt name()}{break}
Enable/disable a workspace; {cmd:disable} requires {opt confirm}{p_end}

{phang}
{cmd:workspace delete} {opt name()} {opt iknowthis()}{break}
delete a workspace {it:(destructive)}{p_end}

{phang}
{cmd:workspace assign} {opt userids()} {opt works:paces()}{break}
assign users to workspaces ({opt mode()} {opt supervisor()}){p_end}

{phang}
{cmd:settings get}{break}
server global notice{p_end}

{phang}
{cmd:settings set} {opt message()}{break}
set the global notice{p_end}

{phang}
{cmd:settings clear} {opt confirm}{break}
clear the global notice (destructive){p_end}

{phang}
{cmd:statistics questionnaires}{break}
questionnaires available for reporting{p_end}

{phang}
{cmd:statistics questions}{break}
reportable questions for {opt guid()} {opt qver()}{p_end}

{phang}
{cmd:statistics report} {opt question()}{break}
tabulation report ({opt exporttype()} {opt saving()} {opt query()}){p_end}


{pstd}
Most {cmd:workspace} verbs require admin rights and accept {opt usews} to act
against the configured workspace context.

{marker maps}{...}
{title:Maps (GraphQL)}

{pstd}
Unlike the rest of {cmd:suso}, map management uses Survey Solutions' {bf:GraphQL}
endpoint ({cmd:/graphql}), not the REST API. The {cmd:maps} subcommands wrap this
for you, so the workflow is the same as any other {cmd:suso} command:{p_end}

{p 8 12 2}{cmd:. suso maps list}{p_end}
{p 8 12 2}{cmd:. suso maps upload , file("C:/maps/region.zip")}{p_end}
{p 8 12 2}{cmd:. suso maps assign , name("region.tpk") user("FieldInt01")}{p_end}
{p 8 12 2}{cmd:. suso maps delete , name("region.tpk") confirm}{p_end}

{pstd}
{cmd:upload} sends a {bf:.zip} archive (containing a complete shapefile family
{cmd:.shp}+{cmd:.dbf}+{cmd:.shx}+{cmd:.prj}, and/or {cmd:.tif}/GeoTIFF or {cmd:.tpk}
basemaps) as a GraphQL multipart upload; one archive may carry several maps. {cmd:list} loads the maps into a
dataset (file name, size, import date, uploader). {cmd:delete} is irreversible and needs {opt confirm}. {cmd:deleteall} wipes the
whole library: by default it only lists what would go (a dry run); to actually
delete you confirm by typing the workspace name, e.g. {cmd:suso maps deleteall ,}
{cmd:iknowthis(myworkspace)}. It is throttled ({opt sleep()} ms between deletes,
default 200) and tolerant of per-map failures, reporting {cmd:r(deleted)}/{cmd:r(failed)}. {cmd:assign}/{cmd:unassign} control which interviewers
can download a given map to their tablet. If your server expects a workspace
argument on a map operation and rejects a call, the GraphQL error message is
shown verbatim so you can adjust.{p_end}

{marker destructive}{...}
{title:Server changes and confirmation}

{pstd}
Actions such as {cmd:interview delete}, {cmd:export cancel},
{cmd:assignment archive}, {cmd:user archive}, {cmd:workspace disable},
and {cmd:maps delete} require {opt confirm}. Review the target before adding
that option. {cmd:user archive} also archives that user's interviewers.{p_end}

{pstd}
{cmd:workspace delete} instead requires {opt iknowthis(workspace_name)}
matching the workspace name. {cmd:maps deleteall} lists its targets by default;
{opt iknowthis(workspace_name)} authorizes deletion of the workspace's maps.
These two commands do not use {opt confirm}.{p_end}

{pstd}
Selected destructive actions write records to {opt auditfile()} or its default
destination under {cmd:sysdir PERSONAL}. This is not a general command log:
read-only, export-download, and paradata/report commands do not create it.{p_end}


{marker results}{...}
{title:Stored results}

{pstd}
{cmd:suso} commands are {cmd:rclass}. Available results depend on the action. Run {cmd:return list} immediately
after that action; copy values into locals before running another command.{p_end}

{phang}
{cmd:r(http)}{break}
HTTP status code of the last request{p_end}

{phang}
{cmd:r(nobs)}{break}
number of rows loaded (list/get-as-data commands){p_end}

{phang}
{cmd:r(totalcount)}{break}
server-reported total for a paginated list{p_end}

{phang}
{cmd:r(saved)}{break}
path written by a download/{opt saving()} command{p_end}

{phang}
{cmd:r(bytes)}{break}
bytes written by a download{p_end}

{phang}
{cmd:r(sha256)}{break}
SHA-256 fingerprint of a successful download{p_end}

{phang}
{cmd:r(backup)}{break}
preserved previous file when replacing a download; empty for a new path{p_end}

{phang}
{cmd:r(elapsed_seconds)}, {cmd:r(attempts)}{break}
transfer operation time and HTTP attempt count for a download{p_end}

{phang}
{cmd:r(prepare_seconds)}, {cmd:r(download_seconds)}, {cmd:r(unzip_seconds)}{break}
export stage times; preparation/extraction use whole-second Stata clocks{p_end}

{phang}
{cmd:r(unzipdir)}, {cmd:r(manifest)}, {cmd:r(unzip_bytes)}{break}
actual completed extraction directory, file/hash manifest and expanded byte count{p_end}

{phang}
{cmd:r(unzip_backup)}{break}
directory containing prior files replaced during this extraction, if any{p_end}

{phang}
{cmd:r(dir)}{break}
actual fresh output directory for a backup run{p_end}

{phang}
{cmd:r(root)}{break}
requested parent directory containing backup runs{p_end}

{phang}
{cmd:r(jobid)}{break}
Export job ID; a local macro after {cmd:export start}, a scalar after {cmd:export get}{p_end}

{phang}
{cmd:r(nevents)}, {cmd:r(nints)}{break}
events and interviews loaded ({cmd:paradata get}/{cmd:load}){p_end}

{phang}
{cmd:r(nflagged)}, {cmd:r(n_}{it:flag}{cmd:)}{break}
flagged interviews, and count per flag ({cmd:paradata flags}){p_end}

{phang}
{cmd:r(nhistories)}, {cmd:r(nhistories_global)}{break}
exhaustive histories in the focused inventory, and in the full current role scope before {opt vars()}{p_end}

{phang}
{cmd:r(nremovalevents)}, {cmd:r(nremovalevents_global)}, {cmd:r(nremovalevents_allroles)}{break}
raw events in focused histories, in the full current role scope, and across all loaded roles{p_end}

{phang}
{cmd:r(ncascades)}, {cmd:r(ncascades_global)}{break}
focused and role-scope compact-priority histories{p_end}

{phang}
{cmd:r(ncompactevents)}, {cmd:r(ncompactevents_global)}, {cmd:r(nwiped)}{break}
focused and role-scope compact events; {cmd:r(nwiped)} is the compatibility alias for focused compact events{p_end}

{phang}
{cmd:r(noutsideevents)}, {cmd:r(noutsideevents_global)}{break}
focused and role-scope raw events outside compact-priority histories{p_end}

{phang}
{cmd:r(ntimingunknownhistories)}, {cmd:r(ntimingunknownhistories_global)}{break}
focused and role-scope histories whose compact timing cannot be classified{p_end}

{phang}
{cmd:r(ntimingunknownevents)}, {cmd:r(ntimingunknownevents_global)}{break}
raw events in those focused and role-scope timing-unknown histories{p_end}

{phang}
{cmd:r(naffectedquestions)}, {cmd:r(nidentityunknown)}{break}
distinct question-within-history units in the exhaustive focus, including histories represented by an identity-unavailable unit{p_end}

{phang}
{cmd:r(nreanswered)}, {cmd:r(nopen)}, {cmd:r(nunknown)}{break}
exhaustive-inventory units re-answered later, still ending in AnswerRemoved, or with unknown paradata final state{p_end}

{phang}
{cmd:r(nfinalanswered)}, {cmd:r(nexpectedblank)}{break}
affected instances answered in the supplied final export or correctly blank because disabled{p_end}

{phang}
{cmd:r(nanswereddisabled)}, {cmd:r(nblankenabled)}{break}
answers present while disabled or final blanks while enabled{p_end}

{phang}
{cmd:r(nlogicunknown)}, {cmd:r(nnotindata)}, {cmd:r(nfinalcheck)}{break}
effective logic unknown, absent from supplied data/roster export, and total instances requiring review{p_end}

{phang}
{cmd:r(hasfinaldata)}, {cmd:r(naffected)}{break}
whether {opt data()} was supplied, and interviews with at least one focused removal history{p_end}

{phang}
{cmd:r(report)}{break}
Path of the written Behaviour report ({cmd:paradata report}){p_end}

{phang}
{cmd:r(suite)}{break}
Path of the written combined report ({cmd:paradata suite}){p_end}

{phang}
{cmd:r(}{it:field}{cmd:)}{break}
each scalar field of a single-object response, lowercased{p_end}


{pstd}
For a single-object response (for example {cmd:export status} or
{cmd:interview stats}), each top-level scalar field of the JSON is returned as
{cmd:r(}{it:field}{cmd:)} with the field name lowercased (e.g. {cmd:r(exportstatus)},
{cmd:r(progress)}). Rows are loaded as the current dataset and are not duplicated
in {cmd:r()}.

{marker examples}{...}
{title:Examples}

{pstd}
Run these as separate recipes, substituting your own paths and identifiers.
The server examples assume that you have already configured a connection.{p_end}

{dlgtab:Save all completed interviews}

{p 8 8 2}{cmd:suso interview list, status(Completed) all}{p_end}
{p 8 8 2}{cmd:save "C:/survey/completed.dta", replace}{p_end}

{dlgtab:Keep events so you can run several analyses}

{p 8 8 2}{cmd:suso paradata load, file("C:/survey/paradata.tab")}{p_end}
{p 8 8 2}{cmd:save "C:/survey/events.dta", replace}{p_end}
{p 8 8 2}{cmd:suso paradata flags, saving("C:/survey/flags.dta") replace}{p_end}
{p 8 8 2}{cmd:use "C:/survey/events.dta", clear}{p_end}
{p 8 8 2}{cmd:suso paradata timing, by(question)}{p_end}

{dlgtab:Investigate removed answers against final data}

{p 8 8 2}{cmd:suso paradata load, file("C:/survey/paradata.tab")}{p_end}
{p 8 8 2}{cmd:suso paradata skips, ///}{p_end}
{p 12 12 2}{cmd:qx("C:/survey/questionnaire.html") ///}{p_end}
{p 12 12 2}{cmd:data("C:/survey/main.dta") ///}{p_end}
{p 12 12 2}{cmd:html("C:/survey/removals.html") ///}{p_end}
{p 12 12 2}{cmd:messages("C:/survey/review.txt") replace}{p_end}

{dlgtab:Audit final data without loading paradata}

{p 8 8 2}{cmd:suso paradata check, ///}{p_end}
{p 12 12 2}{cmd:qx("C:/survey/questionnaire.html") ///}{p_end}
{p 12 12 2}{cmd:data("C:/survey/main.dta") status(approved) ///}{p_end}
{p 12 12 2}{cmd:html("C:/survey/data_qc.html") replace}{p_end}

{dlgtab:Call another API endpoint}

{p 8 8 2}{cmd:suso raw /api/v1/interviews, ///}{p_end}
{p 12 12 2}{cmd:query("status=Completed") todata arraykey(Interviews)}{p_end}

{pstd}
{cmd:raw} defaults to GET. It accepts {opt method()}, {opt query()},
{opt body()}, {opt todata}, {opt arraykey()}, and {opt savefile()} with
{opt replace}. Raw DELETE requests require {opt allowdestructive}.
Use the named commands where available for their option checks and safeguards.{p_end}

{marker troubleshooting}{...}
{title:Troubleshooting}

{phang}{bf:Stata finds an older or different installation}{break}
Run {cmd:which suso} and {cmd:findfile suso.sthlp}. Load the ADO, help file,
and JAR from the same package directory. Close and reopen the help Viewer
after updating the file. Restart Stata after replacing a loaded JAR.{p_end}

{phang}{bf:Java or package compatibility error}{break}
Run {cmd:suso doctor, strict}. If the JAR is not found, set its full path
with {cmd:suso config, jar("C:/path/to/suso.jar")}.{p_end}

{phang}{bf:Server or authentication error}{break}
Check {cmd:suso config, show}, then run {cmd:suso login} and {cmd:suso ping}.
Verify the base URL, workspace short name, API credentials, and permissions.
Add {opt verbose} to a failing API call to inspect the method, URL, and status.{p_end}

{phang}{bf:A correct archive password gives a wrong ZIP password error}{break}
If the password works in another extractor, check the
{help suso##zip_password:literal-character entry rules} above.
The downloaded ZIP is retained. Retry locally with
{cmd:suso export extract, file("C:/survey/data.zip")}
and the corrected {opt unzipw()}; no new download is needed.{p_end}

{phang}{bf:Only part of an API list appears}{break}
Add {opt all}. If the row limit is reached, review the configured
{opt maxrows()} value; it applies to API pagination, not export file size.{p_end}

{phang}{bf:A paradata command asks for events}{break}
Reload the original paradata with {cmd:paradata load}, or {cmd:use} a saved
events dataset. {cmd:report}, {cmd:timing}, {cmd:flags}, and {cmd:skips}
leave summary tables in memory. Those tables cannot reconstruct the event log.{p_end}

{phang}{bf:Question wording or start/end checks are unavailable}{break}
Supply the matching questionnaire HTML with {opt qx()}. For clock checks,
supply both {opt startvar()} and {opt endvar()} with exact event-variable
names. Missing variables or captures remain unavailable; they are not inferred
from unrelated questions. Generate a new HTML report after changing inputs.{p_end}

{phang}{bf:Report controls change the display but Stata data stay the same}{break}
Browser filters and thresholds operate inside the HTML. They do not rewrite
the Stata table. Export the displayed review queue using the report's CSV
control when you need its current selection.{p_end}

{phang}{bf:An output file already exists}{break}
Choose a new filename, or add {opt replace} when you intend to replace it.
{opt saving()} writes a Stata table for analysis commands but an HTML file
for {cmd:report} and {cmd:suite}; {cmd:skips} and {cmd:check} use {opt html()}
for their browser reports.{p_end}

{marker requirements}{...}
{title:Requirements and local installation}

{pstd}
The command declares Stata 14.2 language mode and requires a Java runtime
supporting Java 11 or later. Run {cmd:suso doctor, strict} to check your
environment. The project wiki records the environments actually tested.{p_end}

{pstd}
Keep {cmd:suso.ado}, {cmd:suso.sthlp}, and {cmd:suso.jar} together. To try
the local package, set Stata's working directory to the extracted project
folder, then run:{p_end}

{p 8 8 2}{cmd:adopath ++ "./install"}{p_end}
{p 8 8 2}{cmd:which suso}{p_end}
{p 8 8 2}{cmd:suso doctor, strict}{p_end}
{p 8 8 2}{cmd:help suso}{p_end}

{pstd}
For a persistent local installation, substitute the full package path:{p_end}

{p 8 8 2}{cmd:net install suso, ///}{p_end}
{p 12 12 2}{cmd:from("C:/path/to/survey_solutions_api-main/install") replace}{p_end}

{pstd}
The detailed offline project guide is {cmd:wiki/index.html} in the source
package. Open it in a browser for report interpretation, development notes,
and validation records.{p_end}

{marker author}{...}
{title:Author}

{pstd}
{bf:Attique Ur Rehman}, Economist{break}
The World Bank {hline 1} Development Economics (DEC), Enterprise Surveys{break}
Email: {browse "mailto:attique@worldbank.org":attique@worldbank.org}{break}
Web: {browse "https://sites.google.com/view/attique-ur-rehman":https://sites.google.com/view/attique-ur-rehman}{p_end}

{title:Acknowledgments}

{pstd}
Thanks to {bf:Fahad Mirza} (World Bank / CERP,
{browse "https://github.com/fahad-mirza":github.com/fahad-mirza}) for his insights
and guidance, and for his self-contained Stata tooling ({cmd:sparkta},
{cmd:wordcloud2}) that helped shape this package's design.{p_end}

{pstd}
Built on the World Bank
{browse "https://docs.mysurvey.solutions/":Survey Solutions} platform and its
public REST API. This package is an independent client and is not an official
Survey Solutions product.{p_end}

{title:Also see}

{pstd}
Online: {browse "https://docs.mysurvey.solutions/headquarters/api/api-r-package/":Survey Solutions API documentation}{p_end}

{pstd}
Help:  {helpb survEye}, {helpb javacall}, {helpb import}, {helpb shell}{p_end}
