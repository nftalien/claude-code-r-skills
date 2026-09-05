# transcript-deid

Offline de-identification for interview transcripts. It replaces participant
names with study IDs, redacts other protected health information (PHI),
flags garbled transcription, and gives you a local browser page to review
every decision before anything is exported.

Nothing leaves the machine. After a one-time install it needs no network:
the spaCy language model ships as a pip package, Microsoft Presidio runs
locally, and the review UI binds to `127.0.0.1`.

## Install (once, with internet)

```bash
./install.sh          # macOS / Linux
.\install.ps1         # Windows PowerShell
```

Both scripts run `uv sync`, which creates `.venv/` with Python packages and
the `en_core_web_lg` model (about 600 MB on disk). The machine can be
air-gapped afterwards.

## Workflow

```bash
# 1. Detect + redact + write sidecars
uv run transcript-deid run transcripts/ --roster roster.csv --out deid/

# 2. Review in the browser (optional but recommended)
uv run transcript-deid review --out deid/ --roster roster.csv
#    -> http://127.0.0.1:8765

# 3. Re-export after review (the UI's Export button does the same)
uv run transcript-deid export --out deid/ --roster roster.csv --require-review

# See what is still pending
uv run transcript-deid check --out deid/
```

Input formats: `.docx`, `.vtt` (WebVTT, incl. `<v Name>` voice tags),
`.srt`, `.txt`. Outputs keep the same format: `name.deid.docx`, `name.deid.vtt`, etc.

Each transcript also gets a `name.deid.json` sidecar listing every flag
(segment, offsets, type, replacement, confidence, source, decision, note)
and the batch gets a `summary.csv`.

### The roster

`roster.csv` is the only key linking names to IDs. Keep it where PHI is
allowed to live; never ship it with the outputs.

```csv
study_id,first_name,last_name,aliases
FEAR-0102,Maria,Lopez,Mari|M. Lopez
FEAR-0117,Jonathan,Whitfield,Jon|Jonny
```

Extra columns are ignored, so a REDCap export works as long as the header
has `study_id` (case-insensitive). Aliases are separated by `|` or `;`.
Participants become their study ID wherever the roster matches (full name,
first name, last name, initials, aliases, possessives, and fuzzy spelling
variants such as "Jonathon"). Everyone else becomes `[NAME-n]`, consistent
within a transcript.

## What gets flagged

| Type | Replacement | Detected by |
|---|---|---|
| PARTICIPANT | study ID | roster, exact + fuzzy |
| NAME | `[NAME-n]` | spaCy NER, Presidio, speaker labels |
| DATE | `[DATE]` | regex, NER (years alone and durations are kept) |
| AGE | `[AGE>89]` | regex, ages over 89 only |
| PHONE, EMAIL, URL, SSN, MRN, ID_NUMBER | `[PHONE]` … | regex + Presidio validators |
| ADDRESS, ZIP | `[ADDRESS]`, `[ZIP]` | regex |
| LOCATION, ORGANIZATION | `[LOCATION]`, `[ORGANIZATION]` | NER, generic ones such as "school" or "home" are kept |
| GARBLED | `[GARBLED: original]` | transcriber markers, repeated tokens, runs of unknown words, stutter runs, implausible words/sec from cue timing |
| INDIRECT | unchanged | "the only … in", named providers, schools, rare characteristics. Review only. |

Decisions: flags with confidence ≥ 0.9 start as **accept**; the rest start
as **pending**. Pending PHI is still redacted on export (block by default);
only a reviewer's **reject** restores the original text. INDIRECT flags are
advisory and never change the text unless you convert them.

Before writing any file the exporter re-scans the output for roster names.
If one survived (for example because a flag was rejected), export is
refused and the leak is listed. `--force` overrides that.

## Review UI

* Left: transcripts with pending counts. Middle: each segment with
  highlighted spans and the resulting output line. Right: the selected flag.
* Click a span, then **a** accept, **r** reject, **n** next pending.
  Change the type or replacement text in the panel. "Apply decision to all"
  handles every span with the same text.
* Select any text in a segment to add a flag by hand.
* A NAME flag can be mapped to a study ID; that adds an alias to the roster
  file and **Re-run** re-detects with the new roster while keeping your
  decisions.
* **Export** writes the de-identified file for the current transcript.

Decisions are saved to the sidecar immediately, so the review can be paused
and resumed.

## Limits you should know

* Model-based name detection is not perfect. Lowercase names, unusual
  spellings, and names that are also words ("Hope", "Will") are the usual
  misses. The roster plus review pass exist because an unreviewed automated
  pass is not a safe HIPAA release.
* Indirect identifiers ("my brother the only pediatric surgeon in Tulsa")
  need a human. The INDIRECT heuristics point at likely sentences; they do
  not catch everything.
* Docx output collapses character formatting inside a paragraph whose text
  changed (bold speaker labels stay bold; mixed runs inside one paragraph
  become one run). Paragraph styles, headers, tables and page setup survive.
* One spaCy model, English only.

## CLI options

```
run     INPUT... --roster CSV --out DIR [--model en_core_web_lg] [--no-nlp]
        [--no-presidio] [--no-fuzzy] [--no-garbled] [--no-indirect]
        [--no-export] [--force] [--print]
export  --out DIR [--roster CSV] [--require-review] [--force]
check   --out DIR
review  --out DIR [--roster CSV] [--host 127.0.0.1] [--port 8765]
```

`--no-nlp` runs roster + regex only, in well under a second per file, and
is useful when the model is not installed.

## Development

```bash
uv sync --extra dev
uv run pytest            # NLP tests skip automatically if the model is missing
python examples/make_docx.py   # rebuild the sample .docx
```

Layout: `io/` readers and writers, `detect/` detectors (regex PHI, garbled,
NER, indirect), `roster.py`, `engine.py` (overlap resolution, consistent
tags, export safety), `report.py` (sidecars, summary), `web/` (FastAPI +
single-file UI), `cli.py`.
