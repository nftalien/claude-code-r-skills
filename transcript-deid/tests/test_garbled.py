from transcript_deid.detect.garbled import find_garbled


def notes(text, **kw):
    return {h.note for h in find_garbled(text, **kw)}


def test_markers():
    n = notes("so [inaudible] then (unintelligible 00:24) and [crosstalk]")
    assert "transcriber marker" in n and len(find_garbled("[inaudible] x (crosstalk)")) == 2


def test_repeated_tokens():
    assert "repeated token" in notes("and he he he left")
    assert not notes("no no no, I mean it")  # emphatic repetition is real speech


def test_placeholders_and_fragments():
    assert "placeholder characters" in notes("I said *** to him")
    assert "stutter/fragment run" in notes("I- I- I- I don't know")


def test_oov_run_uses_callback():
    oov = lambda w: w.lower() in {"ksdjf", "wpqoe", "zxmvn"}
    hits = find_garbled("like ksdjf wpqoe zxmvn okay", is_oov=oov)
    assert [h.text for h in hits] == ["ksdjf wpqoe zxmvn"]
    assert not find_garbled("just one ksdjf word", is_oov=oov)


def test_speaking_rate_from_cue_timing():
    hits = find_garbled("one two three four five six seven eight nine ten", start="00:00:01.000", end="00:00:02.000")
    assert any("words/sec" in h.note for h in hits)
    assert not find_garbled("one two three", start="00:00:01.000", end="00:00:03.000")


def test_overlapping_hits_merge():
    hits = find_garbled("[inaudible] [inaudible]")
    assert len(hits) == 2 and all(h.type == "GARBLED" for h in hits)
