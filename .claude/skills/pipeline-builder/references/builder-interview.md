# Builder interview

The question sequence for Mode A (and the subset Mode B needs). It sits on
top of fearlabr-pipeline's `references/config-interview.md`: run that for
study identity, arms, REDCap, instruments, structural skips, MetricWire,
paths, exclusions and de-id, then the sections here. Prefer clickable prompts
where the answer is a choice. Ask nothing the files already answer.

Order matters: timepoints first, because every later answer is expressed in
that vocabulary.

## 1. Timepoints (always)

- **How many assessment timepoints, and what are they called?** Short keys
  (`baseline`, `week4`, `fu_6mo`) become the vocabulary in every table. Labels
  are for humans. Take the keys from the protocol's schedule of assessments.
- **Which one is the anchor, and which REDCap field holds its date?**
  Usually baseline and a consent or session-1 date field. Confirm the field
  exists in the data dictionary; 02s stops if it is absent from the
  participant-level file.
- **Offset in days from the anchor for each timepoint.** Protocol numbers,
  not observed medians.
- **Window around each offset, in days, inclusive.** A visit window from
  the protocol (`[-3, 7]`), or for a wave that is "whenever they came back",
  a wide window that still cannot overlap its neighbours. Overlap stops the
  config check; there is no tie-break rule and there should not be one.
- **Which modalities are expected at each timepoint.** A modality left off
  a timepoint is not counted as missing there. An EEG session only at
  baseline and week 12 is expressed here, not in the EEG block.
- **The REDCap event for each timepoint**, verbatim from the label file
  (truncated names included).

Write the block and run `assert_timepoints_declared()` before moving on.

## 2. Modalities present

Prompt: which of REDCap panel, MetricWire EMA, EEG/ERP, passive sensor or
actigraphy. Multi-select. REDCap is always on. For anything else the person
names that is not one of these ("fMRI", "EMG startle", "voice"), say the
builder does not have a module for it yet, offer to keep it as a per-study
`R/` helper with its own stage after 07m, and note it for Mode E.

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

1. Write `_config.yml` (fearlabr blocks plus the ones above).
2. `assert_timepoints_declared(config)`.
3. `new_pipeline_manifest(config)` and write `_pipeline.yml`.
4. Show the DAG and the stage list; get a yes.
5. Go to files, then proof, then the loop.
