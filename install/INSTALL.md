# Installing the `suso` Stata package

`suso` is a Stata client for the Survey Solutions (SuSo) REST API. It installs
like any SSC-style package via `net install`, and ships three files:

| File         | Purpose                                  |
|--------------|------------------------------------------|
| `suso.ado`   | the Stata command                        |
| `suso.sthlp` | help file (`help suso`)                  |
| `suso.jar`   | dependency-free Java backend (HTTP calls)|

## Option A — install from a local folder

Put `stata.toc`, `suso.pkg`, `suso.ado`, `suso.sthlp`, `suso.jar` in one folder,
then in Stata:

```stata
net install suso, from("C:/path/to/this/folder") replace
```

On Windows use forward slashes or doubled backslashes in `from()`.

## Option B — install from GitHub (or any web folder)

Host the five files in a directory served over HTTPS (e.g. a GitHub repo;
use the `raw.githubusercontent.com` URL of the folder, with a trailing slash):

```stata
net install suso, from("https://raw.githubusercontent.com/<user>/<repo>/main/") replace
```

## Verify

```stata
which suso
help suso
suso doctor          // checks Java + locates suso.jar
```

`net install` places the files on the adopath (the PLUS directory). `suso.jar`
is found there automatically; if you ever move it, point to it with
`suso config , jar("C:/full/path/suso.jar")`.

## Update / uninstall

```stata
ado update suso              // if installed from a stable URL
ado uninstall suso
```

## First use

```stata
suso config , server("https://your-server") workspace("myws") ///
              user("API_USER") password("secret")
suso ping
```

Use a dedicated **API user** — not Headquarters or Administrator credentials.

## Submitting to SSC (maintainer note)

To publish on SSC (so users can `ssc install suso`), email the five files to
`research@stata.com` per the instructions at `help ssc` /
<http://repec.org/bocode/s/sscsubmit.html>. SSC distributes binary files such as
`suso.jar` without issue. The `suso.pkg` and `stata.toc` here already follow the
required format (`v 3`, `d`/`f` lines, `Distribution-Date`).
