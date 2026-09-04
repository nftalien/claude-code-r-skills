---
name: pipeline-builder
description: >-
  Build a FEAR Lab study data pipeline one stage at a time, with the person
  verifying each stage's render before the next is generated. Interviews for
  the study's timepoints, modalities and files, writes the _config.yml blocks
  and the _pipeline.yml build record, generates numbered Quarto stages on the
  fearlabr engine (REDCap, MetricWire EMA, preprocessed EEG/ERP feature
  tables, passive sensor and actigraphy streams), and gates every stage on a
  visual check: ID audit lines, timepoint completeness, QC tiles, coverage
  dashboard, pipeline DAG. Use this WHENEVER the user wants to "build a
  pipeline", "set up a workflow I can drop files into", "walk me through the
  pipeline step by step", asks what files they need, mentions timepoints or
  waves across modalities, wants EEG/ERP, actigraphy, wearable or phone sensor
  data alongside REDCap or EMA, wants to see the pipeline as a diagram, asks
  "what stage are we on", or wants to add a modality to an existing fearlabr
  study. Also for applying the fearlabr 0.2.0 modality modules. Not for
  one-off analyses, raw EEG preprocessing, or non-R work; the REDCap/EMA
  engine itself is the fearlabr-pipeline skill.
---

# pipeline-builder

A step-by-step builder on top of `fearlabr`. The fearlabr-pipeline skill owns
the engine and the REDCap + EMA stages; this skill adds four things:

1. **A timepoint declaration** every modality is checked against
   (`timepoints:` in `_config.yml`).
2. **Modality modules** in fearlabr 0.2.0: preprocessed EEG/ERP feature
   tables and passive sensor/actigraphy streams, each with ingest, QC,
   coverage, and synthetic generators (`assets/fearlabr-modules/`).
3. **A build record**, `_pipeline.yml`, that knows every stage, what it
   depends on, and whether a person has approved its render.
4. **The gated loop**: interview, files, proof, then one stage at a time,
   each rendered and looked at before the next is generated.

Read the fearlabr-pipeline skill's `SKILL.md`, `references/stage-contract.md`,
`references/conventions.md` and `references/lessons-ufos-2026-09.md` before
building anything. Everything there holds here. The additions below are what
changes when the study has more than REDCap and EMA, or when the person wants
to watch the pipeline come together rather than receive a zip.

## Non-negotiables

- **One stage at a time.** Generate a stage only when `_pipeline.yml` says
  every dependency is approved (`builder_stage_gate()` enforces it inside the
  notebook; `mark_stage(..., "generated")` enforces it in the manifest).
  Never write two stages ahead "to save a round trip".
- **The person approves; you never do.** A stage becomes approved through
  `builder_approve("<id>")` in their R console or through their explicit
  "approved" in the chat, after which you run `mark_stage()`. Do not mark a
  stage approved because the render looked fine to you.
- **Show, then ask.** At every gate, tell the person exactly what to look at
  (the `verify` string in `builder_stage_registry()` is the minimum), quote the
  `⚠️` lines from their render, and name the numbers that should match. Do
  not summarise a render as "looks good".
- **Timepoints are declared once.** No stage may carry its own wave
  vocabulary. EEG sessions map to timepoints through `eeg.session_map`;
  sensor days through anchor dates and windows; REDCap events through
  `redcap_event` in the schedule. If a modality's timepoint cannot be
  expressed in the declaration, the declaration is wrong, not the modality.
- **Raw EEG stays in the EEG tool.** The pipeline ingests preprocessed
  feature tables. If asked to filter, epoch or reject artifacts in R, say so
  and point to `references/modality-eeg.md` for the export recipe.
- **Files first, then config, then code.** When a person drops a file, read
  its header and propose the crosswalk; never invent column names. A stage is
  not generated for a modality whose files are absent unless the person says
  to proof on synthetic data.
- **fearlabr >= 0.2.0.** Check `packageVersion("fearlabr")` in 00. Below
  0.2.0, apply `assets/fearlabr-modules/` first (Mode E).
- Everything in fearlabr-pipeline's non-negotiables: read the function before
  calling it, package keys are the package's, shell commands go in the
  terminal, no identifiers parsed from ObjectIds, free text never reaches
  derived data, secrets only in the keyring, proof on synthetic first.

## Pick the mode

**Mode A, build a new study.** "Build me a pipeline", "set up a workflow I
can drop files into", "walk me through it".

**Mode B, add a modality to an existing fearlabr study.** "Add the EEG to
UFOs", "we have actigraphy now". Read the existing `_config.yml` and
`_pipeline.yml` (create the manifest from the config if it does not exist,
marking the stages already rendered as approved with `force = TRUE` and a
note saying why).

**Mode C, resume.** "Where were we", "what stage are we on". Read
`_pipeline.yml`, print `pipeline_status_table()`, name `next_stage()`, and
carry on the loop from step 4.

**Mode D, triage a failed or suspicious render.** "01e stopped", "coverage is
100%", "the QC tile is all orange". Mark the stage `failed` with the message
as the note, diagnose per fearlabr-pipeline Mode D and
`references/verification-gates.md`, fix in the smallest place, say which
stages to re-render.

**Mode E, apply or update the modality modules.** "Install the modules",
"bump fearlabr", "a sensor bug bit me". `Rscript apply_modules.R
<fearlabr-src>` from `assets/fearlabr-modules/`, then build and install; a
bug gets a regression test in the module's test file before the fix.

---

## The loop

### 1. Interview and plan

Run `references/builder-interview.md`. It reuses fearlabr's config interview
for study identity, REDCap, instruments and EMA, and adds timepoints and
modalities. Prefer clickable prompts where the answer is a choice. Ask only
what the files and prior materials cannot answer.

The output is `_config.yml` with the blocks from
`assets/config-modality-blocks.yml` spliced in (`timepoints` always; `eeg` and
`sensors` when present), and `_pipeline.yml` from
`new_pipeline_manifest(config)`. Before showing the plan:

```r
assert_timepoints_declared(config)
m <- new_pipeline_manifest(config)
write_pipeline_manifest(m, "_pipeline.yml")
pipeline_status_table(m)
```

Show the plan as the DAG. In the chat, paste `pipeline_dag_mermaid(m)` inside
a mermaid fence; in the project, `00b_pipeline_status.qmd` draws it with
`plot_pipeline_dag()`. The person confirms the stage list before any stage is
written. A study without EMA has no 04 to 07; a study without EEG has no 01e
and 02e; 07m is present whenever more than REDCap is on.

### 2. Files

For each enabled modality, say what files are needed, where they go, and how
they are found. The table:

| Modality | Where | Found by | What to check when the file arrives |
|---|---|---|---|
| REDCap | `data/raw/` | `redcap.export_prefix` | `id_column` present; event names verbatim |
| EMA | `data/raw/` | `metricwire.sessions[*].file` | one file per session; ID column as declared |
| EEG | `data/raw/eeg/` | `eeg.file_glob` | long shape; columns in `eeg.columns`; session labels in `session_map` |
| Sensors | `data/raw/sensor/` | `sensors.streams.<k>.file_glob` | id/date (or timestamp) and every metric column present |

When a file arrives, read the header (`readr::read_csv(n_max = 5)`), print
it, and propose the crosswalk as a config edit. Confirm
`builder_glob_files(config, glob)` finds it. Do not generate the modality's
stages until this passes or the person opts for synthetic proof.

### 3. Proof on synthetic data

Terminal, project root:

```
Rscript scripts/proof_pipeline.R        # REDCap + EMA core (fearlabr-pipeline)
Rscript scripts/proof_modalities.R      # timepoints, EEG, sensors, 07m, manifest gates
```

Both must be green before real exports are touched. A red stage names the
config field. Fix config, re-run; never patch the synthetic data to pass.

### 4. Stage by stage

Repeat until `next_stage(m)` is `NULL`:

1. **Name the stage.** `id <- next_stage(m)`. Say what it does in two
   sentences and what the person will look at (`verify` from the registry).
2. **Generate.** Core stages (00, 01 to 03b, 04 to 07, 07c, 08, 10) come from
   the fearlabr-pipeline reference study and templates, with one chunk added
   at the top (`builder_stage_gate("<id>")`) and one at the end
   (`builder_record_render("<id>")`). Modality stages (00b, 01e, 02e, 01s,
   02s, 07m) come from this skill's `assets/qmd-templates/`. Substitute
   `{{STUDY_NAME}}`, write to `notebooks/`, then
   `mark_stage(m, id, "generated")` and save the manifest.
3. **Render.** Terminal, not the R console:
   ```
   quarto render notebooks/<id>.qmd --output-dir output/renders
   ```
   The notebook's last chunk marks the stage `rendered` in `_pipeline.yml`.
4. **Verify.** The person sends the HTML or the console tail. Run
   `summarise_render_log()` on the text, quote every `⚠️` and `⏭` line, read
   the ID audit lines and the numbers the stage contract says to read, and
   walk through `references/verification-gates.md` for that stage. Tell the
   person what is right, what is not, and what to look at in the render. If
   something is wrong: `mark_stage(m, id, "failed", note = ...)`, fix, back
   to step 3.
5. **Approve.** The person runs `builder_approve("<id>")` (or says so and you
   run `mark_stage(m, id, "approved", note = <what they checked>)`). Print
   `next_stage(m)`.

Re-render `00b_pipeline_status.qmd` whenever the person asks where things
stand, and after 03, 02e, 02s and 07m, when new coverage files exist.

A change to `_config.yml` after a stage is approved resets that stage and
everything downstream: `mark_stage(m, "<first stage reading the changed
block>", "planned", note = "config changed: <what>")`. Say which stages must
be re-rendered and in what order.

### 5. What each gate shows

| Stage | Picture or table | The person checks |
|---|---|---|
| 00 | config echo, timepoint schedule table | names, offsets, windows are the protocol's |
| 00b | DAG, status table, coverage dashboard | the graph is the plan; blue is what they approved |
| 01 / 01e / 01s | ID audit lines; raw distributions; session or date ranges | zero format-fail; scales match the units claimed |
| 02 / 02e / 02s | duplicate keys, dictionary diff / QC tile / valid-day tile with the rule printed | flagged people are ones they can account for |
| 03 | calc-mismatch, out-of-range, timepoint completeness | zero mismatches or a reason for each |
| 05 | compliance heatmap | missed prompts are present, not dropped |
| 07 / 07m | linkage audit, only-in-each, coverage dashboard | one ID shape across sources; only-in-each list adjudicated |
| 07c | UpSet | intersections match the calendar |
| 08 / 10 | registry tables, validation-gate blockquotes | pre-specified numbers land where the plan said |

Details, including what a wrong picture looks like, are in
`references/verification-gates.md`.

---

## Modality contracts

**Timepoints** (`references/pipeline-manifest.md`, `R/timepoints.R`). Keys
are the vocabulary used everywhere; offsets and windows are days from an
anchor date held in a REDCap column; windows may not overlap; `modalities`
lists what is expected at each timepoint. Coverage is always expected versus
observed against the REDCap roster.

**EEG / ERP** (`references/modality-eeg.md`, `R/ingest_eeg.R`). Long feature
table in, canonical long table and a participant × timepoint feature table
out. QC on trial floor, amplitude range, required channels. A feature
matching zero rows stops the stage.

**Sensors** (`references/modality-sensor.md`, `R/ingest_sensor.R`). Day or
epoch grain in, participant-days out, validity by a declared rule that the
render prints, days assigned to timepoints by anchor and window.

**REDCap and EMA**: unchanged from fearlabr-pipeline. The builder adds the
timepoint completeness table to 03 and the compliance heatmap to 05 (both
from `R/quicklook.R`), and the gate and record chunks to every notebook.

File stems the new stages write and read are listed in
`references/pipeline-manifest.md` under "Stage contract addendum". Never
invent a stem; trace every reader.

## Shiny later

The functions are the contract the front end will wrap: the interview becomes
a form that writes `_config.yml`; the file step becomes a drop zone that runs
`builder_glob_files()`; the stage loop becomes cards from
`manifest_stages_tbl()` with a render button and the HTML in a frame; the
approve button is `mark_stage()`. `references/shiny-roadmap.md` maps each
function to a UI element. Nothing in this skill should be written in a way
that only works from a chat.

## What to read when

- `references/builder-interview.md`: the question sequence and the file
  prompts, before step 1.
- `references/verification-gates.md`: before reading any render, and in Mode D.
- `references/pipeline-manifest.md`: manifest schema, rules, functions, and
  the stage contract addendum, before generating any stage.
- `references/modality-eeg.md`, `references/modality-sensor.md`: before
  writing the modality's config block or stages.
- `references/shiny-roadmap.md`: only when the front end is being planned.
- fearlabr-pipeline's references, always.

## Assets

- `assets/fearlabr-modules/`: fearlabr 0.2.0 modules (R, tests,
  `NAMESPACE.additions`, `NEWS-0.2.0.md`, `apply_modules.R`). Full suite on
  0.1.1 + modules: 183 pass, 0 fail.
- `assets/qmd-templates/`: 00b, 01e, 02e, 01s, 02s, 07m.
- `assets/config-modality-blocks.yml`: `timepoints`, `eeg`, `sensors` blocks.
- `assets/example-config-multimodal.yml`: complete proofable example (REDCap
  + EEG + sensors, three timepoints); what the proof script runs without a
  study config.
- `assets/pipeline-manifest-template.yml`: the manifest shape, annotated.
- `scripts/proof_modalities.R`: synthetic proof of everything this skill adds.
- `USAGE.md`: the human-facing guide.
