"""Speaker-label parsing shared by all readers.

Handles the common transcription-service layouts:

    Interviewer: text
    Jane Doe (00:01:23): text          (Otter.ai)
    Jane Doe 00:01:23 text             (Otter.ai, older)
    JANE DOE: text
    [Jane]: text
    <v Jane Doe>text</v>               (WebVTT voice span, handled in vtt.py)
"""

from __future__ import annotations

import re

# Words that mark a role rather than a person; never treated as names.
ROLE_LABELS = {
    "interviewer",
    "interviewee",
    "participant",
    "respondent",
    "researcher",
    "moderator",
    "facilitator",
    "clinician",
    "therapist",
    "counselor",
    "counsellor",
    "patient",
    "client",
    "speaker",
    "unknown",
    "unidentified",
    "i",
    "p",
    "r",
    "q",
    "a",
}

_TIMESTAMP = r"(?P<ts>\(?\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,3})?\)?)"
_LABEL = r"\[?(?P<speaker>[A-Za-z][A-Za-z.'\- ]{0,40}?(?:\s?\d{1,2})?)\]?"
SPEAKER_RE = re.compile(
    rf"^\s*{_LABEL}\s*(?:{_TIMESTAMP})?\s*:\s*(?P<text>.*)$",
    re.DOTALL,
)
# Otter "Name  00:01" without a colon after the timestamp.
SPEAKER_TS_RE = re.compile(
    rf"^\s*{_LABEL}\s+{_TIMESTAMP}\s+(?P<text>.*)$",
    re.DOTALL,
)


def split_speaker(line: str) -> tuple[str | None, str, str]:
    """Return (speaker, text, suffix).

    ``speaker`` is ``None`` when no label is found.  ``suffix`` is whatever
    sat between the name and the text (an Otter timestamp, the colon) so the
    writer can put the line back together exactly.
    """
    # Timestamp-without-colon first, so "Name 00:05 text" is not read as
    # speaker "Name 00" followed by ":05 text".
    for style, rx in (("ts", SPEAKER_TS_RE), ("colon", SPEAKER_RE)):
        m = rx.match(line)
        if m:
            speaker = m.group("speaker").strip()
            text = m.group("text")
            # Avoid swallowing ordinary sentences such as "Note: bring ID".
            if len(speaker.split()) <= 4 and not speaker.endswith("."):
                ts = m.group("ts") or ""
                suffix = (f" {ts}:" if ts else ":") if style == "colon" else f" {ts}"
                return speaker, text, suffix
    return None, line, ""


def is_role_label(speaker: str | None) -> bool:
    if not speaker:
        return True
    core = re.sub(r"[\d\s_.\-]+$", "", speaker).strip().lower()
    return core in ROLE_LABELS


def join_speaker(speaker: str | None, text: str, suffix: str = ":") -> str:
    if not speaker:
        return text
    return f"{speaker}{suffix} {text}"
