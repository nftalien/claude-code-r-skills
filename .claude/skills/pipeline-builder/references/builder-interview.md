# Builder interview

The question sequence for Mode A (and the subset Mode B needs). It replaces the
front half of fearlabr-pipeline's `references/config-interview.md`: study
identity, arms, REDCap events, instruments, structural skips and de-id are
read from the project and confirmed (sections 0 and 1); MetricWire, paths
and exclusions still follow that file; the sections here add modalities. Prefer clickable prompts
where the answer is a choice. Ask nothing the files already answer.

Order matters: the REDCap read first, because every later answer is
expressed in the timepoint vocabulary it produces.

## 0. Read the project first (always)

Run `scripts/derive_config.R` before asking anything. API when the keyring
holds the token (`redcap.api_token_service` / `api_token_key` in a minimal
`_config.yml`, or `REDCAP_API_URL` and `REDCAP_API_TOKEN` in the
environment); otherwise the three Project Setup exports (data dictionary,
events, instrument-event mapping) dropped in `metadata/`. It writes
`_config.proposed.yml` and `metadata/config_todo.csv`.

What it derives without asking: the ID column; every event with its raw
name, label and whether a scored instrument is collected there; each
instrument's items in dictionary order, item range, total range, the calc
field that references every item, and subscales from the other calc fields;
the randomization field and its arms; identifier-flagged fields and date
fields for de-id; single-field branching logic as structural skips; all form
names for `forms_to_pull`; with the API, the project title and instrument
labels.

What it infers and marks so: an offset read from an event name when REDCap's
`day_offset` is zero (`6_month` gives 180); a subscale name from a calc
field's name; the anchor date field when exactly one date-validated field
sits on a form collected at the anchor event.

What it defaults and marks so: a `[-7, 7]` window when REDCap's offset range
is zero, narrowed where two defaults would overlap; `minimum_valid_items`
at 80% of items.

## 1. Walk the todo (always)

Open `metadata/config_todo.csv` with the person. `ask` rows first:

- **Anchor date field**, if more than one candidate or none.
- **Modalities expected at each timepoint.** The proposal lists `redcap`
  only; add `ema`, `eeg`, `sensors` per timepoint from the protocol.
- **Is this form a scored instrument?** Every form with three or more
  same-range items is proposed; a demographics or screening form can look
  like one. Drop what is not scored. Confirm items excluded for having a
  different range (a slider, a text field with its own bounds).
- **Reverse-coded items.** Not in the dictionary. From the scale's manual.
- **A form with no calc field.** Nothing to cross-validate the total
  against; say so in the config note, or add the calc field in REDCap.
- **Arms.** The randomization field's choices are proposed as conditions.
  Confirm they are treatment and not order (UFOs is a crossover: its
  `randomize` field is order).
- **Offsets REDCap left at zero and the name did not give** (`posttx`,
  `followup`). From the protocol.
- **Multi-condition branching logic.** Listed, not converted; decide whether
  each is a structural skip.

Then `inferred` rows (confirm each number), then `default` rows (accept or
change). `derived` rows are shown as a table, not asked. Timepoint keys may
be renamed here (`week_4` to `week4`) as long as every reference in the
proposal moves with them; the derive script uses the REDCap-derived key
everywhere so a rename is one find-and-replace.

Write the confirmed proposal into `_config.yml`, run
`assert_timepoints_declared()`, and correct the dictionary at the source
wherever the person's answer showed it wrong.

## 2. Modalities present

Prompt: which of MetricWire EMA, EEG/ERP, passive sensor or actigraphy are
present. Multi-select. REDCap is already on. For anything else the person
names that is not one of these ("fMRI", "EMG startle", "voice"), say the
builder does not have a module for it yet, offer to keep it as a per-study
`R/` helper with its own stage after 07m, and note it for Mode E. Then add
each present modality to the timepoints where it is expected.

## 3. EEG / ERP (if on)

Read `modality-eeg.md` first.

- **Which tool preprocessed it?** MNE, EEGLAB/ERPLAB, BrainVision Analyzer,
  other. This decides which export recipe to hand back.
- **What does the export look like?** Ask for the first five lines or the
  column names. If they paste them, build `eeg.columns` from what is there.
  If the export is wide (one column per channel or per component), say the
  0.2.0 module reads long only and give the reshape from the recipe file.
- **Participant ID format in the export** versus REDCap: BIDS `sub-0012`
  against `0012` is the usual case. Set `id_transform` and `id_pattern`.
- **Session labels** in the export and which timepoint each is. This is
  `session_map`. Every label must map; an unmapped session survives ingest
  with `timepoint = NA` and is reported.
- **Features the analysis plan names.** For each: name, measure as the export
  calls it (`mean_amplitude`, `peak_latency`, `power`), condition, channels
  to average, and the window in ms (recorded, not applied). At least one; a
  feature that matches nothing stops 02e.
- **QC thresholds.** Minimum trials per participant-session, plausible
  amplitude range in the export's units, channels that must be present. If
  they do not know, propose values from the component's literature and mark
  them `# TODO confirm` in the config.

## 4. Sensors / actigraphy (if on)

Read `modality-sensor.md` first.

- **Device or source per stream**, and whether the export is one row per
  day (daily summary) or many rows per day with a timestamp (epochs). One
  stream per export type: `accel`, `sleep`, `hr`, `gps_mobility`.
- **Column names** for id, date or timestamp, and every metric that will be
  used. Again from the header, never from memory. Metrics get canonical names
  (`steps`, `wear_minutes`, `sleep_minutes`) that the valid-day rule and 07m
  refer to.
- **Time zone** for epoch timestamps. One per study.
- **Aggregation** for epoch streams: sum for counts and minutes, mean for
  rates.
- **The valid-day rule.** A one-line expression over the canonical metrics,
  quoted in the render. Offer the common ones (`wear_minutes >= 600` for
  wrist actigraphy; `sleep_minutes > 0` for sleep summaries) and ask which
  the protocol or the lab's prior papers used.
- **ID format** in the export versus REDCap.

## 5. Files

For each modality, ask where the exports are now and say where they go:
`data/raw/` (REDCap, EMA), `data/raw/eeg/`, `data/raw/sensor/`. Set each
glob so that a re-export with a new date still matches (`*` for the batch
part). When a file is present, run `builder_glob_files()` and show the count.

If a modality's files do not exist yet, ask whether to proof it on synthetic
data now and build its stages when the files arrive, or to leave the
modality off the plan and add it in Mode B. Do not generate its stages on a
guess about the export shape.

## 6. Verification preferences

- **How do they want to see renders?** Open the HTML themselves and report
  back, or paste the console tail. Both work; the HTML is better for tiles.
- **Who approves?** Default is the person in the chat. If a PI approves,
  say so in the note on each approval.
- **Stage size.** Default one stage per round. A person who has run several
  fearlabr studies may ask for the core 01 to 03 in one round; allow it only
  for stages whose dependencies are all approved, and still one render per
  stage.

## 7. Analysis intent (optional now)

Not needed to build 00 through 07m. Before 08 and 10 the study needs the
registry and the analytic plan (fearlabr-pipeline Mode E). Note what the
person says about outcomes and hypotheses and carry it to that mode; do not
invent entries.

## After the interview

1. Write `_config.yml` (the confirmed proposal plus the modality blocks).
2. `assert_timepoints_declared(config)`.
3. `new_pipeline_manifest(config)` and write `_pipeline.yml`.
4. Show the DAG and the stage list; get a yes.
5. Go to files, then proof, then the loop.
