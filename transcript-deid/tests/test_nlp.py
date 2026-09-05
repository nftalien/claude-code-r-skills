"""Tests that need the real spaCy model; skipped automatically if absent."""

from transcript_deid.engine import Engine, render
from transcript_deid.models import Document, Segment


def run(nlp, roster, text, start=None, end=None):
    doc = Document("m.vtt", "vtt", [Segment(0, text, start=start, end=end)])
    Engine(roster, nlp).process(doc)
    return doc, render(doc)[0][0]


def test_ner_names_get_consistent_tags(nlp, roster):
    doc, out = run(nlp, roster, "My brother Diego Alvarez drove. Diego was quiet. Then Dr. Okafor came.")
    assert out == "My brother [NAME-1] drove. [NAME-1] was quiet. Then Dr. [NAME-2] came."


def test_offline_engine_has_no_network(nlp):
    import tldextract

    assert tldextract.extract.suffix_list_urls == ()


def test_durations_and_years_are_not_dates(nlp, roster):
    _, out = run(nlp, roster, "It took two weeks back in 2019, then on March 3rd it ended.")
    assert out == "It took two weeks back in 2019, then on [DATE] it ended."


def test_gibberish_is_garbled_not_organization(nlp, roster):
    doc, out = run(nlp, roster, "and then like ksdjf wpqoe zxmvn happened")
    assert "[GARBLED: ksdjf wpqoe zxmvn]" in out


def test_generic_locations_are_kept(nlp, roster):
    _, out = run(nlp, roster, "I went home, then to school, then to Round Rock.")
    assert out == "I went home, then to school, then to [LOCATION]."


def test_sentence_start_words_are_not_names(nlp, roster):
    _, out = run(nlp, roster, "Email me later. Okay so Sarah left.")
    assert out == "Email me later. Okay so [NAME-1] left."
