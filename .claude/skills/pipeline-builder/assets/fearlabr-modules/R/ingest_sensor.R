# ════════════════════════════════════════════════════════════════════════
# R/ingest_sensor.R — Passive sensor and actigraphy streams
# ════════════════════════════════════════════════════════════════════════
# Passive streams (wrist actigraphy, phone accelerometry, GPS-derived
# mobility, sleep summaries) arrive as one file per device or per export,
# at day grain or at epoch grain, with vendor column names. This module
# puts each declared stream into a canonical day-level table
# (study_id, sensor_stream, date, <metrics>), decides which days are valid
# by a rule the study declares, and reports coverage per participant.
#
# The valid-day rule is the analytic decision here and it lives in config,
# not in code: "wear_minutes >= 600" is a study's choice, defensible in a
# methods section, and the pipeline should be able to print it.
#
# Config block:
#
#   sensors:
#     enabled: true
#     tz: "America/New_York"          # for epoch timestamps -> local date
#     streams:
#       accel:
#         label: "Wrist actigraphy"
#         file_glob: "sensor/*_accel.csv"
#         grain: day                  # day | epoch
#         columns: {id: participant_id, date: date}         # epoch: timestamp
#         metrics: {steps: step_count, wear_minutes: wear_min}  # canonical: export
#         aggregate: {steps: sum, wear_minutes: sum}        # epoch -> day
#         valid_day_rule: "wear_minutes >= 600"
#         id_transform: {pad_width: 4}
#         id_pattern: "^[0-9]{4}$"
# ════════════════════════════════════════════════════════════════════════

#' Read one declared stream into the canonical day table.
#'
#' @param config Config list.
#' @param stream Key under sensors.streams.
#' @param files Optional explicit files; default resolves the stream's glob.
#' @param write Persist `<stem>_sensor_<stream>_day_latest.rds`?
#' @return Tibble: study_id, sensor_stream, date, <metrics>, n_source_rows.
ingest_sensor_stream <- function(config, stream, files = NULL, write = TRUE) {
  sn <- config$sensors
  if (!isTRUE(sn$enabled)) stop("sensors.enabled is not true in _config.yml.", call. = FALSE)
  spec <- sn$streams[[stream]]
  if (is.null(spec)) {
    stop("[ingest_sensor_stream] no stream '", stream, "' under sensors.streams. Declared: ",
         paste(names(sn$streams), collapse = ", "), call. = FALSE)
  }
  grain <- spec$grain %||% "day"
  if (!grain %in% c("day", "epoch")) {
    stop("[ingest_sensor_stream] stream '", stream, "': grain must be day or epoch.", call. = FALSE)
  }
  files <- files %||% builder_glob_files(config, spec$file_glob %||% paste0("sensor/*", stream, "*.csv"))
  if (length(files) == 0) {
    stop("[ingest_sensor_stream] no files match '", spec$file_glob, "' for stream '",
         stream, "' under ", config$paths$raw_data, ".", call. = FALSE)
  }
  cols <- spec$columns %||% list()
  metrics <- spec$metrics %||% list()
  if (length(metrics) == 0) {
    stop("[ingest_sensor_stream] stream '", stream, "' declares no metrics.", call. = FALSE)
  }
  id_src <- cols$id %||% "id"
  time_src <- if (grain == "day") (cols$date %||% "date") else (cols$timestamp %||% "timestamp")
  tz <- sn$tz %||% "UTC"

  frames <- lapply(files, function(f) {
    df <- readr::read_csv(f, show_col_types = FALSE,
                          col_types = readr::cols(.default = readr::col_character()),
                          name_repair = "minimal")
    need <- c(id_src, time_src, unlist(metrics))
    miss <- setdiff(need, names(df))
    if (length(miss)) {
      stop("[ingest_sensor_stream] ", basename(f), " lacks column(s): ",
           paste(miss, collapse = ", "), ". Fix sensors.streams.", stream,
           ".columns / .metrics in _config.yml.", call. = FALSE)
    }
    out <- tibble::tibble(study_id = df[[id_src]])
    if (grain == "day") {
      out$date <- as.Date(lubridate::parse_date_time(df[[time_src]],
                                                     orders = c("Ymd", "dmY", "mdY", "Ymd HMS")))
    } else {
      # Local calendar date, never as.Date() on a POSIXct: that ignores the
      # tzone and pushed 20% of one study's evening events onto the next day.
      ts <- lubridate::parse_date_time(df[[time_src]], orders = c("Ymd HMS", "Ymd HM", "Ymd"), tz = tz)
      out$date <- as.Date(format(ts, "%Y-%m-%d", tz = tz))
    }
    for (m in names(metrics)) {
      v <- suppressWarnings(as.numeric(df[[metrics[[m]]]]))
      out[[m]] <- v
    }
    out$source_file <- basename(f)
    out
  })
  long <- dplyr::bind_rows(frames)
  n_bad_date <- sum(is.na(long$date))
  if (n_bad_date > 0) cat("⚠️ ", n_bad_date, " row(s) with an unparseable date/timestamp dropped\n", sep = "")
  long <- long[!is.na(long$date), ]

  long$study_id <- eeg_normalize_id(long$study_id, spec$id_transform)
  id_audit_line(long$study_id, paste0("sensor:", stream), pattern = spec$id_pattern)

  day <- if (grain == "epoch") {
    aggregate_sensor_to_day(long, names(metrics), spec$aggregate %||% list())
  } else {
    long |>
      dplyr::summarise(dplyr::across(dplyr::all_of(names(metrics)), ~ mean(.x, na.rm = TRUE)),
                       n_source_rows = dplyr::n(), .by = c("study_id", "date"))
  }
  # A day duplicated across two export files is averaged above and counted
  # in n_source_rows > 1; say so rather than let it pass.
  n_dup <- sum(day$n_source_rows > 1)
  if (grain == "day" && n_dup > 0) {
    cat("⚠️ ", n_dup, " participant-day(s) appeared in more than one row; values averaged\n", sep = "")
  }
  day <- day |>
    dplyr::mutate(sensor_stream = stream, .after = "study_id") |>
    dplyr::arrange(.data$study_id, .data$date)
  attr(day, "source") <- paste0("sensor:", stream, ":", paste(basename(files), collapse = ";"))

  if (isTRUE(write)) {
    write_latest_rds(day, paste0(fearlabr_file_stem(config), "_sensor_", stream, "_day"),
                     resolve_path(config$paths$raw_data %||% "data/raw", config))
  }
  day
}

#' Collapse epoch rows to one row per participant-day.
#'
#' @param df Long epoch table with study_id, date and metric columns.
#' @param metrics Canonical metric names.
#' @param aggregate Named list metric -> "sum" | "mean" | "max" | "min".
aggregate_sensor_to_day <- function(df, metrics, aggregate = list()) {
  fns <- list(sum = function(x) sum(x, na.rm = TRUE),
              mean = function(x) mean(x, na.rm = TRUE),
              max = function(x) suppressWarnings(max(x, na.rm = TRUE)),
              min = function(x) suppressWarnings(min(x, na.rm = TRUE)))
  out <- df |> dplyr::summarise(n_source_rows = dplyr::n(), .by = c("study_id", "date"))
  for (m in metrics) {
    how <- aggregate[[m]] %||% "sum"
    if (!how %in% names(fns)) {
      stop("[aggregate_sensor_to_day] unknown aggregate '", how, "' for ", m, call. = FALSE)
    }
    agg <- df |> dplyr::summarise(v = fns[[how]](.data[[m]]), .by = c("study_id", "date"))
    names(agg)[names(agg) == "v"] <- m
    out <- dplyr::left_join(out, agg, by = c("study_id", "date"))
  }
  out
}

#' Evaluate the declared valid-day rule; NA evaluates to not valid.
#'
#' @param sensor_day Day table.
#' @param rule A string expression over the metric columns, e.g.
#'   "wear_minutes >= 600 & steps > 0".
sensor_valid_days <- function(sensor_day, rule) {
  if (is.null(rule) || !nzchar(rule)) {
    stop("[sensor_valid_days] valid_day_rule is empty; declare one per stream.", call. = FALSE)
  }
  expr <- rlang::parse_expr(rule)
  v <- rlang::eval_tidy(expr, data = sensor_day)
  if (!is.logical(v) || length(v) != nrow(sensor_day)) {
    stop("[sensor_valid_days] rule '", rule, "' did not evaluate to one logical per row.",
         call. = FALSE)
  }
  sensor_day$valid_day <- !is.na(v) & v
  sensor_day
}

#' Per-participant coverage of a stream.
#'
#' @param sensor_day Output of sensor_valid_days().
#' @return Tibble: study_id, first_date, last_date, n_days_span,
#'   n_days_observed, n_valid_days, pct_valid_of_span.
sensor_coverage <- function(sensor_day) {
  if (!"valid_day" %in% names(sensor_day)) {
    stop("[sensor_coverage] run sensor_valid_days() first.", call. = FALSE)
  }
  sensor_day |>
    dplyr::summarise(
      first_date = min(.data$date), last_date = max(.data$date),
      n_days_span = as.integer(max(.data$date) - min(.data$date)) + 1L,
      n_days_observed = dplyr::n_distinct(.data$date),
      n_valid_days = sum(.data$valid_day),
      .by = "study_id") |>
    dplyr::mutate(pct_valid_of_span = round(100 * .data$n_valid_days / .data$n_days_span, 1)) |>
    dplyr::arrange(.data$study_id)
}

#' Attach declared timepoints to sensor days using each participant's anchor.
#'
#' @param sensor_day Day table.
#' @param anchors Tibble study_id, anchor_date (one row per participant).
#' @param config Config list.
#' @return sensor_day with anchor_date, days_from_anchor, timepoint. Days
#'   outside every window keep timepoint NA. Participants with no anchor
#'   are reported and kept with NA.
link_sensor_to_timepoints <- function(sensor_day, anchors, config) {
  stopifnot(all(c("study_id", "anchor_date") %in% names(anchors)))
  anchors <- anchors |>
    dplyr::mutate(study_id = as.character(.data$study_id),
                  anchor_date = as.Date(.data$anchor_date)) |>
    dplyr::distinct(.data$study_id, .keep_all = TRUE)
  out <- dplyr::left_join(sensor_day, anchors[, c("study_id", "anchor_date")], by = "study_id")
  no_anchor <- unique(out$study_id[is.na(out$anchor_date)])
  if (length(no_anchor)) {
    cat("⚠️ ", length(no_anchor), " sensor participant(s) have no anchor date: ",
        paste(utils::head(no_anchor, 8), collapse = ", "), "\n", sep = "")
  }
  out$days_from_anchor <- as.numeric(out$date - out$anchor_date)
  out$timepoint <- assign_timepoint(out$date, out$anchor_date, config)
  out
}

#' Participant x date tile of valid days.
plot_sensor_coverage <- function(sensor_day) {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    message("ggplot2 not installed; returning the day table instead.")
    return(invisible(sensor_day))
  }
  if (!"valid_day" %in% names(sensor_day)) sensor_day$valid_day <- TRUE
  ggplot2::ggplot(sensor_day, ggplot2::aes(x = .data$date, y = .data$study_id,
                                           fill = .data$valid_day)) +
    ggplot2::geom_tile() +
    ggplot2::scale_fill_manual(values = c(`TRUE` = "#2A6F97", `FALSE` = "#E9A03B"),
                               name = "Valid day") +
    ggplot2::labs(x = NULL, y = "Participant") +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(axis.text.y = ggplot2::element_text(size = 6),
                   panel.grid = ggplot2::element_blank())
}
