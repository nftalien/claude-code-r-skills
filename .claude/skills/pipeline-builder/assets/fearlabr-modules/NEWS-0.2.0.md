# fearlabr 0.2.0 (2026-09-04)

Modality modules for the step-by-step pipeline builder. Everything below
reads its study facts from `_config.yml`; nothing is study-specific.

* `R/timepoints.R`: a study declares `timepoints.schedule` once (offset and
  window in days from an anchor, the REDCap event, the modalities expected).
  `timepoint_schedule()`, `assert_timepoints_declared()` (overlapping
  windows and unknown modalities stop), `assign_timepoint()`,
  `timepoint_coverage()` / `timepoint_coverage_summary()`,
  `plot_timepoint_completeness()`.
* `R/ingest_eeg.R`: preprocessed EEG/ERP feature tables (long export from
  MNE, EEGLAB, ERPLAB or BrainVision) into the study's ID and timepoint
  vocabulary via a declared column crosswalk and `session_map`.
  `ingest_eeg_features()`, `eeg_qc_summary()` (trial floor, amplitude
  range, required channels), `eeg_feature_table()` (a feature matching zero
  rows stops and names itself), `plot_eeg_qc()`, `plot_eeg_features()`.
  Raw signal preprocessing stays in the EEG tool; this is deliberate.
* `R/ingest_sensor.R`: passive sensor and actigraphy streams at day or epoch
  grain to canonical participant-days. `ingest_sensor_stream()`,
  `aggregate_sensor_to_day()`, `sensor_valid_days()` (the rule is a config
  string and is printed), `sensor_coverage()`,
  `link_sensor_to_timepoints()`, `plot_sensor_coverage()`. Epoch timestamps
  become local dates through the configured `sensors.tz`, never through
  `as.Date()` on a POSIXct.
* `R/pipeline_manifest.R`: `_pipeline.yml`, the stage-by-stage build record.
  Notebook helpers `builder_stage_gate()`, `builder_record_render()`,
  `builder_approve()`. `builder_stage_registry()`, `new_pipeline_manifest()`, `mark_stage()`
  (generation waits on approved dependencies; approval requires a render;
  resetting a stage resets everything downstream), `next_stage()`,
  `pipeline_status_table()`, `pipeline_dag_mermaid()`, `plot_pipeline_dag()`.
* `R/redcap_project_config.R`: propose `_config.yml` from the REDCap
  project. `redcap_project_read()` (API through an injectable transport, or
  the data dictionary, events and instrument-event mapping exports),
  `redcap_project_to_config()` (events, timepoints with offsets and windows,
  instruments with items, ranges, calc totals and subscales, conditions,
  identifiers, structural skips) with a todo table marking every value
  derived, inferred, defaulted or to ask; `redcap_config_report()`,
  `write_proposed_config()` (never overwrites `_config.yml`).
* `R/metricwire_project_config.R`: propose the `metricwire` block from the
  analysis data (API pull or cached export), the codebook (PDF or parsed
  CSV) and the choicesDataCoding export. `metricwire_project_read()`,
  `metricwire_project_to_config()` (sessions with the Missed-rows check,
  items with codebook names and declared-versus-observed ranges, prompt
  blocks by survey name, free text, safety candidates, the account field
  holding the participant ID), `metricwire_config_report()`,
  `merge_proposals()`; `metricwire_list_studies()` for GET /studies.
* `R/quicklook.R`: `summarise_render_log()`, `modality_coverage_dashboard()`
  / `plot_coverage_dashboard()`, `plot_ema_compliance_heatmap()`.
* `R/synthetic_modalities.R`: `generate_synthetic_eeg()`,
  `generate_synthetic_sensor()`, `generate_synthetic_modalities_from_config()`
  write fake exports with the export column names and session labels the
  config declares, at the paths the ingest globs read.
* Tests: `test-timepoints.R`, `test-eeg.R`, `test-sensor.R`,
  `test-manifest.R`, `test-quicklook.R`, `test-synthetic-modalities.R`,
  `test-redcap-project-config.R`, `test-metricwire-project-config.R`
  (helper `helper-builder-config.R`).
* `ggplot2` stays in Suggests; every plot function returns its table with a
  message when ggplot2 is absent.
