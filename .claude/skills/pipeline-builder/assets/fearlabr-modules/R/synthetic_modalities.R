# ════════════════════════════════════════════════════════════════════════
# R/synthetic_modalities.R — Config-driven fake EEG and sensor exports
# ════════════════════════════════════════════════════════════════════════
# Same contract as generate_synthetic_redcap(): build structurally faithful
# files from _config.yml alone, using the EXPORT column names and session
# labels the config declares, so the ingest crosswalk is exercised rather
# than bypassed. Values are noise; the shape is the point.
# ════════════════════════════════════════════════════════════════════════

#' Synthetic long EEG feature export, one frame, export column names.
#'
#' @param config Config list (eeg block + timepoints).
#' @param n Participants.
#' @param seed RNG seed.
generate_synthetic_eeg <- function(config, n = NULL, seed = 20250101) {
  set.seed(seed + 7L)
  eeg <- config$eeg
  if (!isTRUE(eeg$enabled)) return(NULL)
  n <- n %||% (config$study$target_n %||% 40)
  cols <- eeg$columns %||% list()
  cn <- function(k) cols[[k]] %||% k
  ids <- fearlabr_syn_ids(n, width = as.integer(eeg$id_transform$pad_width %||% 4))
  pre <- eeg$id_transform$strip_prefix %||% ""
  sched <- timepoint_schedule(config)
  tps <- sched$timepoint[purrr::map_lgl(sched$modalities, ~ "eeg" %in% .x)]
  smap <- eeg$session_map %||% stats::setNames(as.list(tps), tps)
  sessions <- names(smap)[unlist(smap) %in% tps]
  if (!length(sessions)) sessions <- tps
  feats <- eeg$features %||% list(list(name = "feature", measure = "mean_amplitude"))
  channels <- unique(c(unlist(lapply(feats, function(f) f$channels)),
                       eeg$qc$required_channels, "Cz"))
  conditions <- unique(unlist(lapply(feats, function(f) f$condition %||% "all")))
  measures <- unique(vapply(feats, function(f) f$measure %||% "mean_amplitude", character(1)))
  grid <- tidyr::expand_grid(id = ids, session = sessions, channel = channels,
                             condition = conditions, measure = measures)
  rng <- eeg$qc$amplitude_range_uv %||% c(-50, 50)
  mid <- mean(rng); sdv <- diff(rng) / 8
  out <- tibble::tibble(.rows = nrow(grid))
  out[[cn("id")]] <- paste0(pre, grid$id)
  out[[cn("session")]] <- grid$session
  out[[cn("channel")]] <- grid$channel
  out[[cn("condition")]] <- grid$condition
  out[[cn("measure")]] <- grid$measure
  out[[cn("value")]] <- round(stats::rnorm(nrow(grid), mid, sdv), 3)
  ntr <- stats::setNames(sample(8:40, n * length(sessions), replace = TRUE),
                         paste(rep(ids, each = length(sessions)), sessions))
  out[[cn("n_trials")]] <- unname(ntr[paste(grid$id, grid$session)])
  out
}

#' Synthetic day-grain export per declared sensor stream.
#'
#' @return Named list of frames, one per stream, export column names.
generate_synthetic_sensor <- function(config, n = NULL, days = 42, seed = 20250101,
                                      base_date = as.Date("2025-02-01")) {
  set.seed(seed + 11L)
  sn <- config$sensors
  if (!isTRUE(sn$enabled) || length(sn$streams) == 0) return(list())
  n <- n %||% (config$study$target_n %||% 40)
  out <- list()
  for (sk in names(sn$streams)) {
    spec <- sn$streams[[sk]]
    ids <- fearlabr_syn_ids(n, width = as.integer(spec$id_transform$pad_width %||% 4))
    pre <- spec$id_transform$strip_prefix %||% ""
    grid <- tidyr::expand_grid(id = ids, d = seq_len(days))
    # Drop ~10% of participant-days so coverage has gaps to show.
    grid <- grid[stats::runif(nrow(grid)) > 0.10, ]
    cols <- spec$columns %||% list()
    df <- tibble::tibble(.rows = nrow(grid))
    df[[cols$id %||% "id"]] <- paste0(pre, grid$id)
    if (identical(spec$grain %||% "day", "epoch")) {
      df[[cols$timestamp %||% "timestamp"]] <- format(as.POSIXct(base_date + grid$d - 1, tz = "UTC") +
                                                         sample(0:86399, nrow(grid), TRUE),
                                                       "%Y-%m-%d %H:%M:%S")
    } else {
      df[[cols$date %||% "date"]] <- format(base_date + grid$d - 1, "%Y-%m-%d")
    }
    for (m in names(spec$metrics)) {
      df[[spec$metrics[[m]]]] <- switch(
        m,
        wear_minutes = sample(c(sample(0:500, 1), sample(600:1440, 9)), nrow(grid), TRUE),
        steps = stats::rpois(nrow(grid), 6000),
        round(stats::rnorm(nrow(grid), 50, 10), 2))
    }
    out[[sk]] <- df
  }
  out
}

#' Write synthetic files for every enabled modality where the ingest expects them.
#'
#' Each glob's `*` becomes `SYNTHETIC`, so `eeg/*_features.csv` is written as
#' `eeg/SYNTHETIC_features.csv` and the real ingest glob finds it.
#'
#' @return List of written paths: eeg (or NULL) and sensors (named by stream).
generate_synthetic_modalities_from_config <- function(config, outdir = NULL, n = NULL,
                                                      seed = 20250101, days = 42) {
  outdir <- outdir %||% resolve_path(config$paths$raw_data %||% "data/raw", config)
  glob_path <- function(glob) {
    p <- file.path(outdir, sub("*", "SYNTHETIC", glob, fixed = TRUE))
    dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    p
  }
  paths <- list(eeg = NULL, sensors = list())
  eeg <- generate_synthetic_eeg(config, n = n, seed = seed)
  if (!is.null(eeg)) {
    paths$eeg <- glob_path(config$eeg$file_glob %||% "eeg/*_features.csv")
    readr::write_csv(eeg, paths$eeg, na = "")
  }
  sens <- generate_synthetic_sensor(config, n = n, seed = seed, days = days)
  for (sk in names(sens)) {
    spec <- config$sensors$streams[[sk]]
    paths$sensors[[sk]] <- glob_path(spec$file_glob %||% paste0("sensor/*_", sk, ".csv"))
    readr::write_csv(sens[[sk]], paths$sensors[[sk]], na = "")
  }
  paths
}
