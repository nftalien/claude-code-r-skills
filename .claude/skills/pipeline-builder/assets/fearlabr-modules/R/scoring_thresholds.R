# ════════════════════════════════════════════════════════════════════════
# R/scoring_thresholds.R — the minimum-valid-items rule, checkable
# ════════════════════════════════════════════════════════════════════════
# A scale is scored only when enough of its items were answered. The rule is
# a proportion of the items, rounded UP:
#
#     minimum_valid_items = ceiling(prop * n_items)
#
# Rounding up is the rule, not an artefact of it. At prop = 0.8 it means a
# participant may miss one item only when the remainder still clears 80%:
#
#     n = 20 -> 16 of 20 (80.0%)   one missing leaves 95.0%, allowed
#     n = 12 -> 10 of 12 (83.3%)   9 of 12 is 75.0%, not allowed
#     n =  5 ->  4 of  5 (80.0%)   one missing leaves 80.0%, allowed
#     n =  4 ->  4 of  4 (100%)    3 of 4 is 75.0%, so the full scale
#
# Short scales therefore require every item, which is the rule working, not
# a special case. redcap_project_to_config() writes thresholds this way; this
# function exists because a config is a text file people edit by hand, and a
# threshold quietly loosened in one instrument is invisible in a render.
# ════════════════════════════════════════════════════════════════════════

#' Check every instrument's minimum_valid_items against the declared rule.
#'
#' @param config Config list from read_config().
#' @param prop Proportion of items required. Defaults to
#'   `config$validation$min_valid_prop`, else 0.8.
#' @param strict When TRUE (default) a deviation is an error. FALSE reports.
#' @return A tibble, one row per instrument, invisibly when everything agrees.
check_scoring_thresholds <- function(config = read_config(), prop = NULL, strict = TRUE) {

  instr <- config$instruments
  if (is.null(instr) || length(instr) == 0) {
    cat("⏭  No instruments configured; nothing to check\n")
    return(invisible(tibble::tibble()))
  }
  prop <- prop %||% config$validation$min_valid_prop %||% 0.8
  if (!is.numeric(prop) || length(prop) != 1 || prop <= 0 || prop > 1) {
    stop("prop must be a single number in (0, 1]; got: ",
         paste(utils::capture.output(str(prop)), collapse = " "), call. = FALSE)
  }

  rows <- lapply(names(instr), function(k) {
    v <- instr[[k]]
    n <- length(v$items_in_order)
    if (n == 0) return(NULL)
    declared <- suppressWarnings(as.integer(v$minimum_valid_items %||% NA))
    expected <- as.integer(ceiling(prop * n))
    tibble::tibble(
      instrument   = k,
      n_items      = as.integer(n),
      declared     = declared,
      expected     = expected,
      pct_required = round(100 * expected / n, 1),
      full_scale   = expected == n,
      ok           = !is.na(declared) && declared == expected
    )
  })
  out <- dplyr::bind_rows(rows)
  if (nrow(out) == 0) {
    cat("⏭  No instruments with items; nothing to check\n")
    return(invisible(out))
  }

  bad <- out[!out$ok, , drop = FALSE]
  if (nrow(bad) == 0) {
    cat("✓ minimum_valid_items: all ", nrow(out), " instrument(s) at ",
        "ceiling(", prop, " × n_items); ", sum(out$full_scale),
        " short scale(s) require every item\n", sep = "")
    return(invisible(out))
  }

  msg <- paste0(
    nrow(bad), " instrument(s) deviate from ceiling(", prop, " × n_items):\n",
    paste0("  ", bad$instrument, ": declared ", bad$declared, " of ", bad$n_items,
           ", rule says ", bad$expected, collapse = "\n"),
    "\nEither fix _config.yml or change validation$min_valid_prop deliberately.")
  if (isTRUE(strict)) stop(msg, call. = FALSE) else cat("⚠️  ", msg, "\n", sep = "")
  invisible(out)
}
