suso — Survey Solutions API client for Stata
![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Stata](https://img.shields.io/badge/Stata-14.2%2B-1a5276)
![Java](https://img.shields.io/badge/Java-11%2B-b07219)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
A safety-first Stata command that wraps the World Bank Survey Solutions REST and
GraphQL API. A small, dependency-free Java backend (`suso.jar`) performs the
authenticated HTTPS calls (every verb, including `PATCH`/`DELETE` and GraphQL),
list endpoints load directly into a Stata dataset, and destructive operations are
guarded at two independent layers. Built for the WBES / B-READY / ISES fieldwork
workflow.
> **Survey Solutions** is the World Bank's computer-assisted survey platform
> (<https://docs.mysurvey.solutions>). `suso` is an independent client for its API; it is
> not affiliated with or endorsed by the Survey Solutions team.
Features
One command, full API surface: assignments, interviews, questionnaires, exports,
users/supervisors/interviewers, workspaces, settings, statistics, and maps (GraphQL).
List endpoints stream straight into a Stata dataset with automatic pagination
(`, all`), ISO-8601 dates converted to `%tc`, and `r(nobs)`/`r(totalcount)`.
`suso backup` — one-shot full-workspace archive (questionnaires + per-type exports +
assignments/users).
`suso maps deleteall` — guarded bulk wipe of a workspace map library (dry-run first).
Defense-in-depth safety on destructive calls, plus an audit log.
Zero third-party dependencies — the backend uses only the JDK and Stata's own SFI.
Requirements
Stata 14.2+ with Java integration, on a Java 11+ runtime
(`suso doctor` prints the JVM version and flags anything older). Java 11+ is required
because Survey Solutions uses `PATCH` extensively.
`suso.jar` on the adopath (installed automatically below), or set with
`suso config , jar("…/suso.jar")`.
Install
From this repository (recommended). In Stata:
```stata
net install suso, from("https://raw.githubusercontent.com/arehman10/survey_solutions_api/main/install") replace
```
Manually. Download `suso.ado`, `suso.sthlp` and `suso.jar`, then copy them into your
Stata `PLUS` folder (run `display c(sysdir_plus)` to locate it, e.g. `…/ado/plus/s/`).
The `.jar` can live there too, or anywhere if you point to it with `suso config , jar()`.
Then verify and configure:
```stata
suso doctor          // environment + Java check
suso config , server("https://<your-server>") workspace("<workspace>")
suso ping            // prompts for user + password (masked), then checks auth
```
Only `server()` and `workspace()` are required. `user()` and `password()` are optional —
if omitted, `suso` prompts for them (masked) the first time a command contacts the server,
or you can run `suso login`. To supply them non-interactively, add `user()`/`password()`,
or — safer — export the `SUSO_PASSWORD` environment variable before launching
Stata so it never enters your command history. Configuration lives in the Stata session
only and is never written to disk. Survey Solutions' convention is to create an
API-user account and use Basic auth (`auth(bearer) token()` is also supported).
Quick start
```stata
suso assignment list , all                       // -> dataset of assignments
suso interview   list , status(Completed) all    // -> dataset of interviews

* export: start -> poll -> download
suso export start , type(STATA) guid(<guid>) qver(3) istatus(ApprovedBySupervisor)
suso export status   , id(`=r(jobid)')
suso export download , id(`=r(jobid)') saving("ises.zip") replace unzip

suso interview reject , id(<uuid>) comment("GPS off-square; please revisit")

* archive a whole workspace in one call
suso backup , dir("C:/archive/srilanka") types(STATA Paradata)
```
See `suso_examples.do` for a fuller tour, and `help suso` inside Stata.
Commands
```
setup        config  ping  doctor  examples  endpoints  about  raw  login
assignment   list  get  history  quantitysettings  create  assign  quantity
             close  archive  unarchive  audio  targetarea
interview    list  get  stats  history  pdf  approve  reject  hqapprove
             hqreject  hqunapprove  assign  assignsupervisor  comment
             commentbyvar  delete
questionnaire list  get  document  interviews  audio  criticality
export       list  start  status  download  cancel
maps         list  upload  delete  deleteall  assign  unassign        (GraphQL)
user         get  create  archive  unarchive
supervisor   list  get  interviewers
interviewer  get  actionslog
workspace    list  get  status  create  update  enable  disable  delete  assign
settings     globalnotice get|set|clear
statistics   questionnaires  questions  report
backup       full-workspace archive (questionnaires + exports + assignments/users)
```
Safety design (destructive operations)
Defense in depth — the Stata layer requires explicit opt-in, and the Java backend
independently refuses any destructive request unless the Stata layer set its internal
allow-flag. A bug on either side cannot silently destroy data.
Operation	Guard
`interview delete`, `export cancel`, `assignment archive`, `user archive`, `workspace disable`, `maps delete`	require `, confirm`
`maps deleteall`	dry-run by default; to execute, retype the workspace name in `iknowthis(name)`
`workspace delete`	retype the exact name in `iknowthis(name)`, plus a pre-flight `status` check that refuses unless the server says the workspace can be deleted (override with `force`)
Every destructive action is appended to an audit log
(default `<PERSONAL>/suso_audit.log`; change with `suso config , auditfile()`),
recording timestamp, user, server/workspace, action, target and HTTP status.
Pagination is automatic (`, all`) but capped at `SUSO_MAXROWS` (default 100,000) to avoid
accidental mega-pulls; raise it with `suso config , maxrows()` or use `suso export` /
`suso backup` for bulk data.
SSL / certificates / proxy
If a command fails with `SSLHandshakeException` / `PKIX path building failed` /
`unable to find valid certification path`, Stata's Java runtime doesn't trust the
server's TLS certificate. This is common on non-World-Bank servers, self-signed
certificates, or with an outdated Java trust store — not just corporate networks.
Two fixes:
Trust the certificate (recommended). Import the server's root CA into the trust
store of the Java runtime Stata uses — find it with `suso doctor` (prints Java home):
```bash
keytool -importcert -alias suso-server -file server-ca.crt -cacerts
# older layout: -keystore "<java.home>/lib/security/cacerts" -storepass changeit
```
Skip verification for this session (quick, less secure). Useful for a quick test
or a server you trust whose CA you can't easily import:
```stata
suso config , insecure
suso ping
```
This disables TLS certificate + hostname checks for the session and warns on every
request; turn it back on with `suso config , noinsecure`. Prefer importing the CA for
anything ongoing.
Proxy:
```stata
suso config , proxyhost(proxy.example.org) proxyport(8080)
suso config , proxyhost(...) proxyport(...) proxyuser(...) proxypass(...)
```
`suso raw` — reach any endpoint
```stata
suso raw /api/v1/settings/globalnotice                       // GET, flatten to r()
suso raw /api/v1/assignments , query(Limit=5&Offset=0) todata arraykey(Assignments)
suso raw /api/v1/interviews/<uuid> , method(DELETE) allowdestructive
```
Build the jar from source
A prebuilt `suso.jar` ships in the repo (root and `install/`) and works on any Stata with
a Java 11+ runtime. Rebuild only if it errors at runtime (e.g. a `NoSuchMethodError`,
which would indicate a different SFI on your Stata). You need a JDK 11+ and your Stata's
`sfi-api.jar` (find your Stata folder with `display c(sysdir_stata)`):
```bash
./build.sh /path/to/sfi-api.jar                              # macOS / Linux
build.bat  "C:\Program Files\Stata19\utilities\jar\sfi-api.jar"   # Windows
```
The jar is compiled to Java 11 bytecode with no external dependencies and contains only
`org/worldbank/suso/*` (it relies on Stata's own `com.stata.sfi` at runtime).
Repository layout
```
suso.ado / suso.sthlp / suso.jar   frontend, help, backend (top level, for quick download)
install/                           net-install package (stata.toc, suso.pkg, + the 3 files)
src/org/worldbank/suso/            Java backend source
  Http.java   authenticated HTTPS (REST + GraphQL, downloads, multipart upload)
  Json.java   dependency-free JSON parse / write
  Stata.java  SFI bridge: entry points + JSON->dataset loader
  Zip.java    encrypted-ZIP extractor for export downloads
build.sh / build.bat               rebuild suso.jar from src/
suso_examples.do                   runnable examples
```
Versioning & releases
Releases are tagged `vMAJOR.MINOR.PATCH` and the version is recorded in `suso.pkg` and
shown by `suso about`. After cloning, pin a release with `git checkout v1.6.0`.
Citation
If `suso` supports your research or fieldwork, please cite it:
> Rehman, A. U. (2026). *suso: A Survey Solutions API client for Stata* (v1.6.0)
> \[Computer software]. https://github.com/arehman10/survey_solutions_api
Contributing
Issues and pull requests are welcome. For backend changes, please rebuild the jar from
`src/` and confirm `suso doctor` / `suso ping` pass against a test workspace.
Acknowledgments
Huge thanks to Fahad Mirza (World Bank / CERP) for his
insights and guidance, and for his self-contained Stata tooling
(sparkta,
wordcloud2), which helped shape the
design of this package.
License
MIT © 2026 Attique Ur Rehman (The World Bank, Development Economics).
Architecture (one line)
`suso.ado` sets `SUSO_*` globals → `javacall org.worldbank.suso.Stata …` → `Http`
(`java.net.http`) executes → `Json` parses → results are written back into the Stata
dataset / `r()` via the SFI, and the password global is scrubbed after every call.
