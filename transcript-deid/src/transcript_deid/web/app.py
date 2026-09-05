"""Local-only review server.  Binds to 127.0.0.1 by default; no outbound calls."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel

from .. import io, report
from ..engine import Engine, apply_flags, render, residual_check
from ..models import Flag
from ..roster import Participant, Roster

STATIC = Path(__file__).parent / "static"


class DecisionIn(BaseModel):
    decision: str  # accept | reject | pending
    replacement: str | None = None
    type: str | None = None


class BulkDecisionIn(BaseModel):
    flag_ids: list[str]
    decision: str


class ManualFlagIn(BaseModel):
    segment: int
    field: str = "text"
    start: int
    end: int
    type: str
    replacement: str


class AliasIn(BaseModel):
    study_id: str
    alias: str
    first_name: str | None = None
    last_name: str | None = None


def create_app(out_dir: Path, roster_path: Path | None = None) -> FastAPI:
    app = FastAPI(title="transcript-deid review", docs_url=None, redoc_url=None)
    state: dict[str, Any] = {
        "out_dir": out_dir,
        "roster_path": roster_path,
        "roster": Roster.from_csv(roster_path) if roster_path else Roster([]),
    }

    def _sidecar(file_id: str) -> Path:
        p = out_dir / f"{file_id}{report.SIDECAR_SUFFIX}"
        if not p.exists() or p.parent != out_dir:
            raise HTTPException(404, "unknown transcript")
        return p

    @app.get("/")
    def index():
        return FileResponse(STATIC / "index.html")

    @app.get("/favicon.ico", include_in_schema=False)
    def favicon():
        return Response(status_code=204)

    @app.get("/api/files")
    def files():
        rows = []
        for sc in sorted(out_dir.glob(f"*{report.SIDECAR_SUFFIX}")):
            doc = report.load_sidecar(sc)
            s = report.summarize(doc)
            s["id"] = sc.name[: -len(report.SIDECAR_SUFFIX)]
            s["exported"] = report.output_path(out_dir, Path(doc.source)).exists()
            rows.append(s)
        return rows

    @app.get("/api/file/{file_id}")
    def file(file_id: str):
        doc = report.load_sidecar(_sidecar(file_id))
        texts, speakers = render(doc)
        d = doc.to_dict()
        d["id"] = file_id
        d["rendered"] = [{"text": t, "speaker": s} for t, s in zip(texts, speakers)]
        d["roster_ids"] = sorted(state["roster"].by_id)
        return d

    @app.post("/api/file/{file_id}/flag/{flag_id}")
    def decide(file_id: str, flag_id: str, body: DecisionIn):
        sc = _sidecar(file_id)
        doc = report.load_sidecar(sc)
        flag = next((f for f in doc.flags if f.id == flag_id), None)
        if flag is None:
            raise HTTPException(404, "unknown flag")
        if body.decision not in {"accept", "reject", "pending"}:
            raise HTTPException(400, "bad decision")
        flag.decision = body.decision  # type: ignore[assignment]
        if body.replacement is not None:
            flag.replacement = body.replacement
        if body.type is not None:
            flag.type = body.type
        report.save_sidecar(doc, sc)
        seg = doc.segments[flag.segment]
        src = seg.text if flag.field == "text" else (seg.speaker or "")
        return {"ok": True, "rendered": apply_flags(src, doc.flags_for(flag.segment, flag.field))}

    @app.post("/api/file/{file_id}/bulk")
    def bulk(file_id: str, body: BulkDecisionIn):
        sc = _sidecar(file_id)
        doc = report.load_sidecar(sc)
        ids = set(body.flag_ids)
        for f in doc.flags:
            if f.id in ids:
                f.decision = body.decision  # type: ignore[assignment]
        report.save_sidecar(doc, sc)
        return {"ok": True, "n": len(ids)}

    @app.post("/api/file/{file_id}/manual")
    def manual(file_id: str, body: ManualFlagIn):
        sc = _sidecar(file_id)
        doc = report.load_sidecar(sc)
        seg = doc.segments[body.segment]
        src = seg.text if body.field == "text" else (seg.speaker or "")
        if not (0 <= body.start < body.end <= len(src)):
            raise HTTPException(400, "bad span")
        replacement = body.replacement
        if body.type == "NAME" and replacement.strip() in {"", "[NAME]"}:
            # Next free generic tag for this transcript, recorded in name_map.
            used = [int(m.group(1)) for m in (re.match(r"\[NAME-(\d+)\]", v) for v in doc.meta.get("name_map", {}).values()) if m]
            used += [int(m.group(1)) for m in (re.match(r"\[NAME-(\d+)\]", f.replacement) for f in doc.flags) if m]
            replacement = f"[NAME-{max(used, default=0) + 1}]"
            doc.meta.setdefault("name_map", {})[src[body.start : body.end].lower()] = replacement
        f = Flag(
            segment=body.segment,
            start=body.start,
            end=body.end,
            text=src[body.start : body.end],
            type=body.type,
            replacement=replacement,
            confidence=1.0,
            source="reviewer",
            field=body.field,
            decision="accept",
            note="added by reviewer",
        )
        doc.flags.append(f)
        report.save_sidecar(doc, sc)
        return f.to_dict()

    @app.post("/api/file/{file_id}/export")
    def export(file_id: str, force: bool = False):
        sc = _sidecar(file_id)
        doc = report.load_sidecar(sc)
        texts, speakers = render(doc)
        leaks = residual_check(doc, state["roster"], texts, speakers)
        if leaks and not force:
            return JSONResponse({"ok": False, "leaks": leaks}, status_code=409)
        out = io.write(doc, texts, speakers, report.output_path(out_dir, Path(doc.source)))
        return {"ok": True, "path": str(out)}

    @app.post("/api/file/{file_id}/rerun")
    def rerun(file_id: str, nlp: bool = True):
        """Re-detect after the roster changed, keeping reviewer decisions on unchanged spans."""
        sc = _sidecar(file_id)
        old = report.load_sidecar(sc)
        engine_nlp = None
        if nlp and old.meta.get("model"):
            from ..detect.nlp import load_engine

            engine_nlp = load_engine(old.meta["model"])
        new = Engine(state["roster"], engine_nlp).process(io.read(old.source))
        prior = {(f.segment, f.field, f.start, f.end): f for f in old.flags}
        for f in new.flags:
            p = prior.get((f.segment, f.field, f.start, f.end))
            if p and p.decision != "pending":
                f.decision = p.decision
                f.replacement = p.replacement if p.type == f.type else f.replacement
        new.flags.extend(f for f in old.flags if f.source == "reviewer")
        report.save_sidecar(new, sc)
        return {"ok": True, "flags": len(new.flags)}

    @app.get("/api/roster")
    def roster():
        r: Roster = state["roster"]
        return {"path": str(state["roster_path"]) if state["roster_path"] else None, "participants": [
            {"study_id": p.study_id, "first_name": p.first_name, "last_name": p.last_name, "aliases": p.aliases}
            for p in r.participants
        ]}

    @app.post("/api/roster/alias")
    def add_alias(body: AliasIn):
        r: Roster = state["roster"]
        if body.study_id in r.by_id:
            r.add_alias(body.study_id, body.alias)
        else:
            r.add_participant(Participant(body.study_id, body.first_name or body.alias, body.last_name or "", []))
        if state["roster_path"]:
            r.to_csv(state["roster_path"])
        return {"ok": True, "size": len(r)}

    return app
