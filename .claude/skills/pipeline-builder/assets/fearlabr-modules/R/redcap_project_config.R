# ════════════════════════════════════════════════════════════════════════
# R/redcap_project_config.R — Derive a proposed _config.yml from REDCap
# ════════════════════════════════════════════════════════════════════════
# REDCap already holds most of what the config interview asks for: the
# events with their day offsets and windows, which instruments are collected
# at which event, every field's type, choices, validation range, calc
# formula, branching logic and identifier flag. Asking a person to retype
# that is how item lists drift from the codebook. This module reads the
# project (API first, exported files otherwise) and proposes the config,
# with a todo table naming every value it derived, inferred, defaulted or
# could not know. The proposal is confirmed, not trusted: the UFOs audit
# found the dictionary disagreeing with the protocol in places.
#
# API contents used: project, arm, event, formEventMapping, instrument,
# metadata. File fallback: the data dictionary CSV, the events CSV
# (Project Setup > Define My Events > download) and, optionally, the
# instrument-event mapping CSV (Designate Instruments for My Events).
# ════════════════════════════════════════════════════════════════════════

# ── API ────────────────────────────────────────────────────────────────

#' Default transport: POST a form body, return the response text.
redcap_api_post <- function(url, body) {
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required.", call. = FALSE)
  resp <- httr::POST(url, body = body, encode = "form")
  txt <- httr::content(resp, as = "text", encoding = "UTF-8")
  if (httr::status_code(resp) != 200L) {
    stop("REDCap API export of '", body$content, "' failed: HTTP ", httr::status_code(resp),
         " ", substr(txt, 1, 200), call. = FALSE)
  }
  txt
}

#' One REDCap export as a character tibble.
#'
#' @param url Project API URL.
#' @param token API token (never printed, never stored).
#' @param content One of project, arm, event, formEventMapping, instrument,
#'   metadata, exportFieldNames.
#' @param .post Transport; tests inject a fake that returns CSV text.
redcap_api_export <- function(url, token, content, ..., .post = redcap_api_post) {
  body <- c(list(token = token, content = content, format = "csv", returnFormat = "json"), list(...))
  txt <- .post(url, body)
  if (!nzchar(trimws(txt))) return(tibble::tibble())
  readr::read_csv(I(txt), col_types = readr::cols(.default = readr::col_character()),
                  show_col_types = FALSE, name_repair = "minimal")
}

# ── Normalisation of file exports ──────────────────────────────────────

#' Rename a data dictionary to the API's column names.
#'
#' The Project Setup download uses human headers ("Variable / Field Name");
#' the API uses machine names (field_name). Match by a stripped key so either
#' shape, and the common re-exports of both, come out the same.
redcap_normalize_dictionary <- function(df) {
  key <- function(x) gsub("[^a-z0-9]", "", tolower(x))
  lookup <- c(
    variablefieldname = "field_name", fieldname = "field_name",
    formname = "form_name", sectionheader = "section_header", fieldtype = "field_type",
    fieldlabel = "field_label",
    choicescalculationsorsliderlabels = "select_choices_or_calculations",
    selectchoicesorcalculations = "select_choices_or_calculations",
    fieldnote = "field_note",
    textvalidationtypeorshowslidernumber = "text_validation_type_or_show_slider_number",
    textvalidationmin = "text_validation_min", textvalidationmax = "text_validation_max",
    identifier = "identifier",
    branchinglogicshowfieldonlyif = "branching_logic", branchinglogic = "branching_logic",
    requiredfield = "required_field", customalignment = "custom_alignment",
    questionnumbersurveysonly = "question_number", questionnumber = "question_number",
    matrixgroupname = "matrix_group_name", matrixranking = "matrix_ranking",
    fieldannotation = "field_annotation"
  )
  k <- key(names(df))
  new <- ifelse(k %in% names(lookup), lookup[k], gsub("[^a-z0-9]+", "_", tolower(names(df))))
  names(df) <- unname(new)
  need <- c("field_name", "form_name", "field_type")
  miss <- setdiff(need, names(df))
  if (length(miss)) stop("[redcap_normalize_dictionary] not a REDCap data dictionary; missing ",
                         paste(miss, collapse = ", "), call. = FALSE)
  for (col in c("select_choices_or_calculations", "text_validation_type_or_show_slider_number",
                "text_validation_min", "text_validation_max", "identifier", "branching_logic",
                "field_label")) {
    if (!col %in% names(df)) df[[col]] <- NA_character_
  }
  df[] <- lapply(df, as.character)
  tibble::as_tibble(df)
}

#' Normalise an events export (API or Project Setup download).
redcap_normalize_events <- function(df) {
  names(df) <- gsub("[^a-z0-9]+", "_", tolower(names(df)))
  if ("days_offset" %in% names(df) && !"day_offset" %in% names(df)) names(df)[names(df) == "days_offset"] <- "day_offset"
  if (!"unique_event_name" %in% names(df)) {
    stop("[redcap_normalize_events] events export lacks unique_event_name.", call. = FALSE)
  }
  for (col in c("event_name", "arm_num", "day_offset", "offset_min", "offset_max", "custom_event_label")) {
    if (!col %in% names(df)) df[[col]] <- NA_character_
  }
  df <- tibble::as_tibble(df)
  df$arm_num <- suppressWarnings(as.integer(df$arm_num)); df$arm_num[is.na(df$arm_num)] <- 1L
  for (col in c("day_offset", "offset_min", "offset_max")) {
    v <- suppressWarnings(as.numeric(df[[col]])); v[is.na(v)] <- 0; df[[col]] <- v
  }
  df$event_name <- dplyr::coalesce(df$event_name, df$unique_event_name)
  df
}

redcap_normalize_form_event_map <- function(df) {
  names(df) <- gsub("[^a-z0-9]+", "_", tolower(names(df)))
  if (!all(c("unique_event_name", "form") %in% names(df))) {
    stop("[redcap_normalize_form_event_map] mapping export needs unique_event_name and form.", call. = FALSE)
  }
  tibble::as_tibble(df)
}

# ── Read the project ───────────────────────────────────────────────────

#' Read project metadata from the API when a token exists, else from files.
#'
#' @param config Config list; supplies redcap.project_url and the keyring
#'   lookup keys. Optional when url/token or files are given.
#' @param url,token Explicit API endpoint and token (token from the keyring
#'   or an environment variable; never from the config).
#' @param files Named list of paths for the file path: data_dictionary
#'   (required), events (required), instrument_event_map (optional),
#'   instruments (optional; form_name, label).
#' @param .post Transport for tests.
#' @return List: source ("api" | "files"), project, arms, events,
#'   form_event_map, instruments, metadata, read_at.
redcap_project_read <- function(config = NULL, url = NULL, token = NULL, files = NULL,
                                .post = redcap_api_post) {
  if (!is.null(files)) {
    stopifnot(!is.null(files$data_dictionary), !is.null(files$events))
    rd <- function(p) readr::read_csv(p, col_types = readr::cols(.default = readr::col_character()),
                                      show_col_types = FALSE, name_repair = "minimal")
    out <- list(
      source = "files", project = NULL, arms = NULL,
      events = redcap_normalize_events(rd(files$events)),
      form_event_map = if (!is.null(files$instrument_event_map)) redcap_normalize_form_event_map(rd(files$instrument_event_map)) else NULL,
      instruments = if (!is.null(files$instruments)) rd(files$instruments) else NULL,
      metadata = redcap_normalize_dictionary(rd(files$data_dictionary)),
      read_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
    cat("• REDCap metadata read from files: ", paste(basename(unlist(files)), collapse = ", "), "\n", sep = "")
    return(out)
  }
  url <- url %||% config$redcap$project_url
  if (is.null(token)) {
    if (is.null(config) || !fearlabr_has_redcap_credential(config)) {
      stop("[redcap_project_read] no REDCap token in the keyring and no files given. ",
           "Either store the token (keyring::key_set(service, username) as named in ",
           "redcap.api_token_service / api_token_key) or pass files = list(data_dictionary=, events=).",
           call. = FALSE)
    }
    token <- get_redcap_token(config)
  }
  if (is.null(url) || !nzchar(url)) stop("[redcap_project_read] redcap.project_url is not set.", call. = FALSE)
  ex <- function(content) redcap_api_export(url, token, content, .post = .post)
  out <- list(
    source = "api",
    project = ex("project"),
    arms = ex("arm"),
    events = redcap_normalize_events(ex("event")),
    form_event_map = redcap_normalize_form_event_map(ex("formEventMapping")),
    instruments = ex("instrument"),
    metadata = redcap_normalize_dictionary(ex("metadata")),
    read_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
  cat("• REDCap metadata read from the API: ", nrow(out$metadata), " fields, ",
      nrow(out$events), " event(s), ", nrow(out$form_event_map), " form-event mapping(s)\n", sep = "")
  out
}

# ── Parsing helpers ────────────────────────────────────────────────────

#' "1, Never | 2, Sometimes" -> tibble(code, label).
redcap_parse_choices <- function(x) {
  if (is.na(x) || !nzchar(trimws(x))) return(tibble::tibble(code = character(), label = character()))
  parts <- trimws(strsplit(x, "|", fixed = TRUE)[[1]])
  code <- trimws(sub(",.*$", "", parts))
  label <- trimws(sub("^[^,]*,?", "", parts))
  tibble::tibble(code = code, label = label)
}

#' Field names referenced by a calc formula, e.g. "[phq_1]+[phq_2]".
redcap_calc_fields <- function(formula) {
  if (is.na(formula) || !nzchar(formula)) return(character(0))
  m <- regmatches(formula, gregexpr("\\[([A-Za-z0-9_]+)\\]", formula))[[1]]
  unique(gsub("\\[|\\]", "", m))
}

#' Whole doubles become integers so yaml writes 3, not 3.0.
as_whole <- function(x) {
  x <- as.numeric(x)
  if (length(x) && all(!is.na(x)) && all(x == round(x)) && all(abs(x) < .Machine$integer.max)) as.integer(x) else x
}

slug <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", "_", x)
  gsub("^_|_$", "", x)
}

#' Days from a name like 6_month, week_4, 90_day; NA when nothing matches.
infer_offset_from_name <- function(key) {
  k <- tolower(key)
  if (grepl("baseline|screen|intake|enrol", k)) return(0)
  m <- regmatches(k, regexec("(\\d+)[_ -]*(month|mo|mth)", k))[[1]]
  if (length(m) == 3) return(30 * as.numeric(m[2]))
  m <- regmatches(k, regexec("(?:week|wk)[_ -]*(\\d+)|(\\d+)[_ -]*(?:week|wk)", k, perl = TRUE))[[1]]
  if (length(m) == 3) { n <- suppressWarnings(as.numeric(m[2])); if (is.na(n)) n <- as.numeric(m[3]); return(7 * n) }
  m <- regmatches(k, regexec("(?:day|d)[_ -]*(\\d+)|(\\d+)[_ -]*(?:day|d)\\b", k, perl = TRUE))[[1]]
  if (length(m) == 3) { n <- suppressWarnings(as.numeric(m[2])); if (is.na(n)) n <- as.numeric(m[3]); return(n) }
  NA_real_
}

# ── Items and instruments ──────────────────────────────────────────────

#' Per-field scoring range where one can be read from the dictionary.
#'
#' radio/dropdown with all-numeric codes; text with integer/number validation
#' and both bounds; yesno/truefalse (0-1); slider (0-100, flagged).
redcap_field_ranges <- function(metadata) {
  purrr::pmap_dfr(metadata[, c("field_name", "form_name", "field_type",
                               "select_choices_or_calculations",
                               "text_validation_type_or_show_slider_number",
                               "text_validation_min", "text_validation_max")], function(
    field_name, form_name, field_type, select_choices_or_calculations,
    text_validation_type_or_show_slider_number, text_validation_min, text_validation_max) {
    lo <- NA_real_; hi <- NA_real_; how <- NA_character_
    ft <- tolower(field_type %||% "")
    if (ft %in% c("radio", "dropdown")) {
      ch <- redcap_parse_choices(select_choices_or_calculations)
      codes <- suppressWarnings(as.numeric(ch$code))
      if (nrow(ch) > 0 && !any(is.na(codes))) { lo <- min(codes); hi <- max(codes); how <- "choices" }
    } else if (ft == "text") {
      vt <- tolower(text_validation_type_or_show_slider_number %||% "")
      mn <- suppressWarnings(as.numeric(text_validation_min)); mx <- suppressWarnings(as.numeric(text_validation_max))
      if (grepl("integer|number", vt) && !is.na(mn) && !is.na(mx)) { lo <- mn; hi <- mx; how <- "validation" }
    } else if (ft %in% c("yesno", "truefalse")) { lo <- 0; hi <- 1; how <- ft
    } else if (ft == "slider") { lo <- 0; hi <- 100; how <- "slider" }
    tibble::tibble(field_name = field_name, form_name = form_name, field_type = ft,
                   lo = lo, hi = hi, how = how)
  })
}

#' Propose an instruments block from the dictionary.
#'
#' A form is an instrument when it has at least `min_items` fields with a
#' readable range and one modal range. Items with another range are listed
#' in the todo, not silently included. Calc fields become the total (one
#' that references every item) and subscales (others referencing >= 2).
#'
#' @return List: instruments (config list), todo (tibble), detail (tibble).
redcap_derive_instruments <- function(metadata, instruments_tbl = NULL, id_column = NULL,
                                      min_items = 3L, min_valid_prop = 0.8, scored_forms = character(0)) {
  scored_forms <- slug(scored_forms)
  rng <- redcap_field_ranges(metadata)
  rng <- rng[!rng$field_name %in% id_column, ]
  labels <- NULL
  if (!is.null(instruments_tbl) && all(c("instrument_name", "instrument_label") %in% names(instruments_tbl))) {
    labels <- stats::setNames(instruments_tbl$instrument_label, instruments_tbl$instrument_name)
  }
  out <- list(); todo <- list(); detail <- list()
  for (form in unique(metadata$form_name)) {
    items <- rng[rng$form_name == form & !is.na(rng$lo), ]
    if (nrow(items) < min_items) next
    key <- paste(items$lo, items$hi)
    modal <- names(sort(table(key), decreasing = TRUE))[1]
    keep <- items[key == modal, ]
    dropped <- items$field_name[key != modal]
    if (nrow(keep) < min_items) next
    lo <- as_whole(keep$lo[1]); hi <- as_whole(keep$hi[1]); n <- nrow(keep)
    ikey <- slug(form)
    # Strength: a scored instrument has a calc field, or several items on a
    # Likert-like range. Yes/no-only forms and forms whose names say they are
    # administrative (fidelity, interview, monitoring, consent, demographics,
    # screeners, TLFB, contact, visit, randomization) are listed as weak
    # candidates in the todo and left out of the proposal, so the person adds
    # them back deliberately rather than removing thirty by hand.
    calc_here <- metadata[metadata$form_name == form & tolower(metadata$field_type) == "calc", ]
    admin_name <- grepl("fidelity|interview|monitoring|consent|demograph|screen|tlfb|contact|visit|randomi|withdraw|^ae_|adverse|eligib|enrol|passcode|icf", ikey)
    binary_only <- (hi - lo) <= 1
    weak <- nrow(calc_here) == 0 && (binary_only || admin_name) && !ikey %in% scored_forms
    if (ikey %in% scored_forms) todo[[length(todo) + 1]] <- tibble::tibble(
      section = "instruments", key = ikey, status = "derived",
      note = paste0("declared scored by the study (scored_forms); ", n, " items on ", lo, "-", hi, " summed"))
    if (weak) {
      todo[[length(todo) + 1]] <- tibble::tibble(
        section = "instruments", key = ikey, status = "ask",
        note = paste0("not proposed: ", if (binary_only) paste0(n, " yes/no items and no calc field") else "form name suggests an administrative form",
                      if (admin_name && !binary_only) "" else "", "; add it as an instrument if it is scored"))
      next
    }
    # The items' shared stem ("ius" from ius1..ius12, "phq" from phq_1..phq_9)
    # is what a calc field's name carries in front of the subscale name.
    stem <- sub("[0-9_]+$", "", Reduce(function(a, b) {
      i <- 1; while (i <= min(nchar(a), nchar(b)) && substr(a, i, i) == substr(b, i, i)) i <- i + 1
      substr(a, 1, i - 1) }, keep$field_name))
    entry <- list(
      name = unname(labels[form] %||% form),
      n_items = n, item_range = c(lo, hi), total_range = as_whole(c(n * lo, n * hi)),
      minimum_valid_items = as.integer(ceiling(min_valid_prop * n)),
      reverse_coded = list(), items_in_order = keep$field_name)
    todo[[length(todo) + 1]] <- tibble::tibble(
      section = "instruments", key = ikey, status = "ask",
      note = paste0("confirm this form is a scored instrument (", n, " items, range ", lo, "-", hi,
                    if (length(dropped)) paste0("; excluded, other range: ", paste(dropped, collapse = ", ")) else "",
                    "); reverse-coded items cannot be read from the dictionary"))
    todo[[length(todo) + 1]] <- tibble::tibble(
      section = "instruments", key = paste0(ikey, ".minimum_valid_items"), status = "default",
      note = paste0("ceiling(", min_valid_prop, " x ", n, ")"))
    if (any(keep$how == "slider")) {
      todo[[length(todo) + 1]] <- tibble::tibble(section = "instruments", key = paste0(ikey, ".item_range"),
                                                 status = "ask", note = "slider fields assumed 0-100")
    }
    # Calc fields on this form
    calcs <- metadata[metadata$form_name == form & tolower(metadata$field_type) == "calc", ]
    total <- NULL; subs <- list()
    for (i in seq_len(nrow(calcs))) {
      refs <- intersect(redcap_calc_fields(calcs$select_choices_or_calculations[i]), keep$field_name)
      cname <- calcs$field_name[i]
      if (length(refs) == n && is.null(total)) {
        total <- cname
      } else if (length(refs) >= 2) {
        sname <- slug(cname)
        for (pre in unique(c(ikey, stem))) if (nzchar(pre)) sname <- sub(paste0("^", pre, "_?"), "", sname)
        sname <- gsub("_?(calc|score|subscale|sub)$", "", sname)
        if (!nzchar(sname)) sname <- cname
        subs[[sname]] <- list(items = refs, range = as_whole(c(length(refs) * lo, length(refs) * hi)), redcap_calc = cname)
      }
    }
    if (length(subs)) entry$subscales <- subs
    entry$redcap_total_calc <- total
    if (is.null(total)) {
      todo[[length(todo) + 1]] <- tibble::tibble(section = "instruments", key = paste0(ikey, ".redcap_total_calc"),
                                                 status = "ask", note = "no calc field references every item; nothing to cross-validate the total against")
    }
    out[[ikey]] <- entry
    detail[[length(detail) + 1]] <- tibble::tibble(form = form, key = ikey, n_items = n, lo = lo, hi = hi,
                                                  total_calc = total %||% NA_character_, n_subscales = length(subs),
                                                  n_excluded = length(dropped))
  }
  list(instruments = out, todo = dplyr::bind_rows(todo), detail = dplyr::bind_rows(detail))
}

# ── The proposal ───────────────────────────────────────────────────────

#' Propose a _config.yml from a project read.
#'
#' @param project Output of redcap_project_read().
#' @param study_name Short slug; defaults to a slug of the project title.
#' @param default_window Window in days used when REDCap's offset range is zero.
#' @return List: config (list ready for yaml), todo (tibble: section, key,
#'   status in derived | inferred | default | ask, note), detail (instrument table).
redcap_project_to_config <- function(project, study_name = NULL, default_window = c(-7, 7),
                                     min_items = 3L, min_valid_prop = 0.8, scored_forms = character(0)) {
  md <- project$metadata; ev <- project$events; fem <- project$form_event_map
  todo <- list()
  note <- function(section, key, status, text) {
    todo[[length(todo) + 1]] <<- tibble::tibble(section = section, key = key, status = status, note = text)
  }
  title <- if (!is.null(project$project) && "project_title" %in% names(project$project)) project$project$project_title[1] else NA_character_
  longitudinal <- if (!is.null(project$project) && "is_longitudinal" %in% names(project$project)) identical(project$project$is_longitudinal[1], "1") else nrow(ev) > 1
  study_name <- study_name %||% (if (!is.na(title)) slug(title) else "study")
  if (is.null(study_name) || !nzchar(study_name)) study_name <- "study"

  # Study
  cfg <- list(study = list(name = study_name, full_name = if (is.na(title)) "TODO" else title,
                           acronym = toupper(study_name), design = "TODO", target_n = 0L))
  note("study", "name", if (is.na(title)) "ask" else "inferred", if (is.na(title)) "no project title without the API" else paste0("slug of project title '", title, "'"))
  note("study", "design/target_n/pi/funder", "ask", "not in REDCap")

  # ID column
  id_col <- md$field_name[1]
  note("redcap", "id_column", "derived", paste0("first field of the dictionary: ", id_col))

  # Instruments
  inst <- redcap_derive_instruments(md, project$instruments, id_column = id_col, scored_forms = scored_forms,
                                    min_items = min_items, min_valid_prop = min_valid_prop)
  inst_forms <- names(inst$instruments)
  form_of_key <- stats::setNames(unique(md$form_name), slug(unique(md$form_name)))

  # Randomization and conditions
  rand <- md[grepl("randomi[sz]", md$field_name) & tolower(md$field_type) %in% c("radio", "dropdown"), ]
  if (nrow(rand) == 0) rand <- md[grepl("randomi[sz]", md$form_name) & tolower(md$field_type) %in% c("radio", "dropdown"), ]
  conditions <- list(); rand_field <- NULL
  if (nrow(rand) > 0) {
    rand_field <- rand$field_name[1]
    ch <- redcap_parse_choices(rand$select_choices_or_calculations[1])
    conditions <- lapply(seq_len(nrow(ch)), function(i) list(name = ch$label[i], code = slug(ch$label[i]),
                                                              redcap_value = as_whole(suppressWarnings(as.numeric(ch$code[i]))),
                                                              description = ch$label[i]))
    note("conditions", rand_field, "derived", paste0(nrow(ch), " arm(s) from the choices of ", rand_field, "; confirm this is treatment, not order"))
  } else {
    conditions <- list(list(name = "TODO", code = "todo", redcap_value = 1, description = "TODO"))
    note("conditions", "randomization_field", "ask", "no radio/dropdown field named like 'randomize'")
  }

  # Events
  ev <- ev[order(ev$arm_num, seq_len(nrow(ev))), ]
  n_arms <- dplyr::n_distinct(ev$arm_num)
  ev$key <- slug(sub("_arm_[0-9]+$", "", ev$unique_event_name))
  if (any(duplicated(ev$key))) ev$key <- slug(ev$unique_event_name)
  mapped_forms <- function(uen) if (is.null(fem)) character(0) else fem$form[fem$unique_event_name == uen]
  ev$assessment <- vapply(ev$unique_event_name, function(u) {
    if (is.null(fem)) return(TRUE)
    any(slug(mapped_forms(u)) %in% inst_forms)
  }, logical(1))
  if (is.null(fem)) note("redcap", "events.*.assessment", "ask", "no instrument-event mapping; every event marked assessment")
  events <- list()
  for (i in seq_len(nrow(ev))) {
    events[[ev$key[i]]] <- list(raw = ev$unique_event_name[i], label = ev$event_name[i], assessment = ev$assessment[i])
  }
  note("redcap", "events", "derived", paste0(nrow(ev), " event(s), raw names verbatim", if (n_arms > 1) paste0("; ", n_arms, " arms, keys carry the arm suffix") else ""))

  # Timepoints
  assess <- ev[ev$assessment, ]
  if (nrow(assess) == 0) { assess <- ev; note("timepoints", "schedule", "ask", "no event maps to a scored instrument; all events used") }
  schedule <- list(); last_hi <- -Inf
  for (i in seq_len(nrow(assess))) {
    k <- assess$key[i]
    off <- assess$day_offset[i]; wmin <- assess$offset_min[i]; wmax <- assess$offset_max[i]
    zero <- off == 0 && wmin == 0 && wmax == 0
    if (zero && i > 1) {
      inf <- infer_offset_from_name(k)
      if (is.na(inf)) { note("timepoints", paste0(k, ".offset_days"), "ask", "REDCap offset is 0 and the name gives no number"); off <- 0 }
      else { off <- inf; note("timepoints", paste0(k, ".offset_days"), "inferred", paste0(inf, " days from the event name; confirm against the protocol")) }
    } else if (!zero) {
      note("timepoints", paste0(k, ".offset_days"), "derived", paste0("REDCap day_offset ", off, ", range -", wmin, "/+", wmax))
    }
    win <- if (wmin == 0 && wmax == 0) { if (i > 1 || TRUE) note("timepoints", paste0(k, ".window_days"), "default", paste0("REDCap offset range is 0; default [", default_window[1], ", ", default_window[2], "]")); default_window } else c(-wmin, wmax)
    schedule[[k]] <- list(label = assess$event_name[i], offset_days = as_whole(off), window_days = as_whole(win),
                          redcap_event = assess$unique_event_name[i], modalities = list("redcap"))
  }
  # Two events at the same offset cannot both be timepoints. Keep the first,
  # drop the other from the schedule, and ask; it is usually an enrollment or
  # randomization event the mapping would have excluded.
  offs <- vapply(schedule, function(s) s$offset_days, numeric(1))
  dup <- names(schedule)[duplicated(offs)]
  for (k in dup) {
    same <- names(schedule)[offs == offs[[k]]][1]
    note("timepoints", k, "ask", paste0("same offset (", offs[[k]], ") as '", same, "'; left out of the schedule. Add it back with its own offset if it is an assessment wave"))
    schedule[[k]] <- NULL
  }
  # Windows must not overlap; shrink a default window that collides with its neighbour.
  keys <- names(schedule)
  if (length(keys) > 1) {
    offs <- vapply(schedule, function(s) s$offset_days, numeric(1)); o <- order(offs)
    for (j in seq_along(o)[-1]) {
      a <- schedule[[o[j - 1]]]; b <- schedule[[o[j]]]
      a_hi <- a$offset_days + a$window_days[2]; b_lo <- b$offset_days + b$window_days[1]
      if (b_lo <= a_hi) {
        gap <- b$offset_days - a$offset_days
        half <- max(0, floor((gap - 1) / 2))
        schedule[[o[j - 1]]]$window_days[2] <- min(a$window_days[2], half)
        schedule[[o[j]]]$window_days[1] <- max(b$window_days[1], -half)
        note("timepoints", paste0(keys[o[j]], ".window_days"), "ask", paste0("window overlapped '", keys[o[j - 1]], "'; both narrowed to fit; confirm"))
      }
    }
  }
  anchor <- keys[1]
  # Anchor date: a date-validated text field on a form mapped to the anchor event, else anywhere.
  is_date <- grepl("^date", tolower(md$text_validation_type_or_show_slider_number %||% "")) & tolower(md$field_type) == "text"
  anchor_forms <- if (!is.null(fem)) mapped_forms(schedule[[anchor]]$redcap_event) else character(0)
  cand <- md$field_name[is_date & md$form_name %in% anchor_forms]
  if (!length(cand)) cand <- md$field_name[is_date]
  anchor_col <- if (length(cand) == 1) cand else if (length(cand)) cand[1] else "TODO"
  note("timepoints", "anchor_date_column",
       if (length(cand) == 1) "inferred" else "ask",
       if (length(cand) == 0) "no date-validated field in the dictionary" else paste0("candidates: ", paste(cand, collapse = ", ")))
  note("timepoints", "schedule.*.modalities", "ask", "REDCap only; add ema / eeg / sensors where expected")
  cfg$conditions <- conditions
  cfg$redcap <- list(ingest_mode = "csv", export_prefix = "TODO", project_url = project$project_url %||% NULL,
                     api_token_service = NULL, api_token_key = NULL,
                     id_column = id_col, randomization_field = rand_field %||% "TODO", arm_label = "arm_1",
                     is_longitudinal = longitudinal, events = events,
                     forms_to_pull = as.list(unique(md$form_name)))
  cfg$instruments <- inst$instruments
  cfg$timepoints <- list(anchor = anchor, anchor_date_column = anchor_col, schedule = schedule)

  # Structural skips: branching logic of the shape [trigger] = 'value' on items
  skips <- list()
  bl <- md[!is.na(md$branching_logic) & nzchar(md$branching_logic), ]
  if (nrow(bl)) {
    m <- regmatches(bl$branching_logic, regexec("^\\s*\\[([A-Za-z0-9_]+)\\]\\s*(=|<>|>|<|>=|<=)\\s*'?([A-Za-z0-9.]+)'?\\s*$", bl$branching_logic))
    simple <- vapply(m, function(x) length(x) == 4, logical(1))
    if (any(simple)) {
      trig <- vapply(m[simple], `[`, character(1), 2); op <- vapply(m[simple], `[`, character(1), 3); val <- vapply(m[simple], `[`, character(1), 4)
      grp <- split(bl$field_name[simple], paste(trig, op, val))
      for (g in names(grp)) {
        p <- strsplit(g, " ")[[1]]
        skips[[length(skips) + 1]] <- list(trigger = p[1], trigger_op = p[2], trigger_value = p[3],
                                           downstream = grp[[g]], skip_value = 0)
      }
      note("structural_skips", "rules", "inferred", paste0(length(skips), " rule(s) from single-field branching logic; the skip_value (0) is a guess"))
    }
    if (any(!simple)) note("structural_skips", "complex", "ask", paste0(sum(!simple), " field(s) with multi-condition branching logic left for review: ", paste(utils::head(bl$field_name[!simple], 6), collapse = ", ")))
  }
  if (length(skips)) cfg$structural_skips <- skips

  # De-identification
  ids <- md$field_name[tolower(md$identifier %||% "") %in% c("y", "yes", "1", "true")]
  cfg$deid <- list(date_shift_seed = as.integer(format(Sys.Date(), "%Y%m%d")), date_shift_range_days = 30,
                   date_columns_to_shift = as.list(md$field_name[is_date]), direct_id_columns = as.list(ids))
  note("deid", "direct_id_columns", if (length(ids)) "derived" else "ask",
       if (length(ids)) paste0(length(ids), " field(s) flagged Identifier in REDCap") else "no field flagged Identifier; check the dictionary")
  cfg$metricwire <- list(enabled = FALSE)
  note("metricwire", "enabled", "ask", "EMA is not in REDCap; enable and fill sessions if the study has it")

  list(config = cfg, todo = dplyr::bind_rows(c(list(inst$todo), todo)) |> dplyr::mutate(status = factor(.data$status, levels = c("derived", "inferred", "default", "ask"))),
       detail = inst$detail, source = project$source, read_at = project$read_at)
}

#' Print the proposal summary and the todo table.
redcap_config_report <- function(proposal) {
  cfg <- proposal$config
  log_section(paste0("Proposed config from REDCap (", proposal$source, ")"))
  cat("• Study: ", cfg$study$name, "   ID column: ", cfg$redcap$id_column, "\n", sep = "")
  cat("• Events: ", length(cfg$redcap$events), "   timepoints: ",
      paste(names(cfg$timepoints$schedule), collapse = ", "), "\n", sep = "")
  cat("• Instruments: ", length(cfg$instruments), if (length(cfg$instruments)) paste0(" (", paste(names(cfg$instruments), collapse = ", "), ")") else "", "\n", sep = "")
  cat("• Conditions: ", length(cfg$conditions), "   identifiers: ", length(cfg$deid$direct_id_columns), "\n", sep = "")
  n <- table(proposal$todo$status)
  cat("• Todo: ", paste(names(n), n, sep = " ", collapse = ", "), "\n", sep = "")
  ask <- proposal$todo[proposal$todo$status == "ask", ]
  if (nrow(ask)) {
    cat("\nTo confirm with the study team:\n")
    for (i in seq_len(nrow(ask))) cat("  ", ask$section[i], ".", ask$key[i], ": ", ask$note[i], "\n", sep = "")
  }
  invisible(proposal$todo)
}

#' Write the proposal next to (never over) _config.yml.
#'
#' @return Paths written: `_config.proposed.yml` and `metadata/config_todo.csv`.
write_proposed_config <- function(proposal, dir = ".") {
  target <- file.path(dir, "_config.proposed.yml")
  if (file.exists(file.path(dir, "_config.yml")) && identical(normalizePath(target, mustWork = FALSE),
                                                              normalizePath(file.path(dir, "_config.yml"), mustWork = FALSE))) {
    stop("refusing to overwrite _config.yml", call. = FALSE)
  }
  dir.create(file.path(dir, "metadata"), recursive = TRUE, showWarnings = FALSE)
  yaml::write_yaml(proposal$config, target)
  todo_path <- file.path(dir, "metadata", "config_todo.csv")
  readr::write_csv(proposal$todo |> dplyr::mutate(status = as.character(.data$status)), todo_path)
  cat("✓ Wrote ", target, " and ", todo_path, "\n", sep = "")
  invisible(c(config = target, todo = todo_path))
}
