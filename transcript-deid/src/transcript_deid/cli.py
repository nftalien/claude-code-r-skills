"""Command-line interface.

    transcript-deid run  INPUT... --roster roster.csv --out deid/
    transcript-deid export deid/            # apply reviewed decisions
    transcript-deid review deid/            # open the local review UI
    transcript-deid check deid/             # list what is still pending
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from . import __version__, io, report
from .engine import Engine, render, residual_check
from .roster import Roster

log = logging.getLogger("transcript_deid")


def _collect_inputs(paths: list[str]) -> list[Path]:
    files: list[Path] = []
    for p in paths:
        path = Path(p)
        if path.is_dir():
            files.extend(sorted(f for f in path.rglob("*") if f.suffix.lower() in io.SUPPORTED_SUFFIXES and not f.name.endswith(".deid" + f.suffix)))
        elif path.suffix.lower() in io.SUPPORTED_SUFFIXES:
            files.append(path)
        else:
            log.warning("skipping unsupported file %s", path)
    return files


def _load_nlp(args):
    if args.no_nlp:
        return None
    from .detect.nlp import load_engine

    return load_engine(args.model, use_presidio=not args.no_presidio)


def cmd_run(args: argparse.Namespace) -> int:
    roster = Roster.from_csv(args.roster) if args.roster else Roster([])
    if not roster:
        log.warning("no roster supplied: participant names will get generic [NAME-n] tags, not study IDs")
    nlp = _load_nlp(args)
    engine = Engine(roster, nlp, fuzzy=not args.no_fuzzy, garbled=not args.no_garbled, indirect=not args.no_indirect)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    docs = []
    for src in _collect_inputs(args.inputs):
        log.info("processing %s", src)
        doc = engine.process(io.read(src))
        report.save_sidecar(doc, report.sidecar_path(out_dir, src))
        docs.append(doc)
        if args.print:
            print(report.review_text(doc))
        if not args.no_export:
            _export_one(doc, roster, out_dir, src, force=args.force)
    report.write_summary(docs, out_dir / "summary.csv")
    pending = sum(1 for d in docs for f in d.flags if f.decision == "pending")
    print(f"{len(docs)} transcript(s) processed -> {out_dir}  ({pending} flags pending review)")
    return 0


def _export_one(doc, roster: Roster, out_dir: Path, src: Path, *, force: bool = False) -> Path | None:
    texts, speakers = render(doc)
    leaks = residual_check(doc, roster, texts, speakers)
    if leaks and not force:
        log.error("%s: %d roster name(s) still present after redaction; export refused (use --force to override)", src.name, len(leaks))
        for leak in leaks[:10]:
            log.error("  segment %s [%s]: %r", leak["segment"], leak["field"], leak["text"])
        return None
    out = report.output_path(out_dir, src)
    io.write(doc, texts, speakers, out)
    return out


def _sidecars(out_dir: Path) -> list[Path]:
    return sorted(out_dir.glob(f"*{report.SIDECAR_SUFFIX}"))


def cmd_export(args: argparse.Namespace) -> int:
    out_dir = Path(args.out)
    roster = Roster.from_csv(args.roster) if args.roster else Roster([])
    docs = []
    n_written = 0
    for sc in _sidecars(out_dir):
        doc = report.load_sidecar(sc)
        docs.append(doc)
        pending = [f for f in doc.flags if f.decision == "pending"]
        if pending and args.require_review:
            log.error("%s: %d flag(s) still pending; export refused", sc.name, len(pending))
            continue
        if _export_one(doc, roster, out_dir, Path(doc.source), force=args.force):
            n_written += 1
    report.write_summary(docs, out_dir / "summary.csv")
    print(f"exported {n_written}/{len(docs)} transcript(s) -> {out_dir}")
    return 0 if n_written == len(docs) else 1


def cmd_check(args: argparse.Namespace) -> int:
    out_dir = Path(args.out)
    total = 0
    for sc in _sidecars(out_dir):
        doc = report.load_sidecar(sc)
        pending = [f for f in doc.flags if f.decision == "pending"]
        total += len(pending)
        print(f"{Path(doc.source).name}: {len(doc.flags)} flags, {len(pending)} pending")
        if args.verbose:
            for f in pending:
                seg = doc.segments[f.segment]
                print(f"   {seg.start or '¶' + str(f.segment + 1):>10} {f.type:<12} {f.confidence:.2f} {f.text!r}")
    return 1 if total else 0


def cmd_review(args: argparse.Namespace) -> int:
    import uvicorn

    from .web.app import create_app

    app = create_app(Path(args.out), roster_path=Path(args.roster) if args.roster else None)
    print(f"Review UI: http://{args.host}:{args.port}   (Ctrl+C to stop)")
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="transcript-deid", description="Offline transcript de-identification.")
    p.add_argument("--version", action="version", version=__version__)
    p.add_argument("-v", "--verbose", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)

    run = sub.add_parser("run", help="detect, redact and write sidecars for transcripts")
    run.add_argument("inputs", nargs="+", help="transcript files or folders (.docx .vtt .srt .txt)")
    run.add_argument("--roster", help="participant roster CSV (study_id, first_name, last_name, aliases)")
    run.add_argument("--out", default="deid", help="output folder (default: ./deid)")
    run.add_argument("--model", default="en_core_web_lg", help="spaCy model name (installed offline)")
    run.add_argument("--no-nlp", action="store_true", help="regex + roster only; skip spaCy/Presidio")
    run.add_argument("--no-presidio", action="store_true", help="spaCy NER only, no Presidio recognisers")
    run.add_argument("--no-fuzzy", action="store_true", help="disable fuzzy roster matching")
    run.add_argument("--no-garbled", action="store_true")
    run.add_argument("--no-indirect", action="store_true")
    run.add_argument("--no-export", action="store_true", help="write sidecars only; export after review")
    run.add_argument("--force", action="store_true", help="export even if a roster name survives redaction")
    run.add_argument("--print", action="store_true", help="print the flag list to the terminal")
    run.set_defaults(func=cmd_run)

    exp = sub.add_parser("export", help="apply reviewed decisions from sidecars and write outputs")
    exp.add_argument("--out", default="deid")
    exp.add_argument("--roster")
    exp.add_argument("--require-review", action="store_true", help="refuse files with pending flags")
    exp.add_argument("--force", action="store_true")
    exp.set_defaults(func=cmd_export)

    chk = sub.add_parser("check", help="list pending flags per transcript (exit 1 if any)")
    chk.add_argument("--out", default="deid")
    chk.set_defaults(func=cmd_check)

    rev = sub.add_parser("review", help="open the local browser review UI")
    rev.add_argument("--out", default="deid")
    rev.add_argument("--roster")
    rev.add_argument("--host", default="127.0.0.1")
    rev.add_argument("--port", type=int, default=8765)
    rev.set_defaults(func=cmd_review)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(levelname)s %(message)s")
    return args.func(args)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
