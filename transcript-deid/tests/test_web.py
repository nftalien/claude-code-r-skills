from pathlib import Path

from fastapi.testclient import TestClient

from transcript_deid import io, report
from transcript_deid.engine import Engine
from transcript_deid.web.app import create_app


def setup(tmp_path: Path, roster):
    src = tmp_path / "t.txt"
    src.write_text("Interviewer: Hi Maria.\nMaria Lopez: I saw Jonny at 1420 Maple Avenue.\n", encoding="utf-8")
    out = tmp_path / "deid"
    out.mkdir()
    doc = Engine(roster, None).process(io.read(src))
    report.save_sidecar(doc, report.sidecar_path(out, src))
    rp = tmp_path / "roster.csv"
    roster.to_csv(rp)
    return TestClient(create_app(out, rp)), out


def test_review_flow(tmp_path, roster):
    client, out = setup(tmp_path, roster)
    files = client.get("/api/files").json()
    assert len(files) == 1 and files[0]["id"] == "t.txt"

    d = client.get("/api/file/t.txt").json()
    assert d["rendered"][1]["speaker"] == "FEAR-0102"
    jonny = next(f for f in d["flags"] if f["text"] == "Jonny")

    r = client.post(f"/api/file/t.txt/flag/{jonny['id']}", json={"decision": "reject"})
    assert r.status_code == 200 and "Jonny" in r.json()["rendered"]

    # export must refuse: a roster name now survives
    r = client.post("/api/file/t.txt/export")
    assert r.status_code == 409 and r.json()["leaks"][0]["text"] == "Jonny"

    client.post(f"/api/file/t.txt/flag/{jonny['id']}", json={"decision": "accept"})
    r = client.post("/api/file/t.txt/export")
    assert r.status_code == 200
    assert (out / "t.deid.txt").read_text() == "Interviewer: Hi FEAR-0102.\nFEAR-0102: I saw FEAR-0117 at [ADDRESS].\n"


def test_manual_flag_and_alias(tmp_path, roster):
    client, out = setup(tmp_path, roster)
    r = client.post("/api/file/t.txt/manual", json={"segment": 1, "start": 2, "end": 5, "type": "NAME", "replacement": "[NAME-9]"})
    assert r.status_code == 200 and r.json()["text"] == "saw"
    r = client.post("/api/file/t.txt/manual", json={"segment": 1, "start": 0, "end": 1, "type": "NAME", "replacement": "[NAME]"})
    assert r.json()["replacement"] == "[NAME-10]"  # next after the explicit [NAME-9]
    r = client.post("/api/roster/alias", json={"study_id": "FEAR-0117", "alias": "Jonners"})
    assert r.json()["size"] == 3
    assert "Jonners" in (tmp_path / "roster.csv").read_text()
    r = client.post("/api/file/t.txt/rerun", params={"nlp": "false"})
    assert r.status_code == 200
    d = client.get("/api/file/t.txt").json()
    assert any(f["source"] == "reviewer" for f in d["flags"])


def test_path_traversal_rejected(tmp_path, roster):
    client, _ = setup(tmp_path, roster)
    assert client.get("/api/file/..%2Ft").status_code in (404, 422)
