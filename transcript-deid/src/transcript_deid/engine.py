"""Orchestrates detection, consistent tagging and export for one document."""

from __future__ import annotations

import datetime as _dt
import logging
import re
from collections.abc import Iterable

from .detect.garbled import find_garbled
from .detect.hits import Hit
from .detect.indirect import find_indirect
from .detect.phi import find_phi
from .io.speakers import is_role_label
from .models import Document, Flag, Segment
from .roster import Roster

log = logging.getLogger(__name__)

# Priority when two detectors overlap: higher wins.
# Structured identifiers outrank PARTICIPANT so "jon.w@x.org" is one
# [EMAIL], not a study ID glued to a domain.
_PRIORITY = {
    "SSN": 120,
    "MRN": 120,
    "EMAIL": 115,
    "PHONE": 115,
    "URL": 110,
    "ADDRESS": 110,
    "ID_NUMBER": 105,
    "PARTICIPANT": 100,
    "NAME": 70,
    "DATE": 60,
    "AGE": 60,
    "ZIP": 50,
    "GARBLED": 48,  # gibberish beats NER guesses (ORG/LOCATION) but not real PHI
    "LOCATION": 45,
    "ORGANIZATION": 40,
    "INDIRECT": 10,
}

TAG = {
    "NAME": "[NAME-{n}]",
    "DATE": "[DATE]",
    "AGE": "[AGE>89]",
    "PHONE": "[PHONE]",
    "EMAIL": "[EMAIL]",
    "ADDRESS": "[ADDRESS]",
    "ZIP": "[ZIP]",
    "LOCATION": "[LOCATION]",
    "ORGANIZATION": "[ORGANIZATION]",
    "SSN": "[SSN]",
    "MRN": "[MRN]",
    "URL": "[URL]",
    "ID_NUMBER": "[ID-NUMBER]",
}

_HONORIFIC = re.compile(r"^(?:mr|mrs|ms|miss|dr|prof|coach|pastor|aunt|uncle|grandma|grandpa|nana|papa)\.?\s+", re.I)


class NameRegistry:
    """Consistent [NAME-n] tags within one transcript.

    A first name seen alone links to a full name seen earlier ("Maria" ->
    "Maria Lopez") so the same person always gets the same tag.
    """

    def __init__(self) -> None:
        self._tags: dict[str, int] = {}
        self._first_to_key: dict[str, str] = {}
        self._next = 1

    @staticmethod
    def normalize(name: str) -> str:
        n = name.strip().rstrip(".,;:!?")
        n = re.sub(r"(?:'s|’s)$", "", n)
        n = _HONORIFIC.sub("", n)
        return re.sub(r"\s+", " ", n).lower()

    def tag(self, name: str) -> str:
        key = self.normalize(name)
        if not key:
            return "[NAME]"
        if key not in self._tags:
            parts = key.split()
            if len(parts) == 1 and key in self._first_to_key:
                key = self._first_to_key[key]
            elif len(parts) == 1:
                # single token: maybe a last name of someone we already have
                for full in list(self._tags):
                    if full.split()[-1] == key and len(full.split()) > 1:
                        key = full
                        break
            if key not in self._tags:
                self._tags[key] = self._next
                self._next += 1
                if len(parts) > 1:
                    self._first_to_key.setdefault(parts[0], key)
        return f"[NAME-{self._tags[key]}]"

    def knows(self, name: str) -> bool:
        """True if this text was already tagged as a person in this transcript."""
        key = self.normalize(name)
        return bool(key) and (key in self._tags or key in self._first_to_key or any(k.split()[-1] == key for k in self._tags))

    @property
    def mapping(self) -> dict[str, str]:
        return {k: f"[NAME-{v}]" for k, v in self._tags.items()}


class Engine:
    def __init__(
        self,
        roster: Roster | None = None,
        nlp=None,
        *,
        fuzzy: bool = True,
        garbled: bool = True,
        indirect: bool = True,
    ):
        self.roster = roster or Roster([])
        self.nlp = nlp
        self.fuzzy = fuzzy
        self.garbled = garbled
        self.indirect = indirect

    # ---------------------------------------------------------------- detect
    def _hits_for_text(self, text: str, seg: Segment) -> list[Hit]:
        hits: list[Hit] = []
        for m in self.roster.find(text, fuzzy=self.fuzzy):
            hits.append(
                Hit(m.start, m.end, m.text, "PARTICIPANT", m.confidence, "roster", f"{m.kind} match -> {m.participant.study_id}")
            )
            hits[-1].entity = m.participant.study_id
        hits.extend(find_phi(text))
        if self.nlp is not None:
            hits.extend(self.nlp.analyze(text))
        if self.garbled:
            hits.extend(
                find_garbled(text, start=seg.start, end=seg.end, is_oov=self.nlp.is_oov if self.nlp else None)
            )
        if self.indirect:
            hits.extend(find_indirect(text))
        return hits

    def _hits_for_speaker(self, speaker: str) -> list[Hit]:
        if is_role_label(speaker):
            return []
        hits: list[Hit] = []
        for m in self.roster.find(speaker, fuzzy=self.fuzzy):
            h = Hit(m.start, m.end, m.text, "PARTICIPANT", m.confidence, "roster", f"{m.kind} match -> {m.participant.study_id}")
            h.entity = m.participant.study_id
            hits.append(h)
        if not hits:
            # A non-role speaker label is a name by construction.
            core = re.sub(r"\s*\d+$", "", speaker).strip()
            if core:
                hits.append(Hit(0, len(core), core, "NAME", 0.9, "heuristic", "speaker label"))
        return hits

    # ------------------------------------------------------------- resolve
    @staticmethod
    def _resolve_overlaps(hits: Iterable[Hit]) -> list[Hit]:
        """Keep the highest-priority hit in each overlapping cluster.

        INDIRECT hits never suppress anything and are never suppressed; they
        are advisory.  GARBLED spans keep going if they overlap a PHI hit
        (the PHI hit wins for redaction, garbled is still reported).
        """
        advisory = [h for h in hits if h.type == "INDIRECT"]
        rest = sorted(
            (h for h in hits if h.type != "INDIRECT"),
            key=lambda h: (-_PRIORITY.get(h.type, 0), -h.confidence, -(h.end - h.start), h.start),
        )
        kept: list[Hit] = []
        for h in rest:
            if any(h.start < k.end and k.start < h.end for k in kept):
                continue
            kept.append(h)
        # Merge exact-duplicate spans from multiple sources into one with best confidence.
        return sorted(kept + advisory, key=lambda h: (h.start, h.end))

    # ---------------------------------------------------------------- run
    def process(self, doc: Document) -> Document:
        names = NameRegistry()
        flags: list[Flag] = []
        # Pre-seed the name registry with speaker labels so [NAME-1] is a speaker.
        for seg in doc.segments:
            if seg.speaker and not is_role_label(seg.speaker) and not self.roster.find(seg.speaker, fuzzy=False):
                names.tag(re.sub(r"\s*\d+$", "", seg.speaker))

        for seg in doc.segments:
            if seg.speaker:
                for h in self._resolve_overlaps(self._hits_for_speaker(seg.speaker)):
                    flags.append(self._to_flag(h, seg.index, "speaker", names))
            if seg.text.strip():
                hits = self._hits_for_text(seg.text, seg)
                # NER sometimes reads a name it has already seen as a place
                # ("Diego" -> GPE).  Once a string is a person, it stays one.
                seen_here = {names.normalize(h.text) for h in hits if h.type == "NAME"}
                seen_here |= {k.split()[0] for k in seen_here if " " in k}
                for h in hits:
                    if h.type in {"LOCATION", "ORGANIZATION"} and (names.knows(h.text) or names.normalize(h.text) in seen_here):
                        h.type, h.note = "NAME", f"retyped from {h.type}: known name"
                for h in self._resolve_overlaps(hits):
                    flags.append(self._to_flag(h, seg.index, "text", names))

        doc.flags = flags
        doc.meta.update(
            {
                "processed_at": _dt.datetime.now().isoformat(timespec="seconds"),
                "model": getattr(self.nlp, "model_name", None),
                "roster_size": len(self.roster),
                "name_map": names.mapping,  # generic tags only; never contains study IDs
            }
        )
        return doc

    def _to_flag(self, h: Hit, seg_index: int, field: str, names: NameRegistry) -> Flag:
        if h.type == "PARTICIPANT":
            replacement = h.entity
        elif h.type == "NAME":
            replacement = names.tag(h.text)
        elif h.type == "GARBLED":
            replacement = f"[GARBLED: {h.text}]"
        elif h.type == "INDIRECT":
            replacement = h.text
        else:
            replacement = TAG.get(h.type, f"[{h.type}]")
        decision = "accept" if (h.confidence >= 0.9 and h.type != "INDIRECT") else "pending"
        return Flag(
            segment=seg_index,
            start=h.start,
            end=h.end,
            text=h.text,
            type=h.type,
            replacement=replacement,
            confidence=round(h.confidence, 2),
            source=h.source,
            field=field,
            decision=decision,
            note=h.note,
        )


# ------------------------------------------------------------------ export
def apply_flags(text: str, flags: list[Flag]) -> str:
    """Return ``text`` with every flag that redacts applied, right-to-left."""
    active = sorted((f for f in flags if f.redacts), key=lambda f: f.start, reverse=True)
    out = text
    last_start = len(text) + 1
    for f in active:
        if f.end > last_start:  # overlap with an already-applied flag
            continue
        out = out[: f.start] + f.replacement + out[f.end :]
        last_start = f.start
    return out


def render(doc: Document) -> tuple[list[str], list[str | None]]:
    """Per-segment (text, speaker) after applying current decisions."""
    texts: list[str] = []
    speakers: list[str | None] = []
    for seg in doc.segments:
        texts.append(apply_flags(seg.text, doc.flags_for(seg.index, "text")))
        if seg.speaker is None:
            speakers.append(None)
        else:
            speakers.append(apply_flags(seg.speaker, doc.flags_for(seg.index, "speaker")))
    return texts, speakers


def residual_check(doc: Document, roster: Roster, texts: list[str], speakers: list[str | None]) -> list[dict]:
    """Scan the *rendered* output for roster names that slipped through.

    Returns a list of leaks; export should refuse when non-empty.
    """
    leaks: list[dict] = []
    for seg, text, speaker in zip(doc.segments, texts, speakers):
        for label, s in (("text", text), ("speaker", speaker or "")):
            for m in roster.find(s, fuzzy=False):
                if m.kind in {"initials"}:
                    continue
                leaks.append({"segment": seg.index, "field": label, "text": m.text, "study_id": m.participant.study_id})
    return leaks
