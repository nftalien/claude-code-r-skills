from transcript_deid.roster import Roster


def test_full_and_alias_matches(roster):
    hits = roster.find("Maria Lopez said Mari and JONATHAN whitfield were late.")
    got = {(h.text, h.participant.study_id, h.kind) for h in hits}
    assert ("Maria Lopez", "FEAR-0102", "full") in got
    assert ("Mari", "FEAR-0102", "alias") in got
    assert ("JONATHAN whitfield", "FEAR-0117", "full") in got


def test_possessive_and_word_boundaries(roster):
    hits = roster.find("That's Maria's bag, not Marianne's.")
    assert [h.text for h in hits] == ["Maria's"]


def test_ambiguous_first_names_need_capitals(roster):
    assert roster.find("I hope this works", fuzzy=False) == []
    assert [h.text for h in roster.find("Then Hope walked in", fuzzy=False)] == ["Hope"]


def test_fuzzy_catches_misspelling(roster):
    hits = roster.find("Did Jonathon come along?")
    assert hits and hits[0].participant.study_id == "FEAR-0117"
    assert hits[0].kind.startswith("fuzzy")
    assert hits[0].confidence < 0.9


def test_fuzzy_ignores_lowercase_words(roster):
    assert roster.find("the marina is closed") == []


def test_longest_match_wins(roster):
    hits = roster.find("Maria Lopez")
    assert len(hits) == 1 and hits[0].kind == "full"


def test_csv_round_trip(tmp_path, roster):
    p = tmp_path / "r.csv"
    roster.to_csv(p)
    again = Roster.from_csv(p)
    assert {x.study_id for x in again.participants} == {"FEAR-0102", "FEAR-0117", "FEAR-0120"}
    assert again.by_id["FEAR-0117"].aliases == ["Jon", "Jonny"]


def test_csv_extra_columns_and_missing_aliases(tmp_path):
    p = tmp_path / "r.csv"
    p.write_text("record_id,Study_ID,First_Name,Last_Name,site\n1,S1,Ana,Ruiz,A\n2,,x,y,B\n", encoding="utf-8")
    r = Roster.from_csv(p)
    assert len(r) == 1 and r.participants[0].full_name == "Ana Ruiz"


def test_add_alias_recompiles(roster):
    assert roster.find("Lopezita", fuzzy=False) == []
    roster.add_alias("FEAR-0102", "Lopezita")
    assert roster.find("Lopezita", fuzzy=False)[0].participant.study_id == "FEAR-0102"
