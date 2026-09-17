# Offline report verification

From the package root:

```sh
python3 tests/run_offline.py
```

The baseline suites execute the report's JavaScript extracted from the supplied
`suso.ado`; no Stata or server is required. Additional correction suites in this
folder are picked up automatically when their filenames contain `regression`.

For the source-template DOM integration test, Node.js 18 or later and Python 3
are required. Install the development-only pinned jsdom dependency:

```sh
npm install --prefix tests
NODE_PATH=tests/node_modules python3 tests/run_offline.py --dom
```

On Windows, set `NODE_PATH` to the absolute `tests/node_modules` path before
running the Python command. These dependencies are used only by the tests;
generated reports remain standalone HTML with no npm dependency.

The DOM test regenerates its preview from the candidate source, checks real
interactive controls and confirms suite iframe payloads equal the standalone
reports. It does not provide pixel/layout screenshots or run Stata calculations.
Run `examples/example.do` separately in licensed Stata for the real suite route.

The Section timing regression suite tests contributor aggregation, intersected
actor/status/data-value filters, period reconciliation, unmapped and untimed
cases, CSV output and lite-mode detail. The DOM suite exercises the same page
controls in source-generated HTML, including empty scopes and section sorting.

In licensed Stata, run `do tests/section_timing_smoke.do` to test the actual
allocation helper and numeric serializer without a server or API credentials.
The smoke test uses hand-built derived intervals; `do examples/example.do`
separately exercises event derivation, questionnaire parsing and the full suite.

`history_index_regression.js` executes the emitted worker with real Blob reads;
`history_sections_regression.js` tests the raw-history section allocator. DOM
checks separately exercise assignment lookup, unnamed-actor filtering and
percentage display. No actual browser upload or persistent storage is used.

For a bounded speed comparison, keep an older ADO outside the source tree and run:

```sh
node tools/benchmark_history.js --baseline /path/to/older/suso.ado --rows 1000000 --runs 3
node tools/benchmark_history.js --baseline /path/to/older/suso.ado --rows 300000 --runs 3 --shape interleaved
```

This benchmark uses generated in-memory Blob data. It does not measure Windows,
network-drive throughput, or browser layout.

The filter-search regression in `report_metrics_regression.js` covers a matching
responsive interview whose duration signal clears after filtering. The DOM
regressions exercise search, saved values, neutral results, CSV, and the suite's
mirrored variable/value selectors. `examples/preview/filter-search-example.html`
opens the source-generated synthetic reproduction with lf_responsive = 1.
