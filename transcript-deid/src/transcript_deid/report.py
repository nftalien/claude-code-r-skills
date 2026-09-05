"""Sidecar JSON per transcript and a batch summary CSV."""

from __future__ import annotations

import csv
import json
from collections import Counter
from pathlib import Path

from .models import Document

SIDECAR_SUFFIX = ".deid.json"


def sidecar_path(out_dir: Path, source: Path) -> Path:
    # Full filename, so a.docx and a.vtt in one folder do not collide.
    return out_dir / f"{source.name}{SIDECAR_SUFFIX}"


def output_path(out_dir: Path, source: Path) -> Path:
    return out_dir / f"{source.stem}.deid{source.suffix.lower()}"


def save_sidecar(doc: Document, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc.to_dict(), indent=1, ensure_ascii=False), encoding="utf-8")


def load_sidecar(path: Path) -> Document:
    return Document.from_dict(json.loads(path.read_text(encoding="utf-8")))


def summarize(doc: Document) -> dict:
    by_type = Counter(f.type for f in doc.flags)
    by_decision = Counter(f.decision for f in doc.flags)
    return {
        "file": Path(doc.source).name,
        "format": doc.format,
        "segments": len(doc.segments),
        "flags": len(doc.flags),
        "pending": by_decision.get("pending", 0),
        "accepted": by_decision.get("accept", 0),
        "rejected": by_decision.get("reject", 0),
        **{f"n_{t.lower()}": by_type.get(t, 0) for t in sorted(by_type)},
        "processed_at": doc.meta.get("processed_at"),
        "model": doc.meta.get("model"),
    }


def write_summary(docs: list[Document], path: Path) -> None:
    rows = [summarize(d) for d in docs]
    cols: list[str] = []
    for r in rows:
        for k in r:
            if k not in cols:
                cols.append(k)
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow(r)


def review_text(doc: Document) -> str:
    """Human-readable flag list, one per line, for quick terminal review."""
    lines = [f"# {doc.source}  ({len(doc.flags)} flags)"]
    for f in sorted(doc.flags, key=lambda f: (f.segment, f.start)):
        seg = doc.segments[f.segment]
        where = seg.start or f"¶{f.segment + 1}"
        lines.append(
            f"{where:>12}  {f.type:<13} {f.confidence:>4.2f} {f.decision:<8} {f.text!r} -> {f.replacement!r}"
            + (f"  ({f.note})" if f.note else "")
        )
    return "\n".join(lines)
