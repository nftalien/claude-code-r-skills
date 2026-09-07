# Shiny front end: what wraps what

The chat is the first interface; the app is the second. Everything the loop
does goes through package functions so that the app is a thin layer. This
file is the map, not the build. Build it when at least one study has gone
through the chat loop end to end, so the pages reflect what people actually
did.

## Pages and the functions behind them

| Page | UI | Calls |
|---|---|---|
| Study | form for study identity, arms, REDCap basics | writes the fearlabr blocks of `_config.yml` |
| Timepoints | editable table: key, label, offset, window lo/hi, REDCap event, modality checkboxes | `assert_timepoints_declared()` on save; `timepoint_schedule()` preview |
| Modalities | toggles for EMA, EEG, sensors; per-modality sub-forms | writes `metricwire`, `eeg`, `sensors` blocks |
| Files | drop zone per modality; header preview; crosswalk editor pre-filled from the header | `builder_glob_files()`; `readr::read_csv(n_max = 5)`; writes `columns` / `metrics` |
| Proof | run button; PASS/FAIL list | `system2("Rscript", "scripts/proof_modalities.R")` and the core proof |
| Build | stage cards from the manifest: status chip, `verify` text, Generate / Render / Approve buttons; render shown in an iframe | `manifest_stages_tbl()`, `next_stage()`, `mark_stage()`, `quarto render` via `system2`, `builder_approve()` |
| Status | DAG and coverage dashboard | `plot_pipeline_dag()` or `DiagrammeR::mermaid(pipeline_dag_mermaid())`; `modality_coverage_dashboard()` from the CSVs |
| Triage | the render's `⚠️` lines and the failure note; a link to the failing chunk | `summarise_render_log()` |

## Rules the app must keep

- The Generate button is disabled unless `assert_stage_ready()` passes.
- The Approve button is disabled unless the stage is `rendered` and the
  iframe has been opened at least once in this session.
- Editing the config after an approval calls `mark_stage(..., "planned")`
  on the first stage that reads the edited block; the cards downstream go
  grey and say why.
- The app never writes into `data/`; it runs the same notebooks the terminal
  runs.

## Packaging

`fearlabr::run_builder()` in a `shiny/` directory inside the package
(Suggests: shiny, bslib, DT, DiagrammeR). Templates are read from the skill's
`assets/qmd-templates/` and fearlabr-pipeline's reference study, which means
the skill directories need to be locatable from R; a `FEARLABR_SKILLS`
environment variable or a `builder.skill_root` config key is the simplest
contract.

## What it does not do

It does not replace the interview's judgment calls (which rule, which
window), and it does not diagnose a failed render. Those stay with a person
and, when they want it, the chat.
