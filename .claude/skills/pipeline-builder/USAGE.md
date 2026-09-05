# Using the pipeline-builder skill

The human-facing guide. `SKILL.md` and `references/` are written for Claude;
this one is for you.

## What it does

You describe the study (how many timepoints, which kinds of data), drop the
files in, and the pipeline gets built one stage at a time. Each stage is a
numbered Quarto notebook on the `fearlabr` engine. You render it, look at
what it shows, and approve it; only then is the next stage written. The
build record lives in `_pipeline.yml` next to `_config.yml`, so you can stop
and come back, and the pipeline-status notebook draws where things stand.

It handles REDCap and MetricWire EMA (the existing fearlabr stages) and adds
two modalities:

- **EEG / ERP**: preprocessed feature tables exported from MNE, EEGLAB,
  ERPLAB or BrainVision Analyzer. The pipeline does not preprocess raw EEG.
- **Passive sensors / actigraphy**: daily or epoch exports from a wrist
  device or a phone, with the valid-day rule you choose.

Everything is keyed to one declaration of the study's timepoints, so "who has
baseline EEG but no week-4 actigraphy" is a table the pipeline prints rather
than a question you answer by hand.

## A session, from your side

**1. Let it read REDCap.** One command in the terminal (not the R console):

```
Rscript scripts/derive_config.R STUDY
```

With the project's API token in your keyring it pulls the events, the
instrument-event mapping and the data dictionary and proposes the config:
timepoints with offsets and windows, every instrument's items and ranges,
calc fields for cross-validation, subscales, the randomization arms,
identifier fields. Without a token, download those three exports from
Project Setup into `metadata/` and pass them with `--dict`, `--events`,
`--map`. You get `_config.proposed.yml` and a todo table that says what was
read, what was inferred from a name, what was defaulted, and what only you
can answer (the anchor date field, which timepoints have EEG or actigraphy,
reverse-coded items, whether a form is really a scored instrument). Claude
walks that table with you; where a question has a fixed set of answers you
get buttons.

If the study has MetricWire EMA, a second command does the same for it:

```
Rscript scripts/derive_ema_config.R --codebook period_1=metadata/period_1_codebook.pdf
```

It reads each session's data (pulled with your MetricWire credentials, or
the cached export), the codebook, and the choicesDataCoding export if you
have one, and adds the EMA block: sessions, items with names and ranges,
which prompts carry which items, free-text fields, safety candidates, and
which account field holds the participant ID. It flags an analysis exported
without Missed rows and a declared range the data contradicts, the two
things that cost the most time on the first real study. You still declare
gates, safety thresholds and the battery map.

**2. Drop the files in.** Claude tells you which files go where
(`data/raw/`, `data/raw/eeg/`, `data/raw/sensor/`). When a file lands, paste
its first lines or its column names; Claude writes the column crosswalk into
the config from what it sees, not from memory.

**3. Proof it.** Two commands in the terminal (not the R console):

```
Rscript scripts/proof_pipeline.R
Rscript scripts/proof_modalities.R
```

Fake data is built from your config and pushed through the engine. Red means
a config field to fix; green means real data can go in.

**4. Build a stage.** Claude writes the next notebook and tells you what it
will show. You render it:

```
quarto render notebooks/01e_ingest_eeg.qmd --output-dir output/renders
```

Send back the HTML or the last screen of the console. Claude quotes the
warning lines and tells you which numbers and pictures to look at (the ID
line, the QC tile, the coverage bars). If something is off, it fixes the
config and you re-render.

**5. Approve it.** In the R console:

```r
builder_approve("01e_ingest_eeg")
```

That records your approval and names the next stage. Repeat.

**6. See where things stand.** Any time:

```
quarto render notebooks/00b_pipeline_status.qmd --output-dir output/renders
```

The diagram colours each stage by status; the table underneath says what is
next; the coverage panel shows every modality against every timepoint.

## What you end up with

```
STUDY/
├── _config.yml          the study: timepoints, instruments, modalities, files
├── _config.proposed.yml what REDCap said, before you confirmed it
├── _pipeline.yml        the build record: stages, dependencies, who approved what
├── notebooks/           00 … 10, plus 00b, 01e, 02e, 01s, 02s, 07m as the study needs
├── data/raw/            your exports (eeg/ and sensor/ subfolders for those)
├── data/derived/        *_latest.rds per stage; *_multimodal_linked_latest.rds from 07m
├── output/renders/      one HTML per rendered stage
├── output/validation/   QC and coverage CSVs; *_coverage_<modality>.csv feed the dashboard
├── output/figures/      the tiles and bars each stage drew
└── scripts/             install_deps.R, proof_pipeline.R, proof_modalities.R
```

## First-time setup

The modality modules are a fearlabr 0.2.0 addition. Once, from the
fearlabr-pipeline skill's package directory (terminal):

```
Rscript path/to/pipeline-builder/assets/fearlabr-modules/apply_modules.R assets/fearlabr-package
cd assets/fearlabr-package && R CMD build . && R CMD INSTALL fearlabr_0.2.0.tar.gz
```

Then restart R. `00_setup` checks the version and stops below 0.2.0. Renders
need a UTF-8 locale (RStudio on Windows and Mac are fine; a bare `Rscript` on
Linux wants `LANG=C.UTF-8`).

## Things worth knowing

- Approving is yours. Claude will say a render looks consistent, but the
  stage is not approved until you run `builder_approve()` or say so.
- Changing `_config.yml` after approving a stage resets that stage and
  everything after it. Claude will say which notebooks to re-render.
- The EEG QC and the sensor valid-day rule are printed in every render, so
  a methods section can quote the pipeline rather than the other way round.
- A Shiny front end is the planned next step; every function the chat uses is
  one the app will call, so nothing built now is thrown away.
