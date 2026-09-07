#!/usr/bin/env Rscript
# ════════════════════════════════════════════════════════════════════════
# proof_modalities.R — proof the EEG, sensor and manifest path on synthetic data
# ════════════════════════════════════════════════════════════════════════
# Companion to fearlabr-pipeline's scripts/proof_pipeline.R, which proofs the
# REDCap + EMA core. This one covers what the builder adds: the timepoint
# declaration, the EEG feature ingest and QC, each sensor stream, the
# cross-modality index, and the manifest's gating rules. Everything runs in
# proof_sandbox/ under the project root; real data/ is never touched.
#
# Usage (terminal, from the project root):
#   Rscript scripts/proof_modalities.R                # uses ./_config.yml
#   Rscript scripts/proof_modalities.R path/to/config.yml
#
# Needs fearlabr >= 0.2.0 (the modules applied). Assignments inside run_stage()
# blocks are plain `<-`: the block is a promise evaluated in the global
# environment, and `x[[i]] <<- v` from there looks past the global environment
# and fails with "object not found". A red stage names the config
# field to look at; paste the FAIL block back into the chat if it is not
# obvious.
# ════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({ library(fearlabr); library(dplyr) })
args <- commandArgs(trailingOnly = TRUE)
config_path <- if (length(args)) args[1] else "_config.yml"
if (!file.exists(config_path)) stop("No config at ", config_path)
if (utils::packageVersion("fearlabr") < "0.2.0") {
  stop("fearlabr ", utils::packageVersion("fearlabr"), " lacks the modality modules; ",
       "apply assets/fearlabr-modules first.")
}
N_SYN <- 12; DAYS <- 100

results <- list()
record <- function(stage, ok, detail = "") {
  results[[length(results) + 1L]] <<- list(stage = stage, ok = ok, detail = detail)
  cat(if (ok) "✓ PASS  " else "✗ FAIL  ", stage, "\n", sep = "")
  if (nchar(detail)) cat("        ", detail, "\n", sep = "")
}
run_stage <- function(stage, expr, hint = "") {
  tryCatch({
    detail <- force(expr)
    record(stage, TRUE, if (is.character(detail)) detail else "")
  }, error = function(e) {
    record(stage, FALSE, paste0(conditionMessage(e),
                                if (nchar(hint)) paste0("  |  likely cause: ", hint) else ""))
  })
}

cat("\n=== Proofing modality modules on synthetic data ===\n\n")
config <- read_config(config_path)
sandbox <- file.path(getwd(), "proof_sandbox")
for (k in c("raw_data", "derived", "validation", "figures", "output")) {
  config$paths[[k]] <- file.path(sandbox, config$paths[[k]] %||% k)
}
raw_dir <- config$paths$raw_data
dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)
stem <- fearlabr_file_stem(config)

run_stage("TP  timepoints declared and consistent", {
  s <- timepoint_schedule(config)
  sprintf("%d timepoint(s): %s", nrow(s), paste(s$timepoint, collapse = ", "))
}, hint = "timepoints.schedule: overlapping window_days, unknown modality, or a bad anchor")

# ── Synthetic files ─────────────────────────────────────────────────────
paths <- NULL; redcap <- NULL
run_stage("SYN synthetic REDCap + modality exports", {
  redcap <- generate_synthetic_redcap(config, n = N_SYN)
  anchor_col <- config$timepoints$anchor_date_column %||% "baseline_date"
  redcap[[anchor_col]] <- format(as.Date("2025-02-01") + sample(0:5, nrow(redcap), TRUE), "%Y-%m-%d")
  readr::write_csv(redcap, file.path(raw_dir, paste0(stem, "_SYNTHETIC_REDCAP.csv")), na = "")
  paths <- generate_synthetic_modalities_from_config(config, outdir = raw_dir, n = N_SYN, days = DAYS)
  sprintf("REDCap %d rows; eeg: %s; sensors: %s", nrow(redcap),
          if (is.null(paths$eeg)) "off" else basename(paths$eeg),
          if (length(paths$sensors)) paste(names(paths$sensors), collapse = ", ") else "off")
}, hint = "eeg.columns / eeg.session_map / sensors.streams.*.metrics malformed")

# A participant-level roster with anchor dates, as 03 would write it.
roster <- NULL
run_stage("03  roster with anchor dates (stand-in for 03_clean_redcap)", {
  id_col <- config$redcap$id_column
  anchor_col <- config$timepoints$anchor_date_column %||% "baseline_date"
  roster <- redcap |>
    mutate(study_id = as.character(.data[[id_col]])) |>
    summarise(anchor_date = as.Date(min(.data[[anchor_col]])), .by = "study_id")
  roster[[id_col]] <- roster$study_id
  roster[[anchor_col]] <- roster$anchor_date
  dir.create(config$paths$derived, recursive = TRUE, showWarnings = FALSE)
  write_latest_rds(roster, paste0(stem, "_redcap_participant_level"), config$paths$derived)
  sprintf("%d participants", nrow(roster))
})

# ── EEG ─────────────────────────────────────────────────────────────────
eeg_long <- NULL
if (isTRUE(config$eeg$enabled)) {
  run_stage("01e ingest EEG features", {
    eeg_long <- ingest_eeg_features(config, write = TRUE)
    if (any(is.na(eeg_long$timepoint))) stop("some EEG sessions did not map to a timepoint")
    sprintf("%d rows, %d participants, timepoints %s", nrow(eeg_long),
            n_distinct(eeg_long$study_id), paste(unique(eeg_long$timepoint), collapse = ", "))
  }, hint = "eeg.columns crosswalk or eeg.session_map")
  run_stage("02e EEG QC + feature table", {
    qc <- eeg_qc_summary(eeg_long, config)
    if (!all(qc$pass)) stop(sum(!qc$pass), " synthetic participant-timepoint(s) failed QC")
    ft <- eeg_feature_table(eeg_long, config)
    write_latest_rds(ft, paste0(stem, "_eeg_features_wide"), config$paths$derived)
    cov <- timepoint_coverage_summary(timepoint_coverage(ft, "study_id", "timepoint", config, "eeg",
                                                         expected_ids = roster$study_id))
    dir.create(config$paths$validation, recursive = TRUE, showWarnings = FALSE)
    readr::write_csv(cov, file.path(config$paths$validation, paste0(stem, "_coverage_eeg.csv")))
    sprintf("features: %s; coverage %s", paste(setdiff(names(ft), c("study_id", "timepoint")), collapse = ", "),
            paste(cov$timepoint, paste0(cov$n_observed, "/", cov$n_expected), collapse = ", "))
  }, hint = "eeg.qc thresholds or a feature whose measure/condition/channels match nothing")
} else cat("⏭ eeg.enabled is false; EEG stages skipped\n")

# ── Sensors ─────────────────────────────────────────────────────────────
if (isTRUE(config$sensors$enabled)) {
  for (sk in names(config$sensors$streams)) {
    run_stage(paste0("01s/02s sensor stream '", sk, "'"), {
      day <- ingest_sensor_stream(config, sk, write = TRUE)
      day <- sensor_valid_days(day, config$sensors$streams[[sk]]$valid_day_rule)
      cov <- sensor_coverage(day)
      day <- link_sensor_to_timepoints(day, roster, config)
      if (!any(!is.na(day$timepoint))) stop("no sensor day fell inside a declared timepoint window")
      write_latest_rds(day, paste0(stem, "_sensor_", sk, "_day_valid"), config$paths$derived)
      tc <- timepoint_coverage_summary(timepoint_coverage(day |> filter(valid_day), "study_id", "timepoint",
                                                          config, "sensors", expected_ids = roster$study_id))
      readr::write_csv(tc, file.path(config$paths$validation, paste0(stem, "_coverage_sensors.csv")))
      sprintf("%d participant-days, median %d valid days; coverage %s", nrow(day),
              as.integer(median(cov$n_valid_days)),
              paste(tc$timepoint, paste0(tc$n_observed, "/", tc$n_expected), collapse = ", "))
    }, hint = paste0("sensors.streams.", sk, ": columns, metrics, grain, or valid_day_rule"))
  }
} else cat("⏭ sensors.enabled is false; sensor stages skipped\n")

# ── REDCap coverage (every study has it; the dashboard never has zero panels)
run_stage("03  REDCap wave coverage", {
  id_col <- config$redcap$id_column
  ev_col <- intersect(c("redcap_event_name", "event"), names(redcap))[1]
  if (is.na(ev_col)) stop("synthetic REDCap has no redcap_event_name column")
  s <- timepoint_schedule(config)
  waves <- redcap |>
    mutate(study_id = as.character(.data[[id_col]]),
           timepoint = s$timepoint[match(.data[[ev_col]], s$redcap_event)]) |>
    filter(!is.na(.data$timepoint)) |>
    distinct(.data$study_id, .data$timepoint)
  cov <- timepoint_coverage_summary(timepoint_coverage(waves, "study_id", "timepoint", config, "redcap",
                                                       expected_ids = roster$study_id))
  dir.create(config$paths$validation, recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(cov, file.path(config$paths$validation, paste0(stem, "_coverage_redcap.csv")))
  paste(cov$timepoint, paste0(cov$n_observed, "/", cov$n_expected), collapse = ", ")
}, hint = "timepoints.schedule.*.redcap_event does not match the event names in the export")

# ── Cross-modality dashboard ────────────────────────────────────────────
run_stage("07m modality coverage dashboard", {
  files <- list.files(config$paths$validation, pattern = paste0("^", stem, "_coverage_.*\\.csv$"), full.names = TRUE)
  if (!length(files)) stop("no coverage files were written")
  dash <- modality_coverage_dashboard(lapply(files, readr::read_csv, show_col_types = FALSE))
  sprintf("%d modality x timepoint rows from %d file(s)", nrow(dash), length(files))
})

# ── Manifest gating ─────────────────────────────────────────────────────
run_stage("MAN manifest gating rules", {
  m <- new_pipeline_manifest(config)
  ok1 <- tryCatch({ mark_stage(m, "01_ingest", "generated"); FALSE }, error = function(e) TRUE)
  ok2 <- tryCatch({ mark_stage(m, "00_setup", "approved"); FALSE }, error = function(e) TRUE)
  if (!ok1 || !ok2) stop("a gate did not fire")
  m <- mark_stage(m, "00_setup", "rendered") |> mark_stage("00_setup", "approved")
  p <- file.path(sandbox, "_pipeline.yml")
  write_pipeline_manifest(m, p)
  m2 <- read_pipeline_manifest(p)
  writeLines(pipeline_dag_mermaid(m2), file.path(sandbox, "pipeline_dag.mmd"))
  if (requireNamespace("ggplot2", quietly = TRUE)) {
    ggplot2::ggsave(file.path(sandbox, "pipeline_dag.png"), plot_pipeline_dag(m2), width = 11, height = 5, dpi = 100)
  }
  sprintf("%d stages; next: %s; DAG written to proof_sandbox/", length(m2$stages), next_stage(m2))
})

# ── Summary ─────────────────────────────────────────────────────────────
cat("\n=== Summary ===\n")
n_ok <- sum(vapply(results, function(r) r$ok, logical(1)))
cat(n_ok, " of ", length(results), " stages PASS\n", sep = "")
if (n_ok < length(results)) {
  cat("\nFailed:\n")
  for (r in results) if (!r$ok) cat("  ", r$stage, ": ", r$detail, "\n", sep = "")
  quit(status = 1)
}
cat("\nGreen. Delete proof_sandbox/ and build the first stage with the builder.\n")
