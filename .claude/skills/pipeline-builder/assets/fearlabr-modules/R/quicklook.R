# ════════════════════════════════════════════════════════════════════════
# R/quicklook.R — What the person looks at before approving a stage
# ════════════════════════════════════════════════════════════════════════
# The verification gate is visual on purpose. A count of 103 looks fine
# until it sits next to the roster's 98; a compliance figure of 100% looks
# fine until the heatmap shows every missed prompt was dropped. These
# helpers produce the small set of pictures and tables the builder shows at
# each gate, plus a parser for the render log so the chat can quote the
# warning lines rather than the whole HTML.
# ════════════════════════════════════════════════════════════════════════

#' Count the pipeline's log glyphs in a render log and return the warnings.
#'
#' @param text Character vector of log lines (or one string).
#' @return List: counts (ok, warn, skip, info) and warn_lines.
summarise_render_log <- function(text) {
  lines <- enc2utf8(unlist(strsplit(paste(text, collapse = "\n"), "\n", fixed = TRUE)))
  # Byte-wise fixed matching: a C locale (bare Rscript on Linux) cannot
  # compile these glyphs as a regular expression. See lessons A7.
  has <- function(glyph) grepl(enc2utf8(glyph), lines, fixed = TRUE, useBytes = TRUE)
  ok   <- has("\u2713")
  warn <- has("\u26a0")
  skip <- has("\u23ed")
  info <- startsWith(trimws(lines), enc2utf8("\u2022"))
  list(counts = c(ok = sum(ok), warn = sum(warn), skip = sum(skip), info = sum(info)),
       warn_lines = trimws(lines[warn]),
       skip_lines = trimws(lines[skip]))
}

#' Bind per-modality coverage summaries into one dashboard table.
#'
#' @param ... Outputs of timepoint_coverage_summary(), or a list of them.
modality_coverage_dashboard <- function(...) {
  parts <- list(...)
  if (length(parts) == 1 && is.list(parts[[1]]) && !is.data.frame(parts[[1]])) parts <- parts[[1]]
  out <- dplyr::bind_rows(parts)
  need <- c("modality", "timepoint", "n_expected", "n_observed", "pct_observed")
  miss <- setdiff(need, names(out))
  if (length(miss)) stop("[modality_coverage_dashboard] missing column(s): ",
                         paste(miss, collapse = ", "), call. = FALSE)
  out
}

#' Bar chart of observed-versus-expected per timepoint, one panel per modality.
plot_coverage_dashboard <- function(dashboard) {
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    message("ggplot2 not installed; returning the dashboard table instead.")
    return(invisible(dashboard))
  }
  dashboard <- dashboard |>
    dplyr::mutate(label = paste0(.data$n_observed, "/", .data$n_expected))
  ggplot2::ggplot(dashboard, ggplot2::aes(x = .data$timepoint, y = .data$pct_observed)) +
    ggplot2::geom_col(fill = "#2A6F97", width = 0.7) +
    ggplot2::geom_text(ggplot2::aes(label = .data$label), vjust = -0.3, size = 3) +
    ggplot2::facet_wrap(~ modality, nrow = 1, scales = "free_x") +
    ggplot2::scale_y_continuous(limits = c(0, 110), breaks = c(0, 25, 50, 75, 100)) +
    ggplot2::labs(x = NULL, y = "% of expected participants observed") +
    ggplot2::theme_minimal(base_size = 11)
}

#' Participant x day EMA compliance tile.
#'
#' @param ema Event-level EMA data (one row per prompt).
#' @param id_col,date_col Column names.
#' @param completed_col Logical or 0/1 column: was the prompt completed.
plot_ema_compliance_heatmap <- function(ema, id_col = "study_id", date_col = "ema_date",
                                        completed_col = "completed") {
  day <- ema |>
    # No leading-dot names inside a dplyr verb: `.d` partially matches the
    # verb's `.data` argument and errors on a column that exists (lessons A9).
    dplyr::mutate(id_ = as.character(.data[[id_col]]),
                  date_ = as.Date(.data[[date_col]]),
                  completed_ = as.logical(.data[[completed_col]])) |>
    dplyr::summarise(pct = 100 * mean(.data$completed_, na.rm = TRUE),
                     n_prompts = dplyr::n(), .by = c("id_", "date_")) |>
    dplyr::rename(study_id = "id_", date = "date_")
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    message("ggplot2 not installed; returning the day table instead.")
    return(invisible(day))
  }
  ggplot2::ggplot(day, ggplot2::aes(x = .data$date, y = .data$study_id, fill = .data$pct)) +
    ggplot2::geom_tile() +
    ggplot2::scale_fill_gradient(low = "#F2F2F2", high = "#2A6F97", limits = c(0, 100),
                                 name = "% completed") +
    ggplot2::labs(x = NULL, y = "Participant") +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(axis.text.y = ggplot2::element_text(size = 6),
                   panel.grid = ggplot2::element_blank())
}
