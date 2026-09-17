# Data-path regression checks

From the package/repository root:

```sh
python3 tests/data_path_source_regression.py
```

The Python checks verify source wiring and safeguards. They do not execute
Stata and do not certify runtime behavior.

In a licensed Stata 14.2+ session, run:

```stata
do tests/data_path_smoke.do
do tests/option_integration_smoke.do
```

The first file requires the ADO and no Java call. It checks configured numeric
missing codes, text and identifier preservation, affected-question enablement,
trigger final values, 260-option membership with status/filter counts, malformed
metadata errors, previous/next/tie/exact-60-second/outside-window answer events,
and exports without Parameters. It verifies saved final data are unchanged.
The second file requires the packaged Java/SFI bridge. It generates a 61-option
questionnaire, parses it through the actual bridge, and checks Data-QC totals
and status/filter breakdowns, including a valid option 61 and an invalid 999.
Both use only temporary synthetic fixtures and restore caller data.

The current compatibility contract is explicit: `misscodes(-9)` replaces the
default numeric list `-999999999`. To normalize both, specify
`misscodes(-9 -999999999)`. All final-data report paths now share that policy.
Numeric-looking text such as `"-9"` is retained as text. The canonical text
sentinel `##N/A##` is normalized, except in the interview identifier.
