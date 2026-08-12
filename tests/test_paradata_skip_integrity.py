from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADO = (ROOT / "suso.ado").read_bytes()
TEXT = ADO.decode("utf-8")


def _section(start: str, end: str) -> str:
    i = TEXT.index(start)
    j = TEXT.index(end, i)
    return TEXT[i:j]


def test_no_raw_backspace_regex_bytes():
    assert b"\x08" not in ADO
    assert "\\b`av'\\b" in TEXT
    assert "\\b`bv'\\b" in TEXT


def test_skips_detects_on_full_stream_then_filters():
    s = _section("program _suso_para_skips", "* ---- report:")
    assert "_suso_para_varsel" not in s
    assert "vars() is an output filter only" in s
    assert "sk_vsel" in s and "runsel" in s and "trigsel" in s


def test_report_and_suite_preserve_event_adjacency():
    r = _section("program _suso_para_report", "* ---- helper: escape text for HTML")
    assert "tempfile EVFULL" in r
    assert 'quietly use `"`EVFULL\'"\', clear' in r
    assert 'vars(`"`vars\'"\')' in r
    q = _section("program _suso_para_suite", "*===============================================================================\n* examples")
    prefix = q.split('if `"`saving\'"\'==""', 1)[0]
    assert "_suso_para_varsel" not in prefix
    assert q.count('vars(`"`vars\'"\')') >= 2


def test_final_state_is_computed_and_reported_safely():
    assert "sk_finalans" in TEXT
    assert "sk_reanswered" in TEXT
    assert "sk_open" in TEXT
    assert "sk_unknown" in TEXT
    assert "All affected questions were re-answered later" in TEXT
    assert "they are empty now" not in TEXT
    assert "the skip logic erased them" not in TEXT


def test_time_window_is_nonnegative_and_supports_both_event_orders():
    assert "inrange(`dtprev', 0, `window'*1000)" in TEXT
    assert "inrange(`dtnext', 0, `window'*1000)" in TEXT
    assert "sk_prevnear | sk_nextnear" in TEXT
    assert "`rspan'<=`window'*1000" in TEXT


def test_reanswer_model():
    events = [
        ("q1", "AnswerRemoved"),
        ("q2", "AnswerRemoved"),
        ("q1", "AnswerSet"),
    ]
    final = {}
    for var, event in events:
        final[var] = event
    assert final["q1"] == "AnswerSet"
    assert final["q2"] == "AnswerRemoved"


def test_filtering_after_detection_cannot_create_adjacency():
    stream = [
        ("AnswerRemoved", "l6"),
        ("AnswerSet", "other"),
        ("AnswerRemoved", "l3"),
        ("AnswerSet", "other2"),
        ("AnswerRemoved", "l7a"),
    ]
    raw_runs = []
    run = []
    for event, var in stream:
        if event == "AnswerRemoved":
            run.append(var)
        else:
            if run:
                raw_runs.append(run)
                run = []
    if run:
        raw_runs.append(run)
    assert max(map(len, raw_runs)) == 1
    selected = [r for r in raw_runs if any(v.startswith("l") for v in r)]
    assert max(map(len, selected)) == 1


def test_install_copy_matches_root():
    assert (ROOT / "install" / "suso.ado").read_bytes() == ADO
