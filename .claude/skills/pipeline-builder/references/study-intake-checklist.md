# Study intake checklist

What to have ready before the interview for a new study, why each item
matters, and the form it should take. Everything here is asked for at step
1 of the loop; a study that arrives with the list complete gets from 00 to
03 in one sitting. FARM-TOK arrived with about half of it and spent the
difference in renders (`lessons-farmtok-2026-09.md`).

Put files under `metadata/` in the repo unless the row says otherwise.
Nothing on this list contains participant data. Data files go under
`data/raw/`, which is git-ignored.

## 1. REDCap

| Item | Why | Form |
|---|---|---|
| Data dictionary | every instrument, item, code and branching rule the config derives from | REDCap Project Setup > Data Dictionary, CSV, exported **the same day** as the two below and after the last form edit |
| Instrument designations | which form is on which event; decides waves and baseline-only instruments | Project Setup > Designate Instruments, or the instrument-event map CSV |
| Events (arms and events) | event names, order and day offsets | Project Setup > Define My Events export |
| API token | the pipeline pulls through the API; the token is the only credential | in the OS keyring only, never in a file or the chat; say which keyring service name it is under |
| Record id field and format | id audit lines depend on knowing the pattern | one line: field name, pattern (e.g. four digits), range |
| Test and practice records | must be excluded before any count | list of record ids, with a word on what each is |
| Id repairs | mistyped ids that must be corrected, not dropped | `metadata/id_repairs.csv`: `from, to, reason` (must not overlap the test list) |
| Randomisation | the arm field, its codes, and the **event it lives on**; the stratifiers and **their** event | one line each |
| Calc fields to trust or quarantine | REDCap calc fields can be wrong at source (FARM-TOK had three) | list any known-wrong calc; the rest are cross-checked at 03 |
| Free-text fields | never reach derived data; must be known so they can be excluded | the dictionary marks them; note any that need a local, restricted export |

## 2. MetricWire EMA (if on)

| Item | Why | Form |
|---|---|---|
| Survey definition per battery | item ids, types, ranges, option labels | the study's survey definition CSV exports, one per battery |
| Codebook | item text and the study's own item names | dashboard codebook PDF plus `ema_item_names.csv` (id, short name) |
| Triggers and schedule | prompts per day, windows, study length in days | one table: battery, time window, days |
| Workspace and analysis ids | which analysis is which battery | fine to commit; list them |
| Client id and secret | API credentials | OS keyring only |
| Account id field | which account field carries the participant id | one line (FARM-TOK: `User.FirstName`) |
| Known id anomalies | test accounts, ids with suffixes | added to the test list or the repairs file above |
| Date format of the export | m/d/Y vs d/m/Y decided by the data, but say what it should be | one line |

## 3. Other modalities (if on)

| Item | Why | Form |
|---|---|---|
| EEG/ERP feature table export | the pipeline ingests preprocessed tables only | one sample file with header; the export recipe in `modality-eeg.md` |
| Session-to-timepoint map | EEG sessions do not carry wave names | `eeg.session_map` in the config |
| Sensor/actigraphy export | header, preamble, grain | one sample file; device and firmware |
| Anchor date rule | sensor days map to timepoints through it | field name and event |

## 4. Protocol and analysis

| Item | Why | Form |
|---|---|---|
| Protocol, current version | schedule of assessments, windows, per-protocol definition | PDF or docx in `metadata/` |
| Schedule of assessments | drives `timepoints:` | table: timepoint, day offset, window, which modalities |
| Anchor date | every window is relative to it | field name and event |
| Per-protocol rule | 03b | one sentence (FARM-TOK: at least 4 of 6 sessions) and the field that evidences it |
| Lock wave | which wave the primary is judged at | one line |
| Feasibility benchmarks | 08 | table: benchmark, target, source (citation or protocol page), progression rule |
| Exit interview items | 08 | list of item fields; which are free text |
| Fidelity coding | 08 | adherence and competence fields, their maps |
| Adverse events and safety fields | 08 and 03's restricted listing | field names; the C-SSRS or equivalent |
| Primary outcome and secondaries | 10 | the registry draft: id, outcome, instrument, waves, status |
| Moderators and subgroups | 10 | list with the field, event and cut for each |
| Engine | 10 | `bayes` or `frequentist`; see toolchain below |
| Registration number | DAP | trial registry id, if registered |
| PI, institution, funder, grant | config `study:` block | one line each |

## 5. Toolchain on the render machine

| Item | Why | How to check |
|---|---|---|
| R version | binaries must match | `R.version.string` |
| Rtools (Windows) | brms and rstan compile | `Sys.which("make")` non-empty |
| Quarto | renders | `quarto --version` in a terminal, or RStudio's bundled one |
| Packages | `install_deps.R` lists them | run it; it sets the mirror |
| fearlabr >= 0.2.0 | modality modules | `packageVersion("fearlabr")` |
| Repo path | no synced folders | a short local path, e.g. `C:\r\<study>` |
| Keyring | credentials | `keyring::key_list()` shows the service names |

If Rtools is absent or rstan does not load, set `analysis.engine:
frequentist` now rather than after the first failed render of 10.

## 6. Repo and security

Confirmed at 00, but decided at intake:

- private GitHub repo; `data/**`, `output/**`, `*.html`,
  `*_RESTRICTED*`, `*_safety_review*` git-ignored;
- credentials in the keyring only, named by service;
- free text never reaches derived data; any free-text export is a script
  with a plain name writing a `*_RESTRICTED` file locally, pseudonymised,
  flagged for a human read;
- the cloud session sees synthetic data only; real renders happen on the
  lab machine and the person reports what they show.

## What the interview will still ask

Even with the list complete, these are decided in the conversation:

- scoring rules the dictionary cannot state (reverse-coded items, means vs
  sums, thresholds);
- which calc fields to trust;
- whether an instrument with one or two participants was administered or is
  vestigial;
- what to do with enrolled participants who have no data in a modality;
- verification preferences (HTML or console tail; who approves).
