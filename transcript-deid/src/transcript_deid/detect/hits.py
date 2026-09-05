from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Hit:
    start: int
    end: int
    text: str
    type: str
    confidence: float
    source: str
    note: str = ""
    entity: str = ""  # raw NER label, when applicable
