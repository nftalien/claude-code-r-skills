# ════════════════════════════════════════════════════════════════════════
# config_checks.R — front-end checks on _config.yml that cost a render each
# the first time they were missed (FARM-TOK, September 2026)
# ════════════════════════════════════════════════════════════════════════

#' Output column names fearlabr writes that a REDCap field must not reuse.
#'
#' `clean_redcap()` writes the randomised arm as `condition`, the assessment
#' wave as `wave`, and so on. A REDCap field with one of these names is moved
#' aside as `<name>_redcap_raw` at cleaning; the derivation names the clash
#' up front so nobody meets `condition.x` in a stage-06 select().
#' @export
fearlabr_reserved_columns <- function() {
  c("condition", "study_id", "wave", "timepoint", "arm", "days_from_anchor",
    "in_window", "assessment_date", "modality")
}

#' Stop on config labels or values that YAML read as booleans.
#'
#' YAML reads a bare `Yes`, `No`, `On`, `Off`, `True` or `False` as a boolean,
#' so an option list written by hand as `label: Yes` arrives in R as `TRUE`
#' and every range or label check on that item fails. `yaml::write_yaml()`
#' quotes such strings; hand-edited blocks do not. This walks the whole
#' config and stops with the path of every `label`, `labels`, `value`,
#' `values`, `choices` or `options` element that is logical.
#'
#' @param config A config list (from `read_config()` or `yaml::read_yaml()`).
#' @return `invisible(config)`; stops with every offending path listed.
#' @export
assert_config_labels <- function(config) {
  keys <- c("label", "labels", "value", "values", "choices", "options", "item_text")
  bad <- character()
  walk <- function(x, path) {
    if (is.list(x)) {
      nms <- names(x)
      for (i in seq_along(x)) {
        nm <- if (!is.null(nms) && nzchar(nms[i])) nms[i] else paste0("[", i, "]")
        walk(x[[i]], c(path, nm))
      }
    } else if (is.logical(x) && length(path) && any(path[length(path)] == keys)) {
      bad <<- c(bad, paste(path, collapse = "$"))
    } else if (is.logical(x) && length(path) >= 2 &&
               path[length(path) - 1] %in% c("labels", "values", "choices", "options")) {
      bad <<- c(bad, paste(path, collapse = "$"))
    }
  }
  walk(config, character())
  if (length(bad)) {
    stop(length(bad), " config element(s) are booleans where a label or value was expected ",
         "(YAML read a bare Yes/No/On/Off/True/False). Quote them, e.g. label: \"Yes\":\n  ",
         paste(utils::head(bad, 20), collapse = "\n  "),
         if (length(bad) > 20) paste0("\n  ... and ", length(bad) - 20, " more") else "",
         call. = FALSE)
  }
  invisible(config)
}
