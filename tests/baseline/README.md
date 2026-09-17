These seven offline JavaScript suites are carried forward from the local
v1.7.26 SuSo audit-fix regression bundle (`auditfix-tests`). They execute the
JavaScript extracted from the ADO supplied as the first argument. They cover
behaviour metrics, questionnaire ordering, local raw-history parsing, suite
messages, removal inventory/filtering, and Data QC.

They were not present in the GitHub checkout. Their inclusion makes the prior
regression coverage available in the candidate package. Only obsolete assertions
whose intended behavior has changed should be adapted, with the reason recorded.

For v1.7.28, four obsolete UI harness expectations were updated: the history
button now uses `classList.contains`; startup opens the single review-list view;
the Skip fake document supplies body/head for compact-view setup; and the suite
extractor reads both plain and compound-quoted Mata writers, including the third
listener for removal navigation. Badge validation and relay checks remain intact.
All prior metric/denominator/filter/oracle assertions were retained. The real DOM
suites separately verify these new UI interactions against emitted HTML.
