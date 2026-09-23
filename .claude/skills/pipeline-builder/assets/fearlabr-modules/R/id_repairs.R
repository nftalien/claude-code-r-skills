# ════════════════════════════════════════════════════════════════════════
# R/id_repairs.R — repair mistyped participant identifiers, on the record
# ════════════════════════════════════════════════════════════════════════
# A participant whose id was mistyped into a data-collection app ("1023_error"
# for 1023) has real data under a label nothing will join on. Two wrong ways
# to handle that: drop the rows as junk, which discards a participant's data;
# or quietly rewrite them in a cleaning script, which leaves no trace of a
# change to identifiers.
#
# So repairs are declared in metadata/id_repairs.csv — one row per repair,
# with the source it applies to and why it was made — and applied by
# apply_id_repairs(), which prints what it changed and refuses to run
# silently. It is the same shape as the exclusions log, for the same reason:
# an identifier decision is a study decision, not a coding detail.
#
# id_repairs.csv columns:
#   from_id      the label in the data                     (required)
#   to_id        the participant id it belongs to          (required)
#   source       redcap | metricwire | eeg | sensors | any (required)
#   reason       free text, for the audit trail            (required)
#   decided_by   who made the call
#   decided_on   YYYY-MM-DD
# ════════════════════════════════════════════════════════════════════════

#' Read the id repair log.
#'
#' @param path Path to id_repairs.csv. Missing file returns zero rows, so a
#'   study with nothing to repair needs no file.
#' @param known_ids Optional character vector of real participant ids. When
#'   given, a repair whose `to_id` is not among them stops: repairing to an
#'   id that does not exist moves the problem rather than fixing it.
read_id_repairs <- function(path = here::here("metadata", "id_repairs.csv"),
                            known_ids = NULL) {
  empty <- tibble::tibble(from_id = character(), to_id = character(), source = character(),
                          reason = character(), decided_by = character(), decided_on = character())
  if (is.null(path) || !file.exists(path)) {
    cat("• No id_repairs.csv; no identifier repairs declared\n")
    return(empty)
  }
  x <- readr::read_csv(path, show_col_types = FALSE, col_types = readr::cols(.default = readr::col_character()))
  need <- c("from_id", "to_id", "source", "reason")
  miss <- setdiff(need, names(x))
  if (length(miss)) stop("[id_repairs] ", basename(path), " is missing column(s): ", paste(miss, collapse = ", "), call. = FALSE)
  x <- x[!is.na(x$from_id) & nzchar(trimws(x$from_id)), , drop = FALSE]
  if (!nrow(x)) return(empty)
  for (col in setdiff(names(empty), names(x))) x[[col]] <- NA_character_
  x$from_id <- trimws(x$from_id); x$to_id <- trimws(x$to_id); x$source <- tolower(trimws(x$source))

  bad <- x$source[!x$source %in% c("redcap", "metricwire", "eeg", "sensors", "any")]
  if (length(bad)) stop("[id_repairs] unknown source(s): ", paste(unique(bad), collapse = ", "),
                        ". Use redcap, metricwire, eeg, sensors or any.", call. = FALSE)
  if (any(is.na(x$to_id) | !nzchar(x$to_id))) stop("[id_repairs] every repair needs a to_id.", call. = FALSE)
  if (any(is.na(x$reason) | !nzchar(x$reason))) stop("[id_repairs] every repair needs a reason; it is the audit trail.", call. = FALSE)
  if (any(x$from_id == x$to_id)) stop("[id_repairs] a repair maps an id to itself: ",
                                      paste(x$from_id[x$from_id == x$to_id], collapse = ", "), call. = FALSE)
  dup <- x$from_id[duplicated(paste(x$from_id, x$source))]
  if (length(dup)) stop("[id_repairs] the same from_id is repaired twice for one source: ",
                        paste(unique(dup), collapse = ", "), call. = FALSE)
  if (!is.null(known_ids)) {
    unknown <- setdiff(x$to_id, as.character(known_ids))
    if (length(unknown)) stop("[id_repairs] repairs point at id(s) that do not exist in the roster: ",
                              paste(unknown, collapse = ", "),
                              "\n  Repairing to a non-existent id moves the problem instead of fixing it.", call. = FALSE)
  }
  cat("• id repairs declared: ", nrow(x), " (", paste(unique(x$source), collapse = ", "), ")\n", sep = "")
  x[, names(empty)]
}

#' Apply the declared repairs to one source's identifier column.
#'
#' Prints one line per repair with the rows affected, and warns about a repair
#' that matched nothing — a stale entry is a sign the upstream label was
#' fixed at source, which is better, and the row should be retired.
#'
#' @param data Data frame.
#' @param repairs Output of read_id_repairs().
#' @param id_col Name of the identifier column in `data`.
#' @param source Which source this data is, matched against the repair's
#'   `source` column ("any" repairs always apply).
apply_id_repairs <- function(data, repairs, id_col, source) {
  if (is.null(repairs) || !nrow(repairs)) return(data)
  if (!id_col %in% names(data)) stop("[id_repairs] id column '", id_col, "' not in the data.", call. = FALSE)
  use <- repairs[repairs$source %in% c(tolower(source), "any"), , drop = FALSE]
  if (!nrow(use)) return(data)

  ids <- as.character(data[[id_col]])
  for (i in seq_len(nrow(use))) {
    hit <- !is.na(ids) & trimws(ids) == use$from_id[i]
    if (!any(hit)) {
      cat("⚠️  id repair matched no rows in ", source, ": '", use$from_id[i],
          "' -> '", use$to_id[i], "'. Retire the row if the label was fixed at source.\n", sep = "")
      next
    }
    ids[hit] <- use$to_id[i]
    cat("✓ id repair (", source, "): '", use$from_id[i], "' -> '", use$to_id[i], "'  ",
        sum(hit), " row(s)  [", use$reason[i], "]\n", sep = "")
  }
  data[[id_col]] <- ids
  data
}
