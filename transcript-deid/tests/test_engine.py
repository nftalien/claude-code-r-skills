from transcript_deid.engine import Engine, NameRegistry, apply_flags, render, residual_check
from transcript_deid.models import Document, Flag, Segment


def make_doc(lines):
    segs = []
    for i, (spk, text) in enumerate(lines):
        segs.append(Segment(index=i, text=text, speaker=spk))
    return Document(source="mem.txt", format="txt", segments=segs)


def test_name_registry_links_first_name_to_full_name():
    r = NameRegistry()
    assert r.tag("Maria Lopez") == "[NAME-1]"
    assert r.tag("Maria's") == "[NAME-1]"
    assert r.tag("Lopez") == "[NAME-1]"
    assert r.tag("Dr. Okafor") == "[NAME-2]"
    assert r.tag("okafor") == "[NAME-2]"


def test_engine_without_nlp_uses_roster_and_regex(roster):
    doc = make_doc([("Interviewer", "Hi Maria, your number is 512-555-0147?"), ("Maria Lopez", "Yes. [inaudible] Jonny too.")])
    Engine(roster, None).process(doc)
    texts, speakers = render(doc)
    assert texts[0] == "Hi FEAR-0102, your number is [PHONE]?"
    assert speakers == ["Interviewer", "FEAR-0102"]
    assert texts[1] == "Yes. [GARBLED: [inaudible]] FEAR-0117 too."
    assert "FEAR-0102" not in str(doc.meta["name_map"])


def test_unknown_speaker_label_becomes_generic_name(roster):
    doc = make_doc([("Sam Ortiz", "hello"), ("Interviewer", "Sam, go on."), ("Sam Ortiz", "ok")])
    Engine(roster, None).process(doc)
    _, speakers = render(doc)
    assert speakers == ["[NAME-1]", "Interviewer", "[NAME-1]"]


def test_structured_identifier_beats_participant_substring(roster):
    doc = make_doc([(None, "mail jon.w@example.com please")])
    Engine(roster, None).process(doc)
    texts, _ = render(doc)
    assert texts[0] == "mail [EMAIL] please"


def test_decisions_control_export(roster):
    doc = make_doc([(None, "Maria met Jonny on 04/12/2008.")])
    Engine(roster, None).process(doc)
    by_text = {f.text: f for f in doc.flags}
    by_text["Jonny"].decision = "reject"
    by_text["04/12/2008"].decision = "reject"
    texts, _ = render(doc)
    assert texts[0] == "FEAR-0102 met Jonny on 04/12/2008."


def test_pending_phi_is_redacted_but_indirect_is_not():
    seg = Segment(0, "the only kid in Franklin who fences, born 04/12/2008")
    doc = Document("m", "txt", [seg])
    Engine(None, None).process(doc)
    types = {f.type: f.decision for f in doc.flags}
    assert types["INDIRECT"] == "pending" and types["DATE"] == "accept"
    texts, _ = render(doc)
    assert texts[0] == "the only kid in Franklin who fences, born [DATE]"


def test_apply_flags_skips_overlaps():
    text = "abcdef"
    flags = [Flag(0, 0, 4, "abcd", "NAME", "[X]", 1, "t", decision="accept"), Flag(0, 2, 6, "cdef", "NAME", "[Y]", 1, "t", decision="accept")]
    assert apply_flags(text, flags) == "ab[Y]"


def test_residual_check_catches_rejected_participant(roster):
    doc = make_doc([("Maria Lopez", "hi")])
    Engine(roster, None).process(doc)
    doc.flags[0].decision = "reject"
    texts, speakers = render(doc)
    leaks = residual_check(doc, roster, texts, speakers)
    assert leaks and leaks[0]["study_id"] == "FEAR-0102"
