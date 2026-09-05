import pytest

from transcript_deid.detect.phi import find_phi


@pytest.mark.parametrize(
    "text,typ",
    [
        ("call 512-555-0147 now", "PHONE"),
        ("call (512) 555 0147 now", "PHONE"),
        ("five one two five five five zero one four seven", "PHONE"),
        ("write to jon.w@example.com", "EMAIL"),
        ("it's on www.example.org/page", "URL"),
        ("SSN 123-45-6789", "SSN"),
        ("MRN: 4482913", "MRN"),
        ("my chart number is 4482913", "MRN"),
        ("I live at 1420 Maple Avenue", "ADDRESS"),
        ("I live at 12 N Oak St Apt 4", "ADDRESS"),
        ("born 04/12/2008", "DATE"),
        ("on March 3rd", "DATE"),
        ("on the 3rd of March, 2024", "DATE"),
        ("she is 92 years old", "AGE"),
        ("grandpa turned 101", "AGE"),
        ("policy number 88213345", "ID_NUMBER"),
    ],
)
def test_patterns(text, typ):
    assert typ in {h.type for h in find_phi(text)}, find_phi(text)


def test_year_alone_and_young_age_are_not_phi():
    types = {h.type for h in find_phi("In 2019 I was 15 years old and had 3 friends.")}
    assert "DATE" not in types and "AGE" not in types
