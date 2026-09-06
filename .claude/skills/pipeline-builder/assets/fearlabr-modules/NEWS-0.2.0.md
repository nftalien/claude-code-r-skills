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
* `R/id_repairs.R`: a participant whose id was mistyped into a collection app
  has real data under a label nothing joins on. Dropping those rows loses a
  participant; rewriting them in a cleaning script leaves no trace of a change
  to identifiers. So repairs are declared in `metadata/id_repairs.csv`
  (from_id, to_id, source, reason) and applied by `apply_id_repairs()`, which
  prints every rewrite with its row count and warns when a repair matches
  nothing. `read_id_repairs()` refuses a repair to a non-existent id, an id
  mapped to itself, a duplicate, or one without a reason.
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
  Before the first pull, the dashboard's Data Import templates
  (`metricwire_read_import_templates()`, header-only CSVs, one per survey)
  give the prompt blocks. A codebook column `canonical_name` fixes an
  item's name across re-derivations. Clock-time questions go to
  `time_fields` and select-all questions to `multi_select_fields`, not to
  the scored items. Survey copies of one question (`quest_<q>_<survey>`)
  are one item with every column in `raw`; when the copies are coded
  differently (0-4 in one battery, 1-5 in the other) the range is an ask.
* `R/metricwire_codebook_pdf.R`: `parse_metricwire_codebook_pdf()` reads a
  real dashboard codebook PDF (pdftools, layout preserved): the Question
  Level Response Variables table (variable codes that wrap over two or
  three lines, LIKERT rows without a format cell, columns that drift
  between pages), the Breakdown of Each Question (display conditions
  become item gates through `mw_resolve_gates()`, question groups,
  response required) and the trigger table; study id and survey summary
  are attributes. `metricwire_read_codebook()` dispatches on the `%PDF`
  magic bytes, so the text-blob parser still serves the older codebooks.
  Field groups are headers: their children only appear as export columns.
* `R/eeg_project_config.R`: propose the `eeg` block from the files. Readers
  for the feature export (`eeg_detect_columns()`, wide-layout detection),
  BrainVision `.vhdr` / `.vmrk` (`brainvision_read_vhdr()`,
  `brainvision_read_vmrk()`, `brainvision_marker_summary()`), BIDS
  `*_eeg.json`, `participants.tsv`, `*_events.tsv`, and an ERPLAB bin
  descriptor. `eeg_project_to_config()` derives the crosswalk, id transform,
  session map against the declared timepoints, feature candidates, QC
  thresholds from the distributions (marked default) and an `eeg.recording`
  block (sampling rate, channels, reference, filters, amplifier, software)
  kept in the config as the one source of truth for the methods section.
* `R/sensor_project_config.R`: propose the `sensors` block from the exports.
  `sensor_read_export()` parses ActiGraph and GENEActiv preambles and reads
  plain tables (Fitbit, Garmin, Oura, AWARE, Beiwe, mindLAMP);
  `sensor_detect_columns()` and `sensor_detect_grain()`;
  `sensor_project_to_config()` derives one stream per export shape with
  glob, grain and epoch length, columns, metrics, aggregation defaults, a
  valid-day rule with the fraction of days it keeps, the id transform and
  the device block; the time zone is asked unless configured.
* `R/quicklook.R`: `summarise_render_log()`, `modality_coverage_dashboard()`
  / `plot_coverage_dashboard()`, `plot_ema_compliance_heatmap()`.
* `R/synthetic_modalities.R`: `generate_synthetic_eeg()`,
  `generate_synthetic_sensor()`, `generate_synthetic_modalities_from_config()`
  write fake exports with the export column names and session labels the
  config declares, at the paths the ingest globs read.
* Tests: `test-timepoints.R`, `test-eeg.R`, `test-sensor.R`,
  `test-manifest.R`, `test-quicklook.R`, `test-synthetic-modalities.R`,
  `test-redcap-project-config.R`, `test-metricwire-project-config.R`, `test-eeg-project-config.R`, `test-sensor-project-config.R`
  (helper `helper-builder-config.R`).
* `ggplot2` stays in Suggests; every plot function returns its table with a
  message when ggplot2 is absent.
