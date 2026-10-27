# ════════════════════════════════════════════════════════════════════════
# R/timepoints.R — Declared timepoints and per-modality coverage
# ════════════════════════════════════════════════════════════════════════
# A study declares its timepoints once, in _config.yml, and every modality
# is checked against that declaration. Before this module each modality
# carried its own idea of "wave 2": REDCap had an event name, EMA had a
# session file, EEG had a `ses-02` folder, and nothing said they were the
# same thing. Coverage questions ("who has baseline EEG but no week-4 EMA")
# needed a hand-written join every time.
#
# Config block this module reads:
#
#   timepoints:
#     anchor: baseline                 # key whose date anchors offsets
#     anchor_date_column: baseline_date  # REDCap column holding the anchor date
#     schedule:
#       baseline: {label: "Baseline", offset_days: 0,  window_days: [-7, 7],
#                  redcap_event: "baseline_arm_1", modalities: [redcap, ema, eeg]}
#       week4:    {label: "Week 4",   offset_days: 28, window_days: [-3, 7],
#                  redcap_event: "week_4_arm_1",   modalities: [redcap, ema]}
#
# Offsets are days from the anchor; windows are inclusive day ranges around
# the offset within which an observation counts as belonging to that
# timepoint. Windows may not overlap. `modalities` is the list of modality
# keys expected at that timepoint; a modality absent from the list is not
# counted as missing there.
# ════════════════════════════════════════════════════════════════════════

#' Known modality keys. Extend here when a modality module is added.
builder_modalities <- function() {
  c("redcap", "ema", "eeg", "sensors")
}

#' Tidy the declared timepoint schedule.
#'
#' @param config Config list from read_config().
#' @return A tibble with one row per timepoint in declared order: timepoint,
#'   label, offset_days, window_lo, window_hi (absolute days from anchor),
#'   redcap_event, modalities (list-column).
timepoint_schedule <- function(config) {
  assert_timepoints_declared(config)
  sched <- config$timepoints$schedule
  purrr::imap_dfr(sched, function(tp, key) {
    win <- tp$window_days %||% c(0, 0)
    tibble::tibble(
      timepoint    = key,
      label        = tp$label %||% key,
      offset_days  = as.numeric(tp$offset_days %||% 0),
      window_lo    = as.numeric(tp$offset_days %||% 0) + as.numeric(win[1]),
      window_hi    = as.numeric(tp$offset_days %||% 0) + as.numeric(win[2]),
      redcap_event = as.character(tp$redcap_event %||% NA_character_),
      modalities   = list(as.character(tp$modalities %||% character(0)))
    )
  }) |>
    dplyr::mutate(order = dplyr::row_number())
}

#' Validate the timepoints block before anything reads it.
#'
#' Stops on: no schedule; an anchor that is not a schedule key; a
#' non-numeric offset; a window whose low end exceeds its high end; two
#' windows that overlap (an observation would then belong to two timepoints,
#' and the coverage table would double count); an unknown modality key.
#'
#' @param config Config list.
assert_timepoints_declared <- function(config) {
  tp <- config$timepoints
  if (is.null(tp) || is.null(tp$schedule) || length(tp$schedule) == 0) {
    stop("[assert_timepoints_declared] _config.yml has no timepoints.schedule. ",
         "Declare at least one timepoint before building any stage.", call. = FALSE)
  }
  keys <- names(tp$schedule)
  if (is.null(keys) || any(!nzchar(keys))) {
    stop("[assert_timepoints_declared] every timepoint needs a key (e.g. baseline, week4).",
         call. = FALSE)
  }
  anchor <- tp$anchor %||% keys[1]
  if (!anchor %in% keys) {
    stop("[assert_timepoints_declared] timepoints.anchor '", anchor,
         "' is not one of the schedule keys: ", paste(keys, collapse = ", "), call. = FALSE)
  }
  lo <- hi <- numeric(length(keys))
  for (i in seq_along(keys)) {
    t <- tp$schedule[[i]]
    off <- t$offset_days %||% 0
    if (!is.numeric(off) || length(off) != 1) {
      stop("[assert_timepoints_declared] timepoint '", keys[i],
           "': offset_days must be a single number.", call. = FALSE)
    }
    win <- t$window_days %||% c(0, 0)
    if (!is.numeric(win) || length(win) != 2 || win[1] > win[2]) {
      stop("[assert_timepoints_declared] timepoint '", keys[i],
           "': window_days must be [lo, hi] with lo <= hi.", call. = FALSE)
    }
    bad_mod <- setdiff(as.character(t$modalities %||% character(0)), builder_modalities())
    if (length(bad_mod)) {
      stop("[assert_timepoints_declared] timepoint '", keys[i], "' lists unknown modality: ",
           paste(bad_mod, collapse = ", "), ". Known: ",
           paste(builder_modalities(), collapse = ", "), call. = FALSE)
    }
    lo[i] <- off + win[1]; hi[i] <- off + win[2]
  }
  o <- order(lo)
  if (length(keys) > 1 && any(lo[o][-1] <= hi[o][-length(o)])) {
    stop("[assert_timepoints_declared] timepoint windows overlap; an observation ",
         "would be assigned to two timepoints. Narrow window_days.", call. = FALSE)
  }
  invisible(TRUE)
}

#' Assign observations to timepoints by days-from-anchor.
#'
#' @param obs_dates Date vector of observations.
#' @param anchor_dates Date vector, same length, each observation's anchor.
#' @param config Config list.
#' @return Character vector of timepoint keys; NA where the observation falls
#'   outside every declared window.
assign_timepoint <- function(obs_dates, anchor_dates, config) {
  sched <- timepoint_schedule(config)
  obs_dates <- as.Date(obs_dates); anchor_dates <- as.Date(anchor_dates)
  if (length(anchor_dates) == 1) anchor_dates <- rep(anchor_dates, length(obs_dates))
  stopifnot(length(obs_dates) == length(anchor_dates))
  d <- as.numeric(obs_dates - anchor_dates)
  out <- rep(NA_character_, length(d))
  for (i in seq_len(nrow(sched))) {
    hit <- !is.na(d) & d >= sched$window_lo[i] & d <= sched$window_hi[i]
    out[hit] <- sched$timepoint[i]
  }
  out
}

#' Expected-versus-observed coverage of one modality across timepoints.
#'
#' @param df A data frame with one row per observation (any grain).
#' @param id_col Participant ID column in df.
#' @param timepoint_col Column holding the timepoint key.
#' @param config Config list.
#' @param modality One of builder_modalities().
#' @param expected_ids Character vector of participants expected in the
#'   study (usually the REDCap roster). Defaults to the ids seen in df.
#' @return A tibble id x timepoint restricted to timepoints where the
#'   modality is expected, with n_obs and observed (n_obs > 0).
timepoint_coverage <- function(df, id_col, timepoint_col, config, modality,
                               expected_ids = NULL) {
  modality <- match.arg(modality, builder_modalities())
  sched <- timepoint_schedule(config)
  tps <- sched$timepoint[purrr::map_lgl(sched$modalities, ~ modality %in% .x)]
  if (length(tps) == 0) {
    stop("[timepoint_coverage] no timepoint lists modality '", modality,
         "' in timepoints.schedule.", call. = FALSE)
  }
  ids <- as.character(expected_ids %||% unique(df[[id_col]]))
  ids <- ids[!is.na(ids) & nzchar(ids)]
  grid <- tidyr::expand_grid(study_id = ids, timepoint = tps)
  counts <- df |>
    dplyr::mutate(study_id = as.character(.data[[id_col]]),
                  timepoint = as.character(.data[[timepoint_col]])) |>
    dplyr::filter(!is.na(.data$timepoint)) |>
    dplyr::count(.data$study_id, .data$timepoint, name = "n_obs")
  grid |>
    dplyr::left_join(counts, by = c("study_id", "timepoint")) |>
    dplyr::mutate(n_obs = dplyr::coalesce(.data$n_obs, 0L),
                  observed = .data$n_obs > 0,
                  modality = modality,
                  timepoint = factor(.data$timepoint, levels = tps)) |>
    dplyr::arrange(.data$study_id, .data$timepoint)
}

#' Collapse a coverage table to n_expected / n_observed per timepoint.
timepoint_coverage_summary <- function(coverage) {
  coverage |>
    dplyr::summarise(n_expected = dplyr::n_distinct(.data$study_id),
                     n_observed = sum(.data$observed),
                     pct_observed = round(100 * mean(.data$observed), 1),
                     .by = c("modality", "timepoint")) |>
    dplyr::mutate(timepoint = as.character(.data$timepoint))
}

#' Participant x timepoint completeness tile plot.
#'
#' @param coverage Output of timepoint_coverage(), or several row-bound.
#' @return A ggplot object, or (without ggplot2) the coverage tibble.
plot_timepoint_completeness <- function(coverage) {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    message("ggplot2 not installed; returning the coverage table instead.")
    return(invisible(coverage))
  }
  ggplot2::ggplot(coverage,
                  ggplot2::aes(x = .data$timepoint, y = .data$study_id,
                               fill = .data$observed)) +
    ggplot2::geom_tile(colour = "white") +
    ggplot2::facet_wrap(~ modality, nrow = 1) +
    ggplot2::scale_fill_manual(values = c(`TRUE` = "#2A6F97", `FALSE` = "#D9D9D9"),
                               name = "Observed") +
    ggplot2::labs(x = NULL, y = "Participant") +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(axis.text.y = ggplot2::element_text(size = 6),
                   panel.grid = ggplot2::element_blank())
}
