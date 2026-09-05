"""Core data structures shared by readers, detectors, the engine and the UI."""

from __future__ import annotations

import uuid
from dataclasses import asdict, dataclass
from dataclasses import field as dc_field
from typing import Any, Literal

FlagType = Literal[
    "PARTICIPANT",
    "NAME",
    "DATE",
    "AGE",
    "PHONE",
    "EMAIL",
    "ADDRESS",
    "ZIP",
    "LOCATION",
    "ORGANIZATION",
    "SSN",
    "MRN",
    "URL",
    "ID_NUMBER",
    "GARBLED",
    "INDIRECT",
]

Decision = Literal["accept", "reject", "pending"]

# Flag types that are redacted on export unless a reviewer rejects them.
REDACTED_BY_DEFAULT: frozenset[str] = frozenset(
    {
        "PARTICIPANT",
        "NAME",
        "DATE",
        "AGE",
        "PHONE",
        "EMAIL",
        "ADDRESS",
        "ZIP",
        "LOCATION",
        "ORGANIZATION",
        "SSN",
        "MRN",
        "URL",
        "ID_NUMBER",
        "GARBLED",
    }
)


@dataclass
class Segment:
    """One unit of transcript text: a paragraph (docx) or a cue (vtt/srt)."""

    index: int
    text: str
    speaker: str | None = None
    start: str | None = None  # timestamp string, cues only
    end: str | None = None
    meta: dict[str, Any] = dc_field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Segment":
        return cls(**d)


@dataclass
class Flag:
    """A span inside a segment that a detector wants a human to look at.

    ``start``/``end`` are character offsets into ``Segment.text`` (not the
    speaker label).  ``field`` is "text" or "speaker" so speaker labels can
    be redacted too.
    """

    segment: int
    start: int
    end: int
    text: str
    type: str
    replacement: str
    confidence: float
    source: str  # roster | ner | regex | garbled | heuristic
    field: str = "text"
    decision: Decision = "pending"
    note: str = ""
    id: str = dc_field(default_factory=lambda: uuid.uuid4().hex[:10])

    @property
    def redacts(self) -> bool:
        """Whether this flag changes the exported text under its current decision."""
        if self.decision == "reject":
            return False
        if self.decision == "accept":
            return True
        return self.type in REDACTED_BY_DEFAULT

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Flag":
        return cls(**d)


@dataclass
class Document:
    """A parsed transcript plus everything the engine learned about it."""

    source: str
    format: str  # docx | vtt | srt | txt
    segments: list[Segment]
    flags: list[Flag] = dc_field(default_factory=list)
    meta: dict[str, Any] = dc_field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "format": self.format,
            "meta": self.meta,
            "segments": [s.to_dict() for s in self.segments],
            "flags": [f.to_dict() for f in self.flags],
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Document":
        return cls(
            source=d["source"],
            format=d["format"],
            meta=d.get("meta", {}),
            segments=[Segment.from_dict(s) for s in d["segments"]],
            flags=[Flag.from_dict(f) for f in d.get("flags", [])],
        )

    def flags_for(self, segment: int, field: str = "text") -> list[Flag]:
        return [f for f in self.flags if f.segment == segment and f.field == field]
