# EEG / ERP modality contract

## Scope

The pipeline ingests **preprocessed feature tables**. Filtering, re-referencing,
epoching, artifact rejection, ICA and averaging happen in the EEG tool, where
the methods are mature and the lab's SOP already lives. What the pipeline
adds is the part those tools do badly: putting the export into the study's ID
and timepoint vocabulary, gating on the QC metadata the export carries, and
joining to everything else on `study_id` × `timepoint`.

Not in scope for 0.2.0: raw `.set`, `.fif`, `.vhdr`, `.edf` files; wide
exports; time-frequency tables (a `measure` column of `power` with a
`frequency_band` column is the planned extension and will need one more
canonical column).

## The export the module reads

Long, one row per participant × session × channel × condition × measure:

| canonical | meaning | required |
|---|---|---|
| `id` | participant, in the export's format | yes |
| `session` | export session label (`ses-01`, `T1`, `baseline`) | no, but needed for timepoints |
| `channel` | electrode or ROI label | yes |
| `condition` | trial type (`error`, `correct`, `standard`, `oddball`) | no |
| `measure` | `mean_amplitude`, `peak_amplitude`, `peak_latency`, `area` | yes |
| `value` | the number, in the export's units | yes |
| `n_trials` | trials in the average | no, but the trial floor needs it |

The names in the export are whatever the tool wrote; `eeg.columns` maps them.
Numeric coercion happens after the rename, and every value that fails to
parse is counted in a `⚠️` line.

## Export recipes

**MNE (Python).** After `evokeds` per condition and a measurement window:

```python
rows = []
for cond, ev in evokeds.items():
    data = ev.copy().crop(tmin=0.0, tmax=0.1).data * 1e6  # volts -> microvolts
    for ch, vals in zip(ev.ch_names, data):
        rows.append({"subject": subj, "session": ses, "channel": ch,
                     "condition": cond, "measure": "mean_amplitude",
                     "value": vals.mean(), "n_trials": ev.nave})
pd.DataFrame(rows).to_csv(f"{subj}_{ses}_features.csv", index=False)
```

One CSV per participant-session is fine: the glob `eeg/*_features.csv` reads
them all and binds them.

**ERPLAB.** Measurement Tool with "mean amplitude between latencies", output
as "one measurement per line (long format)". Rename in the crosswalk:
`ERPset` → id, `chlabel` → channel, `binlabel` → condition, `value` → value.
Sessions usually live in the ERPset name; if so, ask the person to add a
`session` column to the export or split by file with a per-session glob.

**BrainVision Analyzer.** Export → Generic Data with "Peak Detection" or
"Area Information" tables, one row per marker; map `Channel`, `Marker`,
`Value` in the crosswalk and put the session in the file name.

## What is read from the files

`scripts/derive_modality_config.R` proposes the block from the export and
the recording files. BrainVision is read natively: the `.vhdr` header gives
sampling interval, channel names with their reference and unit, and the
Recorder comment block gives the amplifier and the hardware filter row (low
cutoff in seconds, high cutoff in Hz, notch); the `.vmrk` marker file gives
stimulus and response codes with their counts. BIDS sidecars add
power-line frequency, software filters, cap, manufacturer and placement
scheme; `participants.tsv` the id format; `*_events.tsv` trial types. An
ERPLAB bin descriptor gives bin labels.

Those recording parameters land in `eeg.recording` in `_config.yml`. The
pipeline never computes on them; the methods section and the
reporting-standards review (COBIDAS MEEG, ARTEM-IS) read them from there,
which keeps one source of truth.

```yaml
eeg:
  recording:
    sampling_rate_hz: 500
    n_channels: 32
    reference: "common (unnamed in header)"     # or the named reference channel
    unit: "µV"
    hardware_filters: {low_cutoff_s: 10, high_cutoff_hz: 1000, notch_hz: "Off"}
    amplifier: "BrainAmp DC amplifier"
    software: "BrainVision Data Exchange Header File Version 1.0"
    powerline_hz: 60                             # from *_eeg.json
    software_filters: {highpass: {cutoff: 0.1}}
    cap: "Easycap"
    placement_scheme: "10-20"
    source: "BrainVision header sub-001_ses-01_task-flanker_eeg.vhdr"
```

## Config

See `assets/config-modality-blocks.yml`. Points that go wrong:

- `session_map` values must be timepoint keys, and each of those timepoints
  must list `eeg` in its `modalities`.
- `features[].condition` and `channels` are matched literally against the
  export after the crosswalk; case and spacing count.
- `qc.amplitude_range_uv` is in the export's units, whatever the key says.
  If the export is in volts, either convert at export (preferred) or set the
  range accordingly and say so in the config comment.
- `id_transform` strips a prefix then zero-pads numeric IDs. It never
  changes a non-numeric ID; those show as `format-fail`.

## Stages

**01e_ingest_eeg**: files → `ingest_eeg_features()` →
`<stem>_eeg_features_latest.rds` under `data/raw/`; session table; raw value
distributions; coverage against the REDCap roster →
`output/validation/<stem>_coverage_eeg.csv`.

**02e_qc_eeg**: `eeg_qc_summary()` → `<stem>_eeg_qc.csv` and the QC tile;
`eeg_feature_table()` → `<stem>_eeg_features_wide_latest.rds` under
`data/derived/` with `eeg_qc_pass` carried along; feature distributions.

**07m_link_modalities** joins the wide table on `study_id` × `timepoint`.

## Failure modes

| Symptom | Cause | Where |
|---|---|---|
| `lacks column(s) for value` | crosswalk names an export column that is not there | `eeg.columns` |
| `format-fail` > 0 | prefix or padding differs from REDCap | `eeg.id_transform`, `eeg.id_pattern` |
| `session value(s) not in eeg.session_map` | a new session label in a re-export | `eeg.session_map` |
| every participant `flag_low_trials` | `n_trials` absent or mapped to the wrong column | `eeg.columns.n_trials` |
| every participant `flag_amplitude_oob` | units | `eeg.qc.amplitude_range_uv` or the export |
| `EEG feature 'x' matched 0 column(s)` | condition or channel label differs from export | `eeg.features` |
| `assert_expected_n` in 02e | a participant has rows with `timepoint = NA` only | `session_map` |

## Extending the module

A wide reader (`eeg.format: wide` with a `channels_are_columns: true`
flag) is a `tidyr::pivot_longer()` before the crosswalk in
`ingest_eeg_features()`, plus a test with a wide fixture. Time-frequency
adds `frequency_band` to `eeg_canonical_columns()` and to the feature
filter. Both are Mode E work with a regression test first.
