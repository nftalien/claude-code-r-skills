"""Regex recognisers for HIPAA Safe Harbor identifiers that models miss.

These are deliberately conservative: better to flag and let a reviewer
reject than to leak.  Confidence is per-pattern.
"""

from __future__ import annotations

import re

from .hits import Hit

_MONTH = r"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
_STREET_SUFFIX = (
    r"(?:St(?:reet)?|Ave(?:nue)?|Rd|Road|Blvd|Boulevard|Dr(?:ive)?|Ln|Lane|Ct|Court|Way|Pl(?:ace)?|"
    r"Ter(?:race)?|Cir(?:cle)?|Pkwy|Parkway|Hwy|Highway|Trail|Trl|Loop|Run|Row|Sq(?:uare)?)"
)

PATTERNS: list[tuple[str, re.Pattern[str], float, str]] = [
    ("SSN", re.compile(r"\b\d{3}-\d{2}-\d{4}\b"), 0.95, ""),
    ("PHONE", re.compile(r"(?<!\d)(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}(?!\d)"), 0.95, ""),
    ("PHONE", re.compile(r"(?<!\d)\d{10}(?!\d)"), 0.6, "10 digits, may be a phone"),
    ("EMAIL", re.compile(r"\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b"), 0.98, ""),
    ("URL", re.compile(r"\b(?:https?://|www\.)\S+\b|\b[\w-]+\.(?:com|org|net|edu|gov)\b(?:/\S*)?", re.I), 0.9, ""),
    ("MRN", re.compile(r"\b(?:MRN|medical record(?: number)?|record number|chart(?: number)?)(?:\s+(?:is|was|of))?\s*[:#]?\s*[A-Z]?\d{5,10}\b", re.I), 0.95, ""),
    ("ID_NUMBER", re.compile(r"\b(?:account|acct|policy|member|insurance|license|licence|passport|case|claim)\s*(?:number|no\.?|#)?\s*[:#]?\s*[A-Z]{0,3}\d{5,12}\b", re.I), 0.85, ""),
    ("ADDRESS", re.compile(rf"\b\d{{1,6}}(?:\s[NSEW]\.?|\s(?:North|South|East|West))?\s(?:[A-Z][a-z]+\s){{1,3}}{_STREET_SUFFIX}\.?(?:\s(?:Apt|Apartment|Unit|Suite|Ste|#)\s*\w+)?\b"), 0.9, ""),
    ("ZIP", re.compile(r"\b\d{5}(?:-\d{4})?\b(?=\s*$|[\s,.;])"), 0.4, "5-digit number, may be a ZIP code"),
    ("DATE", re.compile(r"\b(?:0?[1-9]|1[0-2])[/.-](?:0?[1-9]|[12]\d|3[01])(?:[/.-](?:\d{4}|\d{2}))?\b"), 0.9, ""),
    ("DATE", re.compile(rf"\b{_MONTH}\.?\s+\d{{1,2}}(?:st|nd|rd|th)?(?:,?\s+\d{{4}})?\b", re.I), 0.9, ""),
    ("DATE", re.compile(rf"\b\d{{1,2}}(?:st|nd|rd|th)?\s+(?:of\s+)?{_MONTH}\.?(?:,?\s+\d{{4}})?\b", re.I), 0.9, ""),
    ("DATE", re.compile(rf"\b{_MONTH}\.?,?\s+(?:19|20)\d{{2}}\b", re.I), 0.6, "month + year; Safe Harbor allows year alone"),
    ("AGE", re.compile(r"\b(?:9\d|1[0-2]\d)(?:\s*(?:-|\s)?years?(?:\s|-)old|\s*y/?o\b|\s+years?\s+of\s+age)", re.I), 0.9, "age over 89"),
    ("AGE", re.compile(r"\b(?:aged?|turned|turning|I'm|I am|he's|she's|they're|is|was)\s+(?:9\d|1[0-2]\d)\b", re.I), 0.7, "possible age over 89"),
]

# Spoken-form phone/date fragments transcribers often write out.
SPOKEN_PHONE = re.compile(
    r"\b(?:(?:zero|one|two|three|four|five|six|seven|eight|nine|oh)[\s-]+){6,}(?:zero|one|two|three|four|five|six|seven|eight|nine|oh)\b",
    re.I,
)


def find_phi(text: str) -> list[Hit]:
    hits: list[Hit] = []
    for typ, rx, conf, note in PATTERNS:
        for m in rx.finditer(text):
            hits.append(Hit(m.start(), m.end(), m.group(0), typ, conf, "regex", note))
    for m in SPOKEN_PHONE.finditer(text):
        hits.append(Hit(m.start(), m.end(), m.group(0), "PHONE", 0.7, "regex", "spelled-out digit string"))
    return hits
