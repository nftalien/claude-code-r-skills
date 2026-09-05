import pytest

from transcript_deid.roster import Participant, Roster


@pytest.fixture
def roster() -> Roster:
    return Roster(
        [
            Participant("FEAR-0102", "Maria", "Lopez", ["Mari"]),
            Participant("FEAR-0117", "Jonathan", "Whitfield", ["Jon", "Jonny"]),
            Participant("FEAR-0120", "Hope", "Grant", []),
        ]
    )


@pytest.fixture(scope="session")
def nlp():
    """Real spaCy/Presidio engine; skipped when the model is not installed."""
    pytest.importorskip("spacy")
    try:
        from transcript_deid.detect.nlp import load_engine

        return load_engine("en_core_web_lg")
    except OSError as e:  # model not installed
        pytest.skip(f"spaCy model unavailable: {e}")
