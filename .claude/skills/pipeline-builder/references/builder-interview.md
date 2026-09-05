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

## 1b. MetricWire EMA (if on): read, then walk

Run `scripts/derive_ema_config.R` with each session's codebook (and the
choicesDataCoding export when the study has one). API when the keyring holds
the client credentials and `metricwire.sessions[*].analysis_id` is set;
otherwise `--data key=path` per session. The analysis ids come from the
MetricWire analysis page and are typed once.

What it derives: sessions and whether each export carries Missed rows (an
analysis without them reads 100% compliance; fix the analysis definition at
source, then re-pull); every question column with its codebook text and a
proposed canonical name (the battery choice word, else the first content
words); declared range from `choicesDataCoding`, else the codebook, beside
the observed range; which survey names carry which items; free-text items;
items whose wording suggests a safety item; which account field holds the
participant ID and the observed ID range.

The `ask` rows for EMA:

- **A session with no Missed rows.** Not a config question; the analysis in
  MetricWire has to include Missed response types. Nothing downstream is
  right until it does.
- **A declared range the data contradicts** (coding 1-5, data 0-4). The
  momentary scale is usually zero-based even when the panel version is not.
  Fix the range; never proceed with NAs.
- **Gates.** An item shown only when another fired (`affect >=
  eligibility_cutoff`, `past_stress_event == 1`). From the survey logic in
  MetricWire; the codebook does not carry it.
- **Safety thresholds.** `safety_min` per candidate item, from the
  protocol. A candidate is found by wording; the threshold never is.
- **Battery map.** Which battery each session is and the evidence (UFOs:
  verified against randomization for 83 of 83). Not in MetricWire.
- **Arm per session** when only one condition receives a battery.
- **Canonical names.** Rename any proposed slug; the raw column and quest
  code travel with it so 04's crosswalk is generated from the config.
- **ID resolver** when more than one account field matches the pattern.
  UFOs needed a coalesce across first name, last name and user id; the
  proposal lists every matching field.

## 2. Modalities present

Prompt: which of EEG/ERP, passive sensor or actigraphy are present (EMA was
handled in 1b); their blocks are then read from the files in sections 3 and 4. Multi-select. REDCap is already on. For anything else the person
names that is not one of these ("fMRI", "EMG startle", "voice"), say the
builder does not have a module for it yet, offer to keep it as a per-study
`R/` helper with its own stage after 07m, and note it for Mode E. Then add
each present modality to the timepoints where it is expected.

## 3. EEG / ERP (if on): read, then walk

Read `modality-eeg.md` first. Put the feature export and, when they exist,
the BrainVision `.vhdr`/`.vmrk` files, the BIDS sidecars and the ERPLAB bin
descriptor under `data/raw/eeg/`, then run `scripts/derive_modality_config.R`.

What it derives: the column crosswalk by name (with the export columns it
could not place listed); the id transform from the id shape and, when the
REDCap roster exists, how many EEG ids it finds there; the session map by
exact key or label, else by position among the timepoints that expect EEG;
the channels present for every participant-session as `required_channels`;
one feature candidate per measure x condition; the amplitude range from the
0.5 and 99.5 percentiles and the trial floor from the 5th percentile, both
marked default with the numbers; and `eeg.recording` (sampling rate,
channels, reference, unit, hardware filters, amplifier, software, and from
the BIDS sidecar the power-line frequency, software filters, cap and
placement scheme). Marker codes, bin labels and event types are listed so
the export's condition labels can be checked against them.

The `ask` rows for EEG:

- **A wide export.** Channels as columns cannot be crosswalked; reshape at
  export (`modality-eeg.md`) or add a `pivot_longer` before ingest.
- **Which timepoints expect EEG**, when the schedule lists none, or a
  session label that matched no timepoint.
- **The features the plan names** and their `window_ms`. The export does
  not carry the window; it is in the preprocessing script.
- **Thresholds** the protocol states, to replace the defaults.
- **An id width that does not match REDCap** (three-digit BIDS ids against
  four-digit REDCap ids): decide the transform, do not pad blindly.
- **Headers that disagree** on sampling rate, or an amplifier not found in
  the header comment.

## 4. Sensors / actigraphy (if on): read, then walk

Read `modality-sensor.md` first. Drop the exports under `data/raw/sensor/`
and run `scripts/derive_modality_config.R` (with `--sensor key=glob` to name
the streams, or without flags to group files by their column set).

What it derives per stream: the glob from the file names; the vendor and
device block from the ActiGraph or GENEActiv preamble (serial, epoch length,
start and download dates, measurement frequency, time-zone offset); the
grain from rows per participant-day and the epoch length from the preamble
or the timestamp gaps (millisecond epoch timestamps from phone apps are
recognised); id, date or timestamp columns and metrics by name against a
vendor vocabulary, with unmatched columns listed; aggregation defaults for
epoch streams (sum for counts and minutes, mean for rates); the valid-day
rule at 600 wear minutes with the fraction of days it keeps, or
`sleep_minutes > 0` for sleep summaries; and the id transform.

The `ask` rows for sensors:

- **Time zone.** Never in a plain table; the GENEActiv header gives an
  offset, not a named zone. Pick the named zone.
- **A stream with no id column.** One file per participant with the id in
  the file name or the preamble's subject code, or exports keyed by device
  serial that need a roster.
- **No wear or sleep metric** to base a rule on: state the protocol's.
- **Unmatched metric columns** worth keeping: add them to `metrics` with a
  canonical name.
- **No header row after the preamble**: re-export with column names.

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
