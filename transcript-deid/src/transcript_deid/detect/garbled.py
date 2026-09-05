"""Heuristics for transcription noise.

A transcript segment is flagged GARBLED when it contains:

* transcriber markers: [inaudible], (unintelligible), [crosstalk], [?], ***
* the same token repeated three or more times in a row
* a run of words the language model has never seen (out-of-vocabulary)
* mostly non-alphabetic characters
* cue timing that implies an implausible speaking rate (VTT/SRT only)

Each heuristic yields a span so the reviewer sees exactly what tripped it.
"""

from __future__ import annotations

import re
from collections.abc import Callable

from .hits import Hit

MARKER_RE = re.compile(
    r"[\[(](?:\s*(?:inaudible|unintelligible|indistinct|unclear|crosstalk|cross-talk|"
    r"overlapping|garbled|static|noise|laughs?|laughter|pause|silence|\?+|\.{2,}|_{2,})\s*"
    r"(?:\d{1,2}:\d{2}(?::\d{2})?)?\s*)[\])]",
    re.I,
)
STAR_RE = re.compile(r"\*{2,}|\?{2,}|_{3,}|(?:\s—\s?){2,}|\bxx+\b", re.I)
REPEAT_RE = re.compile(r"\b(\w+)(?:[\s,]+\1\b){2,}", re.I)
NONALPHA_RE = re.compile(r"[^A-Za-z\s]")
WORD_RE = re.compile(r"[A-Za-z][A-Za-z'\-]*")
FRAGMENT_RE = re.compile(r"(?:\b\w{1,2}-\s?){3,}")  # "I- I- I- I"

BACKCHANNEL = {"mm", "mhm", "mm-hmm", "uh", "um", "uh-huh", "hmm", "hm", "yeah", "ok", "okay", "yep", "nah", "huh", "oh", "ah", "eh"}


def _ts_seconds(ts: str | None) -> float | None:
    if not ts:
        return None
    ts = ts.replace(",", ".")
    parts = ts.split(":")
    try:
        parts_f = [float(p) for p in parts]
    except ValueError:
        return None
    if len(parts_f) == 3:
        return parts_f[0] * 3600 + parts_f[1] * 60 + parts_f[2]
    if len(parts_f) == 2:
        return parts_f[0] * 60 + parts_f[1]
    return None


def find_garbled(
    text: str,
    *,
    start: str | None = None,
    end: str | None = None,
    is_oov: Callable[[str], bool] | None = None,
    oov_min_run: int = 3,
    oov_window: int = 6,
    oov_ratio: float = 0.5,
) -> list[Hit]:
    hits: list[Hit] = []

    for m in MARKER_RE.finditer(text):
        hits.append(Hit(m.start(), m.end(), m.group(0), "GARBLED", 0.95, "garbled", "transcriber marker"))
    for m in STAR_RE.finditer(text):
        hits.append(Hit(m.start(), m.end(), m.group(0), "GARBLED", 0.8, "garbled", "placeholder characters"))
    for m in REPEAT_RE.finditer(text):
        if m.group(1).lower() not in {"no", "yes", "ha", "la", "na"}:
            hits.append(Hit(m.start(), m.end(), m.group(0), "GARBLED", 0.7, "garbled", "repeated token"))
    for m in FRAGMENT_RE.finditer(text):
        hits.append(Hit(m.start(), m.end(), m.group(0), "GARBLED", 0.5, "garbled", "stutter/fragment run"))

    words = list(WORD_RE.finditer(text))
    if words:
        letters = sum(len(w.group(0)) for w in words)
        stripped = text.strip()
        if len(stripped) >= 8 and letters / max(len(stripped), 1) < 0.4:
            hits.append(Hit(0, len(text), text, "GARBLED", 0.6, "garbled", "mostly non-alphabetic"))

    if is_oov is not None and words:
        # Sliding window: flag a window where >= oov_ratio of tokens are OOV.
        oov_flags = [is_oov(w.group(0)) and w.group(0).lower() not in BACKCHANNEL and len(w.group(0)) > 2 for w in words]
        i = 0
        n = len(words)
        while i < n:
            if oov_flags[i]:
                j = min(i + oov_window, n)
                window = oov_flags[i:j]
                if sum(window) >= oov_min_run and sum(window) / len(window) >= oov_ratio:
                    # extend to the last OOV token in the window
                    last = i + max(k for k, v in enumerate(window) if v)
                    s, e = words[i].start(), words[last].end()
                    hits.append(Hit(s, e, text[s:e], "GARBLED", 0.55, "garbled", "run of unrecognised words"))
                    i = last + 1
                    continue
            i += 1

    s_sec, e_sec = _ts_seconds(start), _ts_seconds(end)
    if s_sec is not None and e_sec is not None and e_sec > s_sec and words:
        rate = len(words) / (e_sec - s_sec)
        if rate > 7 and len(words) >= 4:
            hits.append(Hit(0, len(text), text, "GARBLED", 0.5, "garbled", f"{rate:.1f} words/sec in cue timing"))

    return _merge(hits)


def _merge(hits: list[Hit]) -> list[Hit]:
    hits.sort(key=lambda h: (h.start, -(h.end - h.start)))
    out: list[Hit] = []
    for h in hits:
        if out and h.start < out[-1].end:
            prev = out[-1]
            if h.end > prev.end:
                prev.end = h.end
            prev.confidence = max(prev.confidence, h.confidence)
            if h.note and h.note not in prev.note:
                prev.note = f"{prev.note}; {h.note}" if prev.note else h.note
            continue
        out.append(h)
    return out
