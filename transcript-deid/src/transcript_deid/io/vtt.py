"""WebVTT and SubRip readers/writers.

Both are parsed into one ``Segment`` per cue with ``start``/``end`` kept as
the original timestamp strings so they round-trip byte-for-byte.
"""

from __future__ import annotations

import re
from pathlib import Path

from ..models import Document, Segment
from .speakers import join_speaker, split_speaker

_TIMING_RE = re.compile(
    r"^(?P<start>\d{1,2}:\d{2}:\d{2}[.,]\d{3}|\d{1,2}:\d{2}[.,]\d{3})\s*-->\s*"
    r"(?P<end>\d{1,2}:\d{2}:\d{2}[.,]\d{3}|\d{1,2}:\d{2}[.,]\d{3})(?P<settings>.*)$"
)
_VOICE_RE = re.compile(r"^\s*<v(?:\.[\w.]+)?\s+(?P<speaker>[^>]+)>(?P<text>.*?)(?:</v>)?\s*$", re.DOTALL)


def _parse_blocks(raw: str) -> list[list[str]]:
    blocks: list[list[str]] = []
    current: list[str] = []
    for line in raw.splitlines():
        if line.strip() == "":
            if current:
                blocks.append(current)
                current = []
        else:
            current.append(line.rstrip("\r"))
    if current:
        blocks.append(current)
    return blocks


def _read_cues(path: Path, fmt: str) -> Document:
    raw = path.read_text(encoding="utf-8-sig")
    blocks = _parse_blocks(raw)
    header: list[str] = []
    segments: list[Segment] = []
    for block in blocks:
        # Find the timing line; anything before it is a cue identifier.
        timing_idx = next((i for i, l in enumerate(block) if _TIMING_RE.match(l)), None)
        if timing_idx is None:
            if not segments:  # WEBVTT header, NOTE / STYLE blocks
                header.extend(block + [""])
            continue
        m = _TIMING_RE.match(block[timing_idx])
        assert m
        cue_id = "\n".join(block[:timing_idx]) or None
        body = "\n".join(block[timing_idx + 1 :])
        speaker: str | None = None
        voice = _VOICE_RE.match(body)
        style = "plain"
        suffix = ":"
        if voice:
            speaker = voice.group("speaker").strip()
            body = voice.group("text")
            style = "voice"
        else:
            speaker, body, suffix = split_speaker(body)
            if speaker:
                style = "colon"
        segments.append(
            Segment(
                index=len(segments),
                text=body,
                speaker=speaker,
                start=m.group("start"),
                end=m.group("end"),
                meta={"cue_id": cue_id, "settings": m.group("settings"), "style": style, "suffix": suffix},
            )
        )
    return Document(source=str(path), format=fmt, segments=segments, meta={"header": "\n".join(header)})


def read_vtt(path: Path) -> Document:
    return _read_cues(path, "vtt")


def read_srt(path: Path) -> Document:
    return _read_cues(path, "srt")


def _render(doc: Document, texts: list[str], speakers: list[str | None], srt: bool) -> str:
    out: list[str] = []
    if not srt:
        header = doc.meta.get("header") or "WEBVTT\n"
        out.append(header.rstrip("\n") + "\n")
    for n, (seg, text, speaker) in enumerate(zip(doc.segments, texts, speakers), start=1):
        style = seg.meta.get("style", "plain")
        if srt:
            out.append(str(n))
        elif seg.meta.get("cue_id"):
            out.append(seg.meta["cue_id"])
        start, end = seg.start or "", seg.end or ""
        if srt:
            start, end = start.replace(".", ","), end.replace(".", ",")
        else:
            start, end = start.replace(",", "."), end.replace(",", ".")
        out.append(f"{start} --> {end}{seg.meta.get('settings', '')}")
        if style == "voice" and speaker:
            out.append(f"<v {speaker}>{text}</v>")
        else:
            out.append(join_speaker(speaker, text, seg.meta.get("suffix", ":")))
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def write_vtt(doc: Document, texts: list[str], speakers: list[str | None], out: Path) -> None:
    out.write_text(_render(doc, texts, speakers, srt=False), encoding="utf-8")


def write_srt(doc: Document, texts: list[str], speakers: list[str | None], out: Path) -> None:
    out.write_text(_render(doc, texts, speakers, srt=True), encoding="utf-8")
