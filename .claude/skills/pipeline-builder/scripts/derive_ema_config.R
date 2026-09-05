#!/usr/bin/env Rscript
# ════════════════════════════════════════════════════════════════════════
# derive_ema_config.R — propose the metricwire block from MetricWire itself
# ════════════════════════════════════════════════════════════════════════
# Companion to derive_config.R (REDCap). Reads each session's analysis data
# (API pull when the keyring holds the client credentials and the sessions
# have analysis_ids; otherwise the cached export under data/raw or a file
# you name), the codebook (dashboard PDF or the parsed items CSV) and, when
# you have it, the choicesDataCoding export. Writes or updates
# `_config.proposed.yml` and `metadata/config_todo.csv`; never touches
# `_config.yml`.
#
# Usage (terminal, from the project root):
#
#   # API: metricwire.sessions[*].analysis_id + keyring credentials in _config.yml
#   Rscript scripts/derive_ema_config.R \
#       --codebook period_1=metadata/period_1_codebook.pdf --codebook period_2=metadata/period_2_codebook.pdf
#
#   # Files: name each session's export explicitly
#   Rscript scripts/derive_ema_config.R \
#       --data period_1=data/raw/period_1_api_raw.csv --data period_2=data/raw/period_2_api_raw.csv \
#       --codebook period_1=metadata/codebook_items.csv --coding period_1=metadata/choices_coding.csv \
#       --id-pattern '^[0-9]{4}$'
#
# Repeat --data / --codebook / --coding once per session (key=path).
# ════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({ library(fearlabr) })
args <- commandArgs(trailingOnly = TRUE)
kv <- function(flag) {
  i <- which(args == flag); if (!length(i)) return(NULL)
  vals <- args[i + 1]
  out <- lapply(strsplit(vals, "=", fixed = TRUE), function(p) p[2]); names(out) <- vapply(strsplit(vals, "=", fixed = TRUE), `[`, character(1), 1)
  out
}
one <- function(flag, default = NULL) { i <- which(args == flag); if (length(i)) args[i + 1] else default }

config <- if (file.exists("_config.yml")) read_config("_config.yml") else NULL
proposed_path <- "_config.proposed.yml"
prior <- if (file.exists(proposed_path)) {
  list(config = yaml::read_yaml(proposed_path),
       todo = if (file.exists("metadata/config_todo.csv")) readr::read_csv("metadata/config_todo.csv", show_col_types = FALSE) else tibble::tibble(),
       source = "prior")
} else NULL
base_cfg <- config %||% prior$config

project <- metricwire_project_read(config = base_cfg, data = kv("--data"), codebooks = kv("--codebook"), coding = kv("--coding"))
proposal <- metricwire_project_to_config(project, config = base_cfg, id_pattern = one("--id-pattern", "^[0-9]{3,6}$"))
metricwire_config_report(proposal)

final <- if (!is.null(prior)) merge_proposals(prior, proposal) else proposal
write_proposed_config(final, dir = ".")
cat("\nNext: walk metadata/config_todo.csv (the metricwire rows), set gates, safety_min per item and the battery map,\n",
    "then merge _config.proposed.yml into _config.yml and run scripts/proof_pipeline.R\n", sep = "")
