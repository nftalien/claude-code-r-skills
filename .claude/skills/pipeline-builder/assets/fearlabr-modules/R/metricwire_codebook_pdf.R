# ════════════════════════════════════════════════════════════════════════
# R/metricwire_codebook_pdf.R — Parse a real MetricWire dashboard codebook PDF
# ════════════════════════════════════════════════════════════════════════
# parse_metricwire_codebook() (0.1.x) reads the text blobs the reference
# study kept: plain text saved with a .pdf extension, or zips of page text.
# A codebook downloaded from the dashboard today is a binary PDF whose
# "Question Level Response Variables" table is columnar. pdftools keeps
# that layout, and this parser walks it line by line. It also reads what
# the blob parser never saw:
#   • "Breakdown of Each Question": display conditions (the only place the
#     dashboard states a gate), question groups, response required.
#   • "Breakdown of Each Trigger": the prompt schedule per survey.
#   • The study header: study name and the enrollment study id.
# Field groups (FIELD_GROUP rows) are headers: their child questions are
# not listed in the codebook and only appear as columns in an export.
# ════════════════════════════════════════════════════════════════════════

#' TRUE when the file starts with the %PDF magic bytes.
is_pdf_file <- function(path) {
  con <- file(path, "rb"); on.exit(close(con))
  magic <- readBin(con, "raw", n = 4)
  length(magic) == 4 && identical(rawToChar(magic), "%PDF")
}

#' Text lines of a PDF, layout preserved (pdftools).
metricwire_codebook_pdf_lines <- function(path) {
  if (!requireNamespace("pdftools", quietly = TRUE)) {
    stop("[metricwire_codebook_pdf] pdftools is needed to read a real PDF codebook: pak::pak('pdftools')", call. = FALSE)
  }
  pages <- pdftools::pdf_text(path)
  unlist(strsplit(paste(pages, collapse = "\n"), "\n", fixed = TRUE))
}

#' Parse a dashboard codebook PDF into one row per question.
#'
#' Same columns as parse_metricwire_codebook() (survey_name, quest_code,
#' item_text, item_stem, item_choice, format, position, question_type,
#' response_options, response_min, response_max, n_options) plus
#' display_condition, question_group, response_required. Attributes
#' "study", "surveys" and "triggers" carry the header, the survey summary
#' and the prompt schedule.
parse_metricwire_codebook_pdf <- function(path) {
  parse_metricwire_codebook_lines(metricwire_codebook_pdf_lines(path))
}

#' The line-level parser behind parse_metricwire_codebook_pdf() (testable
#' without a PDF).
parse_metricwire_codebook_lines <- function(lines) {
  lines <- gsub("\r", "", lines, fixed = TRUE)
  lines <- gsub("&nbsp;", "      ", lines, fixed = TRUE)   # same width: keeps the columns aligned
  n <- length(lines)
  survey_at <- grep("^\\s*Survey Information for\\s+\\S", lines)
  survey_names <- trimws(sub("^\\s*Survey Information for\\s+", "", lines[survey_at]))
  survey_of <- function(i) {
    k <- findInterval(i, survey_at)
    if (k >= 1) survey_names[k] else NA_character_
  }

  # ── 1. Question Level Response Variables tables ────────────────────────
  table_starts <- grep("^\\s*Question Level Response Variables\\s*$", lines)
  items <- list()
  for (ts in table_starts) {
    te <- grep("^\\s*Breakdown of Each Question\\s*$", lines)
    te <- te[te > ts]; te <- if (length(te)) te[1] - 1 else n
    seg <- lines[(ts + 1):te]
    seg <- seg[!grepl("^\\s*Question\\s+Variable Name\\s+Format", seg)]
    # Variable names are quest_<id>[_<id>...]; a few dashboard-made variables
    # carry a word prefix instead (AM_Loc_<id> for a location question).
    anchor_re <- paste0("^(.*?)\\s*(", mw_var_re, ")\\s+(?:(Character|Numeric|Date|Datetime|Boolean|Time)\\s+)?([0-9]+)\\s+([A-Z_]+)(.*)$")
    is_anchor <- grepl(anchor_re, seg, perl = TRUE)
    anchors <- which(is_anchor)
    for (a in seq_along(anchors)) {
      i0 <- anchors[a]; i1 <- if (a < length(anchors)) anchors[a + 1] - 1 else length(seg)
      m <- regmatches(seg[i0], regexec(anchor_re, seg[i0], perl = TRUE))[[1]]
      text <- trimws(m[2]); code <- m[3]; fmt <- if (nzchar(m[4])) m[4] else NA_character_
      pos <- as.integer(m[5]); qtype <- m[6]; rest <- m[7]
      code_col <- regexpr(code, seg[i0], fixed = TRUE)[1]
      choices <- character(0)
      push_choice <- function(s) {
        s <- trimws(s)
        if (!nzchar(s)) return()
        if (startsWith(s, "-")) choices <<- c(choices, s)
        else if (length(choices)) choices[length(choices)] <<- paste(choices[length(choices)], s)
      }
      push_choice(rest)
      for (j in seq_len(i1 - i0)) {
        ln <- seg[i0 + j]
        if (!nzchar(trimws(ln))) next
        # Cells are separated by two or more spaces; classify each by content
        # and by where it starts, since the columns drift a little between
        # pages and a wrapped variable code can span two or three lines.
        hits <- gregexpr("\\S+(?:\\s\\S+)*", ln, perl = TRUE)[[1]]
        cells <- regmatches(ln, list(hits))[[1]]
        starts <- as.integer(hits)
        for (c in seq_along(cells)) {
          cell <- cells[c]; at <- starts[c]
          if (grepl("^[0-9_][0-9_]{3,}$", cell) && at >= code_col - 8) { code <- paste0(code, cell); next }
          if (qtype == "MULTIPLE_CHOIC" && cell == "E") next
          if (startsWith(cell, "-")) { push_choice(cell); next }
          if (at < code_col - 1) text <- paste(text, cell) else push_choice(cell)
        }
      }
      if (qtype == "MULTIPLE_CHOIC") qtype <- "MULTIPLE_CHOICE"
      ch <- mw_parse_choices(choices)
      text <- gsub("\\s+", " ", trimws(text))
      qmark <- regexpr("?", text, fixed = TRUE)[1]
      if (qmark > 0 && qmark < nchar(text)) {
        stem <- trimws(substr(text, 1, qmark)); choice <- trimws(substr(text, qmark + 1, nchar(text)))
      } else { stem <- text; choice <- NA_character_ }
      items[[length(items) + 1]] <- tibble::tibble(
        survey_name = survey_of(ts), quest_code = code, item_text = text, item_stem = stem, item_choice = choice,
        format = fmt, position = pos, question_type = qtype,
        response_options = ch$options, response_min = ch$min, response_max = ch$max, n_options = ch$n)
    }
  }
  items <- if (length(items)) dplyr::bind_rows(items) else tibble::tibble(
    survey_name = character(), quest_code = character(), item_text = character(), item_stem = character(),
    item_choice = character(), format = character(), position = integer(), question_type = character(),
    response_options = character(), response_min = numeric(), response_max = numeric(), n_options = integer())

  items <- dplyr::distinct(items, .data$quest_code, .keep_all = TRUE)

  # ── 2. Breakdown of Each Question: gates, groups, required ─────────────
  # The breakdown lists questions in survey order, but its variable-name
  # column is clipped at the page edge for long codes, so entries are
  # matched by rank within the survey (verified against the code prefix)
  # and only by prefix when the counts disagree.
  bd <- mw_parse_breakdown(lines, survey_of)
  items$display_condition <- NA_character_; items$question_group <- NA_character_
  items$response_required <- NA_character_; items$breakdown_number <- NA_integer_
  for (sv in unique(items$survey_name)) {
    ii <- which(items$survey_name == sv); ii <- ii[order(items$position[ii])]
    bb <- bd[bd$survey_name %in% sv, ]; bb <- bb[order(bb$breakdown_number), ]
    if (!nrow(bb)) next
    by_rank <- length(ii) == nrow(bb) && all(startsWith(items$quest_code[ii], bb$code))
    for (r in seq_len(nrow(bb))) {
      j <- if (by_rank) ii[r] else {
        cand <- ii[startsWith(items$quest_code[ii], bb$code[r])]
        if (length(cand) == 1) cand else NA_integer_
      }
      if (is.na(j)) next
      items$display_condition[j] <- bb$display_condition[r]; items$question_group[j] <- bb$question_group[r]
      items$response_required[j] <- bb$response_required[r]; items$breakdown_number[j] <- bb$breakdown_number[r]
    }
  }

  attr(items, "study") <- mw_parse_study_header(lines)
  attr(items, "surveys") <- mw_parse_survey_summary(lines)
  attr(items, "triggers") <- mw_parse_triggers(lines, survey_of)
  items
}

#' "- Cannabis : 1", "-1:1", "-0", "- Yes" -> options string, range, count.
mw_parse_choices <- function(choices) {
  if (!length(choices)) return(list(options = NA_character_, min = NA_real_, max = NA_real_, n = 0L))
  s <- trimws(sub("^-\\s*", "", choices))
  has_code <- grepl(":\\s*-?[0-9]+(\\.[0-9]+)?\\s*$", s)
  label <- ifelse(has_code, trimws(sub(":\\s*-?[0-9]+(\\.[0-9]+)?\\s*$", "", s)), s)
  code <- ifelse(has_code, sub("^.*:\\s*(-?[0-9]+(?:\\.[0-9]+)?)\\s*$", "\\1", s, perl = TRUE), NA_character_)
  code <- suppressWarnings(as.numeric(code))
  numeric_label <- suppressWarnings(as.numeric(label))
  code[is.na(code) & !is.na(numeric_label)] <- numeric_label[is.na(code) & !is.na(numeric_label)]
  opts <- paste0("- ", label, ifelse(is.na(code), "", paste0(" : ", code)), collapse = "; ")
  list(options = opts,
       min = if (any(!is.na(code))) min(code, na.rm = TRUE) else NA_real_,
       max = if (any(!is.na(code))) max(code, na.rm = TRUE) else NA_real_,
       n = length(s))
}

mw_var_re <- "(?:quest|[A-Za-z]+_[A-Za-z]+)_[0-9][0-9_]*"

mw_parse_breakdown <- function(lines, survey_of) {
  entry_re <- paste0("^\\s*([0-9]+)\\)\\s+(.*?)\\s{2,}([A-Z_]+)\\s+(", mw_var_re, ")(?:\\s+(\\S+))?\\s*$")
  hits <- which(grepl(entry_re, lines, perl = TRUE))
  empty <- tibble::tibble(survey_name = character(), code = character(), breakdown_number = integer(), text = character(),
                          display_condition = character(), question_group = character(), response_required = character())
  if (!length(hits)) return(empty)
  rows <- lapply(hits, function(i) {
    m <- regmatches(lines[i], regexec(entry_re, lines[i], perl = TRUE))[[1]]
    nxt <- hits[hits > i]; stop_at <- if (length(nxt)) nxt[1] - 1 else length(lines)
    stop_at <- min(stop_at, i + 40)
    block <- lines[(i + 1):stop_at]
    take <- function(label) {
      h <- grep(paste0("^\\s*", label, ":\\s*"), block)
      if (length(h)) trimws(sub(paste0("^\\s*", label, ":\\s*"), "", block[h[1]])) else NA_character_
    }
    tibble::tibble(survey_name = survey_of(i), code = m[5], breakdown_number = as.integer(m[2]), text = trimws(m[3]),
                   display_condition = take("Display Conditions"), question_group = take("Question Groups"),
                   response_required = take("Response Required"))
  })
  dplyr::distinct(dplyr::bind_rows(rows), .data$survey_name, .data$breakdown_number, .keep_all = TRUE)
}

mw_parse_study_header <- function(lines) {
  take <- function(label) {
    h <- grep(paste0("^\\s*", label, "\\s+\\S"), lines)
    if (length(h)) trimws(sub(paste0("^\\s*", label, "\\s+"), "", lines[h[1]])) else NA_character_
  }
  link <- take("Public Enrollment Link")
  list(study_name = take("Study Name"), description = take("Study Description"),
       enrollment_link = link,
       study_id = if (!is.na(link)) sub("^.*/([0-9a-f]{24}).*$", "\\1", link) else NA_character_,
       participants_invited = suppressWarnings(as.integer(take("Participants Invited"))),
       participants_submitting = suppressWarnings(as.integer(take("Number of Participants Submitting Responses"))))
}

mw_parse_survey_summary <- function(lines) {
  h <- grep("^\\s*Survey Name\\s*/\\s*Type", lines)
  e <- grep("^\\s*Survey Information for", lines)
  empty <- tibble::tibble(survey_name = character(), type = character(), n_triggers = integer(), n_questions = integer(), n_responses = integer())
  if (!length(h) || !length(e)) return(empty)
  blob <- paste(lines[(h[1] + 1):(e[1] - 1)], collapse = " ")
  blob <- gsub("\\s+", " ", blob)
  # The type sits after the slash, or wraps to after the counts.
  re <- "(.*?)\\s*/\\s*(?:([A-Z]+)\\s+)?Number of Triggers:\\s*([0-9]+)\\s+([0-9]+)\\s+([0-9]+)(?:\\s+([A-Z]+)(?=\\s|$))?"
  m <- regmatches(blob, gregexec(re, blob, perl = TRUE))[[1]]
  if (!length(m)) return(empty)
  type <- ifelse(nzchar(m[3, ]), m[3, ], m[7, ])
  tibble::tibble(survey_name = trimws(m[2, ]), type = ifelse(nzchar(type), type, NA_character_),
                 n_triggers = as.integer(m[4, ]), n_questions = as.integer(m[5, ]), n_responses = as.integer(m[6, ]))
}

mw_parse_triggers <- function(lines, survey_of) {
  starts <- grep("^\\s*Breakdown of Each Trigger\\s*$", lines)
  empty <- tibble::tibble(survey_name = character(), index = integer(), trigger_name = character(), type = character(), settings = character())
  if (!length(starts)) return(empty)
  seen <- character(0); out <- list()
  for (s in starts) {
    sv <- survey_of(s)
    if (is.na(sv) || sv %in% seen) next          # the block repeats after every question
    seen <- c(seen, sv)
    re <- "^\\s*([0-9]+)\\)\\s*(.*?)\\s{2,}(ONCE|schedule|SCHEDULE|EVENT|MANUAL)\\s+(.*?)\\s*$"
    j <- s + 1
    while (j <= length(lines) && !grepl("^\\s*(Question & Settings|Breakdown of Each|Survey Information for)", lines[j])) {
      if (grepl(re, lines[j], perl = TRUE)) {
        m <- regmatches(lines[j], regexec(re, lines[j], perl = TRUE))[[1]]
        out[[length(out) + 1]] <- tibble::tibble(survey_name = sv, index = as.integer(m[2]), trigger_name = trimws(m[3]),
                                                 type = m[4], settings = trimws(m[5]))
      }
      j <- j + 1
    }
  }
  if (!length(out)) return(empty)
  dplyr::bind_rows(out)
}
