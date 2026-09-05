"""Plain-text transcripts: one utterance per line or blank-line separated."""

from __future__ import annotations

from pathlib import Path

from ..models import Document, Segment
from .speakers import join_speaker, split_speaker


def read(path: Path) -> Document:
    raw = path.read_text(encoding="utf-8-sig")
    segments: list[Segment] = []
    for i, line in enumerate(raw.splitlines()):
        speaker, text, suffix = split_speaker(line)
        segments.append(Segment(index=i, text=text, speaker=speaker, meta={"blank": not line.strip(), "suffix": suffix}))
    return Document(source=str(path), format="txt", segments=segments)


def write(doc: Document, texts: list[str], speakers: list[str | None], out: Path) -> None:
    lines = [join_speaker(sp, tx, seg.meta.get("suffix", ":")) for seg, sp, tx in zip(doc.segments, speakers, texts)]
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
