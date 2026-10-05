#!/usr/bin/env Rscript
# ════════════════════════════════════════════════════════════════════════
# derive_modality_config.R — propose the eeg and sensors blocks from the files
# ════════════════════════════════════════════════════════════════════════
# Companion to derive_config.R (REDCap) and derive_ema_config.R (MetricWire).
# There is no metadata system for EEG or sensors; the files are the
# metadata. Reads the feature export, BrainVision .vhdr/.vmrk, BIDS
# sidecars and an ERPLAB bin descriptor for EEG; the vendor exports for
# sensors. Writes or updates `_config.proposed.yml` and
# `metadata/config_todo.csv`; never touches `_config.yml`.
#
# Usage (terminal, from the project root; every flag optional):
#
#   Rscript scripts/derive_modality_config.R \
#       --eeg-export 'data/raw/eeg/*_features.csv' \
#       --vhdr 'data/raw/eeg/*.vhdr' --vmrk 'data/raw/eeg/*.vmrk' \
#       --eeg-json 'data/raw/eeg/*_eeg.json' --participants data/raw/eeg/participants.tsv \
#       --events 'data/raw/eeg/*_events.tsv' --bins metadata/flanker_bins.txt \
#       --sensor accel='data/raw/sensor/*_actigraph_daily.csv' --sensor sleep=data/raw/sensor/fitbit_sleep.csv
#
#   With no --sensor flags every CSV under data/raw/sensor is read and grouped
#   into one stream per distinct column set. Quote globs so the shell does not
#   expand them.
# ════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({ library(fearlabr) })
args <- commandArgs(trailingOnly = TRUE)
one <- function(flag) { i <- which(args == flag); if (length(i)) args[i + 1] else NULL }
many <- function(flag) { i <- which(args == flag); if (!length(i)) return(NULL); v <- args[i + 1]; sp <- strsplit(v, "=", fixed = TRUE); out <- lapply(sp, function(p) p[2]); names(out) <- vapply(sp, `[`, character(1), 1); out }

config <- if (file.exists("_config.yml")) read_config("_config.yml") else NULL
proposed_path <- "_config.proposed.yml"
prior <- if (file.exists(proposed_path)) list(config = yaml::read_yaml(proposed_path),
  todo = if (file.exists("metadata/config_todo.csv")) readr::read_csv("metadata/config_todo.csv", show_col_types = FALSE) else tibble::tibble(), source = "prior") else NULL
base_cfg <- config %||% prior$config
final <- prior

eeg_args <- list(exports = one("--eeg-export"), vhdr = one("--vhdr"), vmrk = one("--vmrk"), eeg_json = one("--eeg-json"),
                 participants = one("--participants"), events = one("--events"), bin_descriptor = one("--bins"), trial_counts = one("--trial-counts"))
if (any(!vapply(eeg_args, is.null, logical(1))) || isTRUE(base_cfg$eeg$enabled)) {
  eeg_project <- tryCatch(do.call(eeg_project_read, c(list(config = base_cfg), eeg_args)), error = function(e) { cat("⏭ EEG: ", conditionMessage(e), "\n", sep = ""); NULL })
  if (!is.null(eeg_project)) {
    roster <- NULL
    rp <- if (!is.null(base_cfg)) file.path(resolve_path(base_cfg$paths$derived %||% "data/derived", base_cfg), paste0(fearlabr_file_stem(base_cfg), "_redcap_participant_level_latest.rds")) else ""
    if (file.exists(rp)) { r <- readRDS(rp); roster <- as.character(r[[base_cfg$redcap$id_column]]) }
    eeg_prop <- eeg_project_to_config(eeg_project, config = base_cfg, redcap_ids = roster)
    eeg_config_report(eeg_prop)
    final <- if (is.null(final)) eeg_prop else merge_proposals(final, eeg_prop)
  }
}

sensor_files <- many("--sensor")
sensor_dir <- if (!is.null(base_cfg)) file.path(resolve_path(base_cfg$paths$raw_data %||% "data/raw", base_cfg), "sensor") else "data/raw/sensor"
if (!is.null(sensor_files) || dir.exists(sensor_dir) || isTRUE(base_cfg$sensors$enabled)) {
  sp <- tryCatch(sensor_project_read(config = if (is.null(sensor_files) && isTRUE(base_cfg$sensors$enabled)) base_cfg else NULL,
                                     files = sensor_files, raw_dir = sensor_dir),
                 error = function(e) { cat("⏭ Sensors: ", conditionMessage(e), "\n", sep = ""); NULL })
  if (!is.null(sp)) {
    s_prop <- sensor_project_to_config(sp, config = base_cfg)
    sensor_config_report(s_prop)
    final <- if (is.null(final)) s_prop else merge_proposals(final, s_prop)
  }
}
if (is.null(final)) stop("Nothing was derived: give --eeg-export / --vhdr / --sensor flags or drop files under data/raw/eeg and data/raw/sensor.")
write_proposed_config(final, dir = ".")
cat("\nNext: walk metadata/config_todo.csv (eeg and sensors rows): which timepoints expect each modality, the features the\n",
    "plan names and their window_ms, the QC thresholds and valid-day rule to keep, and the time zone. Then merge into _config.yml\n",
    "and run scripts/proof_modalities.R\n", sep = "")
