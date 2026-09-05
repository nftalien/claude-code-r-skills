"""Phrases that often carry indirect identifiers.

These are *not* redacted automatically; they get a low-confidence INDIRECT
flag so a reviewer reads the sentence.  Examples: "the only ... in", "my
teacher Mr.", "works at", school/team/church names, rare diagnoses.
"""

from __future__ import annotations

import re

from .hits import Hit

PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bthe only\b[^.?!]{3,60}\b(?:in|at|on|who)\b", re.I), "uniqueness claim"),
    (re.compile(r"\b(?:works?|worked|working|teaches|taught|coaches?|coached)\s+(?:at|for)\s+(?:the\s+)?[A-Z][\w&'.\- ]{2,40}"), "employer / school"),
    (re.compile(r"\b(?:goes|went|going)\s+to\s+[A-Z][\w'.\- ]{2,40}\s+(?:High|Middle|Elementary|Academy|School|College|University)\b"), "school name"),
    (re.compile(r"\b(?:Mr|Mrs|Ms|Miss|Dr|Coach|Pastor|Father|Rabbi|Imam|Officer|Nurse|Professor|Prof)\.?\s+[A-Z][a-z]+"), "titled person"),
    (re.compile(r"\b(?:my|our|his|her|their)\s+(?:therapist|psychiatrist|doctor|pediatrician|counselor|counsellor|teacher|coach|principal|boss|manager|pastor|caseworker|social worker|probation officer)\s+(?:is\s+|was\s+|named\s+|called\s+)?[A-Z][a-z]+"), "named provider / authority"),
    (re.compile(r"\b(?:twins?|triplets?|adopted|foster|deployed|paralyzed|amputat\w+|transplant|wheelchair|blind|deaf|olympi\w+|famous|viral|newspaper|on the news)\b", re.I), "rare characteristic"),
    (re.compile(r"\b[A-Z][\w'.\-]+\s+(?:Hospital|Medical Center|Clinic|Health|Church|Temple|Mosque|Synagogue|Elementary|Middle School|High School|Academy|University|College|Mall|Park)\b"), "named institution"),
    (re.compile(r"\b(?:tattoo|scar|birthmark)\s+(?:of|on|that says)\b[^.?!]{3,40}", re.I), "distinguishing mark"),
]


def find_indirect(text: str) -> list[Hit]:
    hits: list[Hit] = []
    for rx, note in PATTERNS:
        for m in rx.finditer(text):
            hits.append(Hit(m.start(), m.end(), m.group(0), "INDIRECT", 0.3, "heuristic", note))
    return hits
