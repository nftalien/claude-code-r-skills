# ════════════════════════════════════════════════════════════════════════
# R/ingest_eeg.R — EEG / ERP feature-table ingest and QC
# ════════════════════════════════════════════════════════════════════════
# Scope, stated plainly: this module does NOT preprocess EEG. Filtering,
# epoching, artifact rejection and averaging happen in MNE, EEGLAB, ERPLAB
# or BrainVision Analyzer, where the tooling is mature. What arrives here is
# the preprocessed export those tools produce: a long table with one row per
# participant x session x channel x condition x measure. This module puts
# that table into the study's ID and timepoint vocabulary, gates it on the
# QC the export carries (trial counts, amplitude range, required channels),
# and reduces it to the features the analysis plan names.
#
# Config block:
#
#   eeg:
#     enabled: true
#     format: long                       # the only format in 0.2.0
#     file_glob: "eeg/*_features.csv"    # under paths.raw_data
#     columns: {id: subject, session: session, channel: channel,
#               condition: condition, measure: measure, value: value,
#               n_trials: n_trials}      # export name per canonical column
#     id_transform: {strip_prefix: "sub-", pad_width: 4}
#     id_pattern: "^[0-9]{4}$"
#     session_map: {"ses-01": baseline, "ses-02": week4}   # export -> timepoint
#     features:
#       - {name: ern, measure: mean_amplitude, condition: error,
#          channels: [FCz, Cz], window_ms: [0, 100]}
#     qc:
#       min_trials: 6
#       amplitude_range_uv: [-50, 50]
#       required_channels: [FCz, Cz]
# ════════════════════════════════════════════════════════════════════════

eeg_canonical_columns <- function() {
  c(id = "study_id", session = "eeg_session", channel = "channel",
    condition = "condition", measure = "measure", value = "value",
    n_trials = "n_trials")
}

#' Resolve a raw-data glob to files, relative to paths.raw_data.
builder_glob_files <- function(config, glob) {
  raw_dir <- resolve_path(config$paths$raw_data %||% "data/raw", config)
  sub <- dirname(glob)
  dir <- if (identical(sub, ".")) raw_dir else file.path(raw_dir, sub)
  if (!dir.exists(dir)) return(character(0))
  list.files(dir, pattern = utils::glob2rx(basename(glob)), full.names = TRUE)
}

#' Bring a modality's participant IDs into the study's format.
#'
#' BIDS-style exports carry `sub-0012`; REDCap holds `0012` or `12`. The
#' transform strips a declared prefix and zero-pads purely numeric IDs to a
#' declared width. Anything else is left alone so a genuinely odd ID shows
#' up in the format check instead of being silently reshaped.
#'
#' @param x Character vector of IDs.
#' @param transform List with optional strip_prefix and pad_width.
eeg_normalize_id <- function(x, transform = NULL) {
  x <- trimws(as.character(x))
  pre <- transform$strip_prefix %||% ""
  if (nzchar(pre)) x <- sub(paste0("^", pre), "", x)
  w <- transform$pad_width
  if (!is.null(w)) {
    num <- !is.na(x) & grepl("^[0-9]+$", x)
    x[num] <- formatC(as.integer(x[num]), width = as.integer(w), flag = "0")
  }
  x
}

#' Read the EEG feature export(s) into the canonical long table.
#'
#' @param config Config list.
#' @param files Optional explicit file paths; default resolves eeg.file_glob.
#' @param write Persist `<stem>_eeg_features_latest.rds` under paths.raw_data?
#' @return Tibble: study_id, eeg_session, timepoint, channel, condition,
#'   measure, value, n_trials, source_file.
ingest_eeg_features <- function(config, files = NULL, write = TRUE) {
  eeg <- config$eeg
  if (!isTRUE(eeg$enabled)) stop("eeg.enabled is not true in _config.yml.", call. = FALSE)
  fmt <- eeg$format %||% "long"
  if (!identical(fmt, "long")) {
    stop("eeg.format '", fmt, "' is not supported; export a long feature table ",
         "(one row per participant x session x channel x condition x measure).",
         call. = FALSE)
  }
  files <- files %||% builder_glob_files(config, eeg$file_glob %||% "eeg/*.csv")
  if (length(files) == 0) {
    stop("[ingest_eeg_features] no files match eeg.file_glob '", eeg$file_glob,
         "' under ", config$paths$raw_data, ".", call. = FALSE)
  }
  cols <- eeg$columns %||% list()
  canon <- eeg_canonical_columns()
  required <- c("id", "channel", "measure", "value")

  frames <- lapply(files, function(f) {
    df <- readr::read_csv(f, show_col_types = FALSE,
                          col_types = readr::cols(.default = readr::col_character()),
                          name_repair = "minimal")
    present <- vapply(names(canon), function(k) (cols[[k]] %||% k) %in% names(df), logical(1))
    miss <- names(canon)[!present & names(canon) %in% required]
    if (length(miss)) {
      stop("[ingest_eeg_features] ", basename(f), " lacks column(s) for ",
           paste(miss, collapse = ", "), " (export names: ",
           paste(vapply(miss, function(k) cols[[k]] %||% k, character(1)), collapse = ", "),
           "). Fix eeg.columns in _config.yml.", call. = FALSE)
    }
    out <- tibble::tibble(.rows = nrow(df))
    for (k in names(canon)) {
      src <- cols[[k]] %||% k
      out[[canon[[k]]]] <- if (src %in% names(df)) df[[src]] else NA_character_
    }
    out$source_file <- basename(f)
    out
  })
  long <- dplyr::bind_rows(frames)

  # IDs into the study vocabulary, then the boundary print.
  long$study_id <- eeg_normalize_id(long$study_id, eeg$id_transform)
  id_audit_line(long$study_id, "EEG raw", pattern = eeg$id_pattern)

  # Sessions map to declared timepoints. An unmapped session is reported,
  # not dropped: the row survives with timepoint NA so the QC stage shows it.
  smap <- eeg$session_map %||% list()
  long$timepoint <- if (length(smap)) {
    unname(unlist(smap)[long$eeg_session])
  } else long$eeg_session
  unmapped <- unique(long$eeg_session[is.na(long$timepoint) & !is.na(long$eeg_session)])
  if (length(unmapped)) {
    warning("[ingest_eeg_features] session value(s) not in eeg.session_map: ",
            paste(unmapped, collapse = ", "), call. = FALSE)
  }

  # Deferred numeric coercion, with the failure count made visible.
  val <- suppressWarnings(as.numeric(long$value))
  n_bad <- sum(is.na(val) & !is.na(long$value))
  if (n_bad > 0) cat("⚠️ ", n_bad, " EEG value(s) were not numeric and became NA\n", sep = "")
  long$value <- val
  long$n_trials <- suppressWarnings(as.integer(long$n_trials))

  long <- long |>
    dplyr::select(dplyr::all_of(c("study_id", "eeg_session", "timepoint", "channel",
                                  "condition", "measure", "value", "n_trials", "source_file")))
  attr(long, "source") <- paste0("eeg:", paste(basename(files), collapse = ";"))

  if (isTRUE(write)) {
    write_latest_rds(long, paste0(fearlabr_file_stem(config), "_eeg_features"),
                     resolve_path(config$paths$raw_data %||% "data/raw", config))
  }
  long
}

#' Per participant x timepoint QC verdict from the export's own metadata.
#'
#' @param eeg_long Output of ingest_eeg_features().
#' @param config Config list.
#' @return Tibble with n_rows, n_channels, min_trials, n_oob,
#'   n_missing_channels, the three flags, and pass.
eeg_qc_summary <- function(eeg_long, config) {
  qc <- config$eeg$qc %||% list()
  rng <- qc$amplitude_range_uv %||% c(-Inf, Inf)
  req <- as.character(qc$required_channels %||% character(0))
  min_tr <- qc$min_trials %||% 0

  eeg_long |>
    dplyr::summarise(
      n_rows = dplyr::n(),
      n_channels = dplyr::n_distinct(.data$channel),
      min_trials = if (all(is.na(.data$n_trials))) NA_integer_ else min(.data$n_trials, na.rm = TRUE),
      n_oob = sum(!is.na(.data$value) & (.data$value < rng[1] | .data$value > rng[2])),
      n_missing_channels = length(setdiff(req, unique(.data$channel))),
      .by = c("study_id", "timepoint")
    ) |>
    dplyr::mutate(
      flag_low_trials = !is.na(.data$min_trials) & .data$min_trials < min_tr,
      flag_amplitude_oob = .data$n_oob > 0,
      flag_missing_channels = .data$n_missing_channels > 0,
      pass = !(.data$flag_low_trials | .data$flag_amplitude_oob | .data$flag_missing_channels)
    ) |>
    dplyr::arrange(.data$study_id, .data$timepoint)
}

#' Reduce the long table to the configured features, one column each.
#'
#' Each feature is the mean of `value` over its channels for its measure and
#' condition, per participant x timepoint. A feature that matches zero rows
#' stops the run and names itself: the alternative is a column of NA that
#' looks like missing data rather than a config error.
#'
#' @return Tibble study_id, timepoint, <one column per feature>.
eeg_feature_table <- function(eeg_long, config) {
  feats <- config$eeg$features
  if (is.null(feats) || length(feats) == 0) {
    stop("[eeg_feature_table] eeg.features is empty; declare at least one feature.",
         call. = FALSE)
  }
  pieces <- lapply(feats, function(f) {
    sel <- eeg_long |>
      dplyr::filter(.data$measure == f$measure,
                    is.null(f$condition) | .data$condition %in% f$condition,
                    is.null(f$channels) | .data$channel %in% f$channels)
    assert_nonzero_match(nrow(sel) > 0, label = paste0("EEG feature '", f$name, "'"))
    sel |>
      dplyr::summarise(value = mean(.data$value, na.rm = TRUE),
                       .by = c("study_id", "timepoint")) |>
      dplyr::mutate(feature = f$name)
  })
  dplyr::bind_rows(pieces) |>
    tidyr::pivot_wider(names_from = "feature", values_from = "value") |>
    dplyr::arrange(.data$study_id, .data$timepoint)
}

#' Participant x timepoint QC tile plot.
plot_eeg_qc <- function(qc) {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    message("ggplot2 not installed; returning the QC table instead.")
    return(invisible(qc))
  }
  qc <- qc |>
    dplyr::mutate(verdict = dplyr::case_when(
      .data$pass ~ "pass",
      .data$flag_missing_channels ~ "missing channels",
      .data$flag_low_trials ~ "low trials",
      .data$flag_amplitude_oob ~ "amplitude out of range",
      TRUE ~ "flagged"))
  ggplot2::ggplot(qc, ggplot2::aes(x = .data$timepoint, y = .data$study_id,
                                   fill = .data$verdict)) +
    ggplot2::geom_tile(colour = "white") +
    ggplot2::scale_fill_manual(values = c(pass = "#2A6F97", `missing channels` = "#B8336A",
                                          `low trials` = "#E9A03B",
                                          `amplitude out of range` = "#8E5572",
                                          flagged = "#999999"), name = NULL) +
    ggplot2::labs(x = NULL, y = "Participant") +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(axis.text.y = ggplot2::element_text(size = 6),
                   panel.grid = ggplot2::element_blank())
}

#' Feature distributions by timepoint (one panel per feature).
plot_eeg_features <- function(feature_table) {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    message("ggplot2 not installed; returning the feature table instead.")
    return(invisible(feature_table))
  }
  long <- feature_table |>
    tidyr::pivot_longer(-c("study_id", "timepoint"), names_to = "feature", values_to = "value")
  ggplot2::ggplot(long, ggplot2::aes(x = .data$timepoint, y = .data$value)) +
    ggplot2::geom_boxplot(outlier.size = 0.8, fill = "#DCE9F2") +
    ggplot2::facet_wrap(~ feature, scales = "free_y") +
    ggplot2::labs(x = NULL, y = "Feature value") +
    ggplot2::theme_minimal(base_size = 11)
}
