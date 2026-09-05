"""Transcript readers and writers.  Each format round-trips ``Document``."""

from __future__ import annotations

from pathlib import Path

from ..models import Document
from . import docx as _docx
from . import text as _text
from . import vtt as _vtt

READERS = {
    ".docx": _docx.read,
    ".vtt": _vtt.read_vtt,
    ".srt": _vtt.read_srt,
    ".txt": _text.read,
}

WRITERS = {
    "docx": _docx.write,
    "vtt": _vtt.write_vtt,
    "srt": _vtt.write_srt,
    "txt": _text.write,
}

SUPPORTED_SUFFIXES = tuple(READERS)


def read(path: str | Path) -> Document:
    path = Path(path)
    try:
        reader = READERS[path.suffix.lower()]
    except KeyError as e:
        raise ValueError(f"Unsupported transcript format: {path.suffix}") from e
    return reader(path)


def write(doc: Document, texts: list[str], speakers: list[str | None], out_path: str | Path) -> Path:
    """Write ``doc`` with per-segment replacement ``texts``/``speakers`` to ``out_path``."""
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    WRITERS[doc.format](doc, texts, speakers, out_path)
    return out_path
