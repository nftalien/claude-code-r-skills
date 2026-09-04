# The pipeline manifest and the stage contract addendum

## `_pipeline.yml`

Written by `new_pipeline_manifest(config)`, updated by `mark_stage()` and the
notebook helpers. Kept in version control next to `_config.yml`.

```yaml
study: mmx
created_at: "2026-09-04T14:02:11"
modalities: [redcap, eeg, sensors]
timepoints: [baseline, week4, week12]
stages:
  - id: 01e_ingest_eeg
    label: Ingest EEG features
    modality: eeg
    qmd: 01e_ingest_eeg.qmd
    depends_on: [00_setup]
    verify: "ID audit; session -> timepoint map; unmapped sessions"
    status: approved            # planned | generated | rendered | approved | failed
    render: output/renders/01e_ingest_eeg.html
    notes: "format-fail 0; two sessions mapped"
    updated_at: "2026-09-04T15:10:40"
    approved_at: "2026-09-04T15:10:40"
```

### Rules

1. `mark_stage(m, id, "generated")` stops unless every `depends_on` is
   `approved`. Same check in the notebook via `builder_stage_gate(id)`.
2. `mark_stage(m, id, "approved")` stops unless the stage is `rendered`
   (`force = TRUE` overrides, for stand-ins and migrations; always leave a
   note).
3. Setting a stage to `planned` or `failed` resets every stage downstream of
   it to `planned` with a note naming the upstream stage.
4. `next_stage(m)` is the first unapproved stage in registry order whose
   dependencies are all approved; `NULL` when the build is done.

### Stage registry

`builder_stage_registry()` is the single list of stages, with modality,
dependencies and the `verify` string. `new_pipeline_manifest()` keeps the
rows whose modality is `core`, `multi`, `analysis` or one of the study's
enabled modalities, and adds to 07m's dependencies the last stage of each
enabled non-REDCap modality (`07_link_redcap_ema`, `02e_qc_eeg`,
`02s_qc_sensor`). Add a row when a modality adds a stage; nothing else needs
to change for the DAG, the status table and `next_stage()` to know it.

### Functions

| Function | Use |
|---|---|
| `new_pipeline_manifest(config, modalities = NULL, include_analysis = TRUE)` | build |
| `read_pipeline_manifest(path)`, `write_pipeline_manifest(m, path)` | persist |
| `manifest_stages_tbl(m)`, `pipeline_status_table(m)` | tabular views |
| `mark_stage(m, id, status, note, render, force)` | every status change |
| `assert_stage_ready(m, id)`, `next_stage(m)`, `invalidate_downstream(m, id)` | the rules |
| `pipeline_dag_mermaid(m)`, `pipeline_dag_layout(m)`, `plot_pipeline_dag(m)` | the picture |
| `builder_stage_gate(id)`, `builder_record_render(id)`, `builder_approve(id, note)` | in notebooks and the console |

The chat shows the DAG by pasting `pipeline_dag_mermaid(m)` inside a
```` ```mermaid ```` fence. The project shows it through 00b with
`plot_pipeline_dag()` (ggplot2) and writes the Mermaid source to
`output/pipeline_dag.mmd` for the README.

## Stage contract addendum

Everything in fearlabr-pipeline's `references/stage-contract.md` holds. The
builder adds these stages, files and gates. `<stem>` is
`fearlabr_file_stem(config)`.

### 00_setup (additions)
- **gates**: `packageVersion("fearlabr") >= "0.2.0"`;
  `assert_timepoints_declared(config)`.
- **shows**: `timepoint_schedule(config)`.

### 00b_pipeline_status
- **in**: `_pipeline.yml`; `output/validation/<stem>_coverage_*.csv` if any.
- **out**: `output/pipeline_dag.mmd`.
- **teaches**: the two manifest rules; blue means a person looked.

### 01e_ingest_eeg
- **in**: files matching `eeg.file_glob` under `paths.raw_data`;
  `<stem>_redcap_participant_level_latest.rds` if present (roster).
- **out**: `data/raw/<stem>_eeg_features_latest.rds`;
  `output/validation/<stem>_coverage_eeg.csv`;
  `output/figures/<stem>_eeg_raw_values.png`.
- **gates**: required crosswalk columns; `id_audit_line` with `eeg.id_pattern`;
  unmapped sessions warned.

### 02e_qc_eeg
- **in**: `<stem>_eeg_features_latest.rds`.
- **out**: `data/derived/<stem>_eeg_features_wide_latest.rds` (+ versioned);
  `output/validation/<stem>_eeg_qc.csv`;
  `output/figures/<stem>_eeg_qc.png`, `<stem>_eeg_features.png`.
- **gates**: `assert_nonzero_match` per feature (inside
  `eeg_feature_table()`); `assert_expected_n` on participants after the
  reduction.

### 01s_ingest_sensor
- **in**: per stream, files matching its `file_glob`.
- **out**: `data/raw/<stem>_sensor_<stream>_day_latest.rds` per stream;
  `output/figures/<stem>_sensor_<stream>_observed.png`.
- **gates**: required id/date/timestamp and metric columns;
  `id_audit_line` per stream with `id_pattern`; unparseable dates and
  duplicated days counted.

### 02s_qc_sensor
- **in**: the day tables; `<stem>_redcap_participant_level_latest.rds` with
  `timepoints.anchor_date_column`.
- **out**: `data/derived/<stem>_sensor_<stream>_day_valid_latest.rds` (+
  versioned); `output/validation/<stem>_sensor_<stream>_coverage.csv`,
  `<stem>_coverage_sensors.csv`; `output/figures/<stem>_sensor_<stream>_valid.png`.
- **gates**: rule non-empty and evaluates to one logical per row; anchor
  column present when a roster exists.

### 03_clean_redcap (addition)
- **shows**: `timepoint_coverage()` for `redcap` from the assessment-level
  file through `redcap_event` → timepoint; writes
  `output/validation/<stem>_coverage_redcap.csv`.

### 05_clean_ema (addition)
- **shows**: `plot_ema_compliance_heatmap()` on the clean event file.

### 07m_link_modalities
- **in**: `<stem>_redcap_participant_level_latest.rds` (required);
  `<stem>_redcap_assessment_long_latest.rds`; `<stem>_ema_week_linked_latest.rds`
  or `<stem>_ema_event_analysis_latest.rds`; `<stem>_eeg_features_wide_latest.rds`;
  `<stem>_sensor_<stream>_day_valid_latest.rds`.
- **out**: `data/derived/<stem>_multimodal_index_latest.rds`
  (participant × timepoint with `has_<modality>`);
  `data/derived/<stem>_multimodal_linked_latest.rds`;
  `output/validation/<stem>_modality_id_formats.csv`,
  `<stem>_modality_id_only_in_each.csv`, `<stem>_modality_coverage.csv`;
  `output/figures/<stem>_modality_coverage.png`.
- **gates**: `id_audit_line` per source; format-inventory length warning;
  `assert_expected_n` on the index (participants) and the linked table
  (rows).
- **teaches**: format drift is the mechanism behind a silent under-join;
  a participant-level table repeats across timepoints by design.

### 07c_id_audit, 08, 10
Depend on 07m in the builder's registry (07c reads the same sources; 08 and
10 read `<stem>_multimodal_linked_latest.rds` when more than REDCap is on,
the fearlabr week-linked file otherwise).
