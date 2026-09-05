#!/usr/bin/env Rscript
# ════════════════════════════════════════════════════════════════════════
# derive_config.R — propose _config.yml from the REDCap project itself
# ════════════════════════════════════════════════════════════════════════
# Reads the project's events, instrument-event mapping and data dictionary
# (API when the keyring holds a token, exported files otherwise) and writes
# `_config.proposed.yml` plus `metadata/config_todo.csv`. It never touches
# `_config.yml`; the proposal is reviewed against the todo table and merged
# by hand or in the chat.
#
# Usage (terminal, from the project root):
#
#   # API: needs redcap.project_url and the keyring keys in a minimal _config.yml,
#   # or REDCAP_API_URL + REDCAP_API_TOKEN in the environment.
#   Rscript scripts/derive_config.R mystudy
#
#   # Files: the three exports from Project Setup (mapping optional).
#   Rscript scripts/derive_config.R mystudy --dict metadata/DataDictionary.csv \
#       --events metadata/events.csv --map metadata/instrument_event_map.csv
# ════════════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({ library(fearlabr) })
args <- commandArgs(trailingOnly = TRUE)
opt <- function(flag) { i <- match(flag, args); if (is.na(i) || i == length(args)) NULL else args[i + 1] }
positional <- args[!grepl("^--", args) & !seq_along(args) %in% (match(c("--dict", "--events", "--map"), args) + 1)]
study_name <- if (length(positional)) positional[1] else NULL

files <- NULL
if (!is.null(opt("--dict"))) {
  files <- list(data_dictionary = opt("--dict"), events = opt("--events"), instrument_event_map = opt("--map"))
  if (is.null(files$events)) stop("--events is required with --dict")
}

config <- if (file.exists("_config.yml")) read_config("_config.yml") else NULL
url <- Sys.getenv("REDCAP_API_URL", unset = "")
token <- Sys.getenv("REDCAP_API_TOKEN", unset = "")
project <- if (!is.null(files)) {
  redcap_project_read(files = files)
} else if (nzchar(url) && nzchar(token)) {
  redcap_project_read(url = url, token = token)
} else if (!is.null(config) && fearlabr_has_redcap_credential(config)) {
  redcap_project_read(config = config)
} else {
  stop("No REDCap token found (keyring keys in _config.yml, or REDCAP_API_URL/REDCAP_API_TOKEN) ",
       "and no --dict/--events files given. Download the exports from Project Setup and pass them.")
}
rm(token)

proposal <- redcap_project_to_config(project, study_name = study_name %||% config$study$name)
redcap_config_report(proposal)
write_proposed_config(proposal, dir = ".")
cat("\nNext: review metadata/config_todo.csv, merge _config.proposed.yml into _config.yml, then\n",
    "  Rscript scripts/proof_pipeline.R\n", sep = "")
