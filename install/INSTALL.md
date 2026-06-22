# Installing the `suso` Stata package

`suso` is a Stata client for the Survey Solutions (SuSo) REST and GraphQL API. It
installs like any SSC-style package via `net install`. The package directory holds
five files:

| File         | Purpose                                   |
|--------------|-------------------------------------------|
| `stata.toc`  | package catalog (read by `net install`)   |
| `suso.pkg`   | package manifest (file list + metadata)   |
| `suso.ado`   | the Stata command                         |
| `suso.sthlp` | help file (`help suso`)                   |
| `suso.jar`   | dependency-free Java backend (HTTP calls) |

## Option A — install from a local folder

Put all five files in one folder, then in Stata:

```stata
net install suso, from("C:/path/to/this/folder") replace
```

On Windows use forward slashes or doubled backslashes in `from()`.

## Option B — install from GitHub

The five files live in the repo's `install/` folder, so point `from()` at the
**raw** URL of that folder (note: `raw.githubusercontent.com`, not `github.com`,
and the `install` path — no `/tree/`):

```stata
net install suso, from("https://raw.githubusercontent.com/arehman10/survey_solutions_api/main/install") replace
```

## Verify

```stata
which suso
help suso
suso doctor          // checks Java + locates suso.jar
```

`net install` places the files on the adopath (the PLUS directory). `suso.jar` is
found there automatically; if you ever move it, point to it with
`suso config , jar("C:/full/path/suso.jar")`.

## Update / uninstall

```stata
adoupdate suso, update     // re-pull if installed from a stable URL
ado uninstall suso
```

After re-installing into the same Stata session, run `discard` (or restart Stata)
so the previously loaded copy is dropped and the new one takes effect.

## First use

Only `server()` and `workspace()` are required — `suso` prompts for the user name
and a masked password the first time a command contacts the server (or run
`suso login`):

```stata
suso config , server("https://your-server") workspace("myws")
suso ping
```

To script it non-interactively, add `user()`/`password()`, or set the
`SUSO_PASSWORD` environment variable before launching Stata. Use a dedicated
**API user** — not Headquarters or Administrator credentials.
