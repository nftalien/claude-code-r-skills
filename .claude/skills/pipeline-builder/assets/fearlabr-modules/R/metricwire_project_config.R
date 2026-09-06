# ════════════════════════════════════════════════════════════════════════
# R/metricwire_project_config.R — Derive the metricwire block from MetricWire
# ════════════════════════════════════════════════════════════════════════
# The REDCap counterpart reads one dictionary. MetricWire's metadata is
# spread across three things, none of which alone is enough:
#
#   1. The analysis data (Consumer API POST /analysis/{ws}/{id}/{skip}, or
#      the cached CSV under data/raw): which question columns exist, which
#      survey names carry which items, whether Missed rows are present,
#      observed min/max per item, and which account field holds the ID.
#   2. The codebook (dashboard PDF parsed by parse_metricwire_codebook(),
#      or its parsed CSV): item text, question type, response min/max.
#   3. The choicesDataCoding export, when the study has it: the numeric
#      code behind each label, which is the ground truth for an item's
#      scale (failure-modes: "label-parsed ordinal recode").
#
# A definitions endpoint on the API (analyses per study, questions with
# their coding) would replace 2 and 3; none is called here because none
# has been confirmed. `metricwire_project_read()` takes a `definitions`
# argument shaped like the coding table so such a reader can slot in.
#
# Everything derived carries a status, as the REDCap module does: derived,
# inferred, default, ask. Gates between items, the battery -> condition
# map, and safety thresholds are never derived.
# ════════════════════════════════════════════════════════════════════════

# ── Names and columns ──────────────────────────────────────────────────

#' snake_case a MetricWire column name: "User.FirstName" -> user_first_name.
mw_snake <- function(x) {
  x <- gsub("([a-z0-9])([A-Z])", "\\1_\\2", x)
  x <- gsub("[^A-Za-z0-9]+", "_", x)
  tolower(gsub("^_+|_+$", "", x))
}

mw_admin_regex <- function() {
  paste0("^(response_type|response_id|source_name|survey_name|survey_id|study_id|mw_study_id|",
         "user_|participant|first_name|last_name|email|trigger_|survey_started|survey_submitted|",
         "submitted|started|completed|scheduled|timezone|time_zone|device|session_key|date|time|",
         "analysis_id|workspace)")
}

#' The question columns of an analysis table.
#'
#' `quest_<n>` columns when the export has them (the API shape); otherwise
#' every column that is not administrative.
mw_question_columns <- function(df) {
  nm <- names(df)
  # quest_<id> columns, plus the dashboard's word-prefixed variables (AM_Loc_<id>)
  q <- nm[grepl(paste0("^", mw_var_re, "$"), nm, perl = TRUE) & grepl("[0-9]{6,}", nm)]
  if (length(q)) return(q)
  nm[!grepl(mw_admin_regex(), nm) & !grepl("^\\.", nm)]
}

#' Read one analysis export (data frame, CSV or RDS) as a character tibble.
metricwire_read_analysis_data <- function(x) {
  df <- if (is.data.frame(x)) x else {
    stopifnot(file.exists(x))
    if (grepl("\\.rds$", x, ignore.case = TRUE)) readRDS(x) else
      readr::read_csv(x, col_types = readr::cols(.default = readr::col_character()),
                      show_col_types = FALSE, name_repair = "minimal")
  }
  df <- tibble::as_tibble(df)
  names(df) <- mw_snake(names(df))
  df[] <- lapply(df, as.character)
  df
}

#' Read a codebook: the dashboard PDF (parsed) or a parsed-items CSV.
#'
#' The CSV shape is what build_ema_codebook() writes: quest_code, item_text,
#' item_choice, question_type, response_min, response_max, survey_name.
metricwire_read_codebook <- function(path) {
  stopifnot(file.exists(path))
  if (grepl("\\.csv$", path, ignore.case = TRUE)) {
    cb <- readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()),
                          show_col_types = FALSE, name_repair = "minimal")
    names(cb) <- mw_snake(names(cb))
    if (!"quest_code" %in% names(cb)) stop("[metricwire_read_codebook] ", basename(path), " has no quest_code column.", call. = FALSE)
  } else if (is_pdf_file(path)) {
    # A real dashboard PDF: layout parser, keeps study/survey/trigger attributes
    cb <- parse_metricwire_codebook_pdf(path)
    extra <- list(study = attr(cb, "study"), surveys = attr(cb, "surveys"), triggers = attr(cb, "triggers"))
    if (nrow(cb)) cb <- group_codebook_items_into_scales(cb)
    for (a in names(extra)) attr(cb, a) <- extra[[a]]
  } else {
    cb <- parse_metricwire_codebook(path)
    if (nrow(cb)) cb <- group_codebook_items_into_scales(cb)
  }
  extra <- list(study = attr(cb, "study"), surveys = attr(cb, "surveys"), triggers = attr(cb, "triggers"))
  for (col in c("item_text", "item_stem", "item_choice", "question_type", "response_min",
                "response_max", "survey_name", "effective_stem", "display_condition", "question_group")) {
    if (!col %in% names(cb)) cb[[col]] <- NA_character_
  }
  cb$response_min <- suppressWarnings(as.numeric(cb$response_min))
  cb$response_max <- suppressWarnings(as.numeric(cb$response_max))
  cb <- tibble::as_tibble(cb)
  for (a in names(extra)) attr(cb, a) <- extra[[a]]
  cb
}

#' The base code of a variable: the first id, which is the question; later
#' ids are the survey copies MetricWire appends (quest_<q>_<survey>...).
mw_base_code <- function(code) sub("^((?:quest|[A-Za-z]+_[A-Za-z]+)_[0-9]+).*$", "\\1", code)

#' Parse one choicesDataCoding value into label/code pairs.
#'
#' Accepts a JSON object ({"Not at all":0,...}), "label=code" or "code=label"
#' pairs separated by ; or |, or "code, label" pairs separated by |.
mw_parse_coding <- function(x) {
  empty <- tibble::tibble(label = character(), code = numeric())
  if (is.na(x) || !nzchar(trimws(x))) return(empty)
  x <- trimws(x)
  if (startsWith(x, "{")) {
    j <- tryCatch(jsonlite::fromJSON(x), error = function(e) NULL)
    if (is.null(j)) return(empty)
    return(tibble::tibble(label = names(j), code = suppressWarnings(as.numeric(unlist(j)))))
  }
  parts <- trimws(strsplit(x, "[;|]")[[1]])
  parts <- parts[nzchar(parts)]
  out <- lapply(parts, function(p) {
    kv <- trimws(strsplit(p, "[=,]")[[1]])
    if (length(kv) < 2) return(NULL)
    a <- suppressWarnings(as.numeric(kv[1])); b <- suppressWarnings(as.numeric(kv[2]))
    if (!is.na(b)) tibble::tibble(label = kv[1], code = b) else if (!is.na(a)) tibble::tibble(label = kv[2], code = a) else NULL
  })
  dplyr::bind_rows(out)
}

#' Read MetricWire "Data Import" templates: header-only CSVs, one per survey.
#'
#' The dashboard's Data Import page exports the column schema of a survey
#' (userId plus one quest_<base>_<version> column per question). With no
#' data pulled yet, these say which columns exist and which survey carries
#' which item, which is what the prompt-block proposal needs.
#'
#' @param paths Named list survey label -> CSV path.
#' @return Tibble survey, column.
metricwire_read_import_templates <- function(paths) {
  purrr::imap_dfr(paths, function(path, survey) {
    stopifnot(file.exists(path))
    cols <- names(readr::read_csv(path, n_max = 0, show_col_types = FALSE, name_repair = "minimal"))
    tibble::tibble(survey = survey, column = cols[!mw_snake(cols) %in% c("user_id", "userid")])
  })
}

#' Read a choicesDataCoding export: one row per item with its coding.
#'
#' @return Tibble quest_code, label, code (long).
metricwire_read_choices_coding <- function(path) {
  stopifnot(file.exists(path))
  df <- readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()),
                        show_col_types = FALSE, name_repair = "minimal")
  names(df) <- mw_snake(names(df))
  qcol <- names(df)[grepl("^(quest_code|question_id|questionid|question|quest|variable)$", names(df))][1]
  ccol <- names(df)[grepl("choices_data_coding|choicesdatacoding|^coding$", names(df))][1]
  if (is.na(qcol) || is.na(ccol)) {
    stop("[metricwire_read_choices_coding] need a question column and a choicesDataCoding column; got ",
         paste(names(df), collapse = ", "), call. = FALSE)
  }
  purrr::map2_dfr(df[[qcol]], df[[ccol]], function(q, c) {
    p <- mw_parse_coding(c)
    if (!nrow(p)) return(NULL)
    p$quest_code <- q; p
  }) |> dplyr::select("quest_code", "label", "code")
}

# ── API (studies) ──────────────────────────────────────────────────────

mw_api_get <- function(url, token) {
  if (!requireNamespace("httr", quietly = TRUE)) stop("Package 'httr' is required.", call. = FALSE)
  resp <- httr::GET(url, httr::add_headers(Authorization = paste("Bearer", token)))
  if (httr::status_code(resp) != 200L) stop("GET ", url, " failed: HTTP ", httr::status_code(resp), call. = FALSE)
  httr::content(resp, as = "text", encoding = "UTF-8")
}

#' Studies in the workspace (Consumer API GET /studies/{workspaceId}).
metricwire_list_studies <- function(config, token = NULL, .get = mw_api_get) {
  token <- token %||% get_metricwire_access_token(config)
  url <- sprintf("%s/studies/%s", mw_clean_base_url(config$metricwire$base_url), config$metricwire$workspace_id)
  txt <- .get(url, token)
  j <- jsonlite::fromJSON(txt, flatten = TRUE)
  if (is.list(j) && !is.data.frame(j)) j <- j[[which(vapply(j, is.data.frame, logical(1)))[1]]]
  tibble::as_tibble(j)
}

# ── Read the project ───────────────────────────────────────────────────

#' Gather MetricWire metadata from the API and/or files.
#'
#' @param config Config list (metricwire block: base_url, workspace_id,
#'   keyring keys, sessions with analysis_id/file/codebook). Optional when
#'   `data` is given.
#' @param data Named list (session key -> data frame or CSV/RDS path). When
#'   NULL: pulled through `.pull` for each configured session if credentials
#'   exist, else read from `data/raw/<file>`.
#' @param codebooks Named list (session key -> codebook PDF or parsed CSV);
#'   defaults to `sessions[[k]]$codebook`.
#' @param coding Named list (session key -> choicesDataCoding CSV), optional.
#' @param definitions Optional long tibble quest_code, label, code from an
#'   API definitions reader; used like `coding`, for every session.
#' @param studies Optional tibble; fetched from the API when credentials
#'   exist and `fetch_studies` is TRUE.
#' @param .pull,.get Transports, for tests.
metricwire_project_read <- function(config = NULL, data = NULL, codebooks = NULL, coding = NULL,
                                    definitions = NULL, studies = NULL, fetch_studies = TRUE,
                                    import_templates = NULL,
                                    .pull = pull_metricwire_analysis, .get = mw_api_get) {
  templates <- if (!is.null(import_templates)) metricwire_read_import_templates(import_templates) else NULL
  if (!is.null(templates)) cat("• import templates: ", dplyr::n_distinct(templates$survey), " survey(s), ",
                               nrow(templates), " column(s)\n", sep = "")
  sessions <- config$metricwire$sessions %||% list()
  keys <- unique(c(names(data), names(sessions)))
  if (!length(keys)) stop("[metricwire_project_read] no sessions: give `data` or configure metricwire.sessions.", call. = FALSE)
  has_creds <- !is.null(config) && fearlabr_has_metricwire_credentials(config)
  source <- if (is.null(data) && has_creds) "api" else "files"

  frames <- list(); session_tbl <- list()
  for (k in keys) {
    sess <- sessions[[k]] %||% list()
    df <- NULL; how <- NA_character_
    if (!is.null(data[[k]])) {
      df <- metricwire_read_analysis_data(data[[k]]); how <- if (is.data.frame(data[[k]])) "data frame" else basename(data[[k]])
    } else if (has_creds && !is.null(sess$analysis_id)) {
      df <- metricwire_read_analysis_data(.pull(config, k)); how <- "api"
    } else if (!is.null(sess$file)) {
      p <- file.path(resolve_path(config$paths$raw_data %||% "data/raw", config), sess$file)
      if (file.exists(p)) { df <- metricwire_read_analysis_data(p); how <- basename(p) }
    }
    if (is.null(df)) {
      # Codebook-only: no export yet, but the codebook names the items. The
      # session is carried with zero rows so the item block can be proposed
      # from declared ranges; observed ranges, the Missed check, prompt
      # blocks and the ID field wait for the first pull.
      cb_path <- codebooks[[k]] %||% sess$codebook
      if (!is.null(cb_path)) {
        cb_path <- if (fs::is_absolute_path(cb_path) || file.exists(cb_path)) cb_path else here::here(cb_path)
        if (file.exists(cb_path)) {
          cb0 <- metricwire_read_codebook(cb_path)
          cols0 <- if (!is.null(templates) && nrow(templates)) unique(c(templates$column)) else cb0$quest_code
          df <- tibble::as_tibble(stats::setNames(replicate(length(cols0), character(0), simplify = FALSE), cols0))
          how <- "codebook only (no data)"
          cat("⚠️ ", k, ": no data; carried from the codebook alone (", nrow(cb0), " items)\n", sep = "")
        }
      }
    }
    if (is.null(df)) {
      cat("⚠️ ", k, ": no data (no file, no credentials, nothing passed); session skipped\n", sep = "")
      next
    }
    frames[[k]] <- df
    session_tbl[[k]] <- tibble::tibble(key = k, analysis_id = as.character(sess$analysis_id %||% NA_character_),
                                       analysis_name = as.character(sess$analysis_name %||% sess$label %||% NA_character_),
                                       file = as.character(sess$file %||% paste0(k, "_api_raw.csv")),
                                       read_from = how, n_rows = nrow(df))
    cat("• ", k, ": ", nrow(df), " rows from ", how, "\n", sep = "")
  }
  if (!length(frames)) stop("[metricwire_project_read] no session had data.", call. = FALSE)

  cbs <- list()
  for (k in names(frames)) {
    p <- codebooks[[k]] %||% sessions[[k]]$codebook
    if (is.null(p)) next
    p <- if (fs::is_absolute_path(p) || file.exists(p)) p else here::here(p)
    if (!file.exists(p)) { cat("⚠️ ", k, ": codebook not found at ", p, "\n", sep = ""); next }
    cbs[[k]] <- metricwire_read_codebook(p)
    cat("• ", k, ": codebook ", basename(p), " (", nrow(cbs[[k]]), " items)\n", sep = "")
  }
  cods <- list()
  for (k in names(frames)) {
    p <- coding[[k]]
    if (is.null(p)) next
    cods[[k]] <- metricwire_read_choices_coding(p)
    cat("• ", k, ": choicesDataCoding ", basename(p), " (", dplyr::n_distinct(cods[[k]]$quest_code), " items)\n", sep = "")
  }
  if (!is.null(definitions)) for (k in names(frames)) cods[[k]] <- cods[[k]] %||% definitions

  if (is.null(studies) && has_creds && isTRUE(fetch_studies)) {
    studies <- tryCatch(metricwire_list_studies(config, .get = .get),
                        error = function(e) { cat("⚠️ studies list unavailable: ", conditionMessage(e), "\n", sep = ""); NULL })
  }
  list(source = source, sessions = dplyr::bind_rows(session_tbl), data = frames, codebooks = cbs,
       coding = cods, studies = studies, templates = templates, read_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
}

# ── Derivation ─────────────────────────────────────────────────────────

mw_stopwords <- function() c("how", "much", "do", "you", "feel", "right", "now", "are", "the", "a", "an",
                             "of", "in", "at", "this", "moment", "have", "has", "been", "your", "to",
                             "is", "did", "since", "last", "prompt", "please", "rate", "currently", "i",
                             "was", "were", "it", "having", "be", "about", "that", "with", "when",
                             "from", "my", "me", "on", "for", "and", "or")

#' The name for codebook row i: a canonical_name column when the codebook
#' carries one (the study's own vocabulary, kept across re-derivations),
#' else the slug of the text.
mw_item_name <- function(cb, i) {
  cn <- if ("canonical_name" %in% names(cb)) cb$canonical_name[i] else NA_character_
  if (!is.na(cn) && nzchar(trimws(cn))) return(slug(cn))
  mw_item_slug(cb$item_text[i], cb$item_choice[i])
}

#' A canonical item name from codebook text: the choice word when the item
#' is one of a battery ("Afraid"), else the first content words of the text.
mw_item_slug <- function(item_text, item_choice = NA_character_, max_words = 4) {
  if (!is.na(item_choice) && nzchar(trimws(item_choice))) return(slug(item_choice))
  if (is.na(item_text) || !nzchar(trimws(item_text))) return(NA_character_)
  item_text <- gsub("[\u2019']", "", item_text)          # I'm -> im, can't -> cant
  w <- strsplit(tolower(gsub("[^A-Za-z0-9 ]+", " ", item_text)), "\\s+")[[1]]
  w <- w[nzchar(w) & !w %in% mw_stopwords()]
  if (!length(w)) return(slug(item_text))
  paste(utils::head(w, max_words), collapse = "_")
}

#' Map every data column to the codebook code it belongs to.
#'
#' Exact match first; then the longest code that the column starts with
#' followed by "_" (FarmTok-style quest_<base>_<version> variants, which
#' the pipeline coalesces into one item); then a code whose digits end the
#' column name. NA when nothing matches.
mw_column_to_code <- function(columns, quest_codes) {
  # The export is read through janitor::clean_names(), which lower-cases every
  # column, while the codebook keeps the dashboard's own casing (AM_Loc_...).
  # Match case-insensitively and return the codebook's spelling, or a
  # dashboard-named variable silently fails to match its own item.
  out <- rep(NA_character_, length(columns))
  codes <- quest_codes[order(-nchar(quest_codes))]
  lc_codes <- tolower(codes); lc_quest <- tolower(quest_codes)
  for (j in seq_along(columns)) {
    col <- tolower(columns[j])
    hit <- match(col, lc_quest)
    if (!is.na(hit)) { out[j] <- quest_codes[hit]; next }
    pre <- which(startsWith(col, paste0(lc_codes, "_")))
    if (length(pre)) { out[j] <- codes[pre[1]]; next }
    d <- sub("^quest_", "", lc_codes)
    tail_ok <- nzchar(d) & vapply(d, function(dd) grepl(paste0("(^|[^0-9])", dd, "$"), col), logical(1))
    if (sum(tail_ok) == 1) out[j] <- codes[which(tail_ok)]
  }
  out
}

#' Resolve "If <question text> IS <value>" display conditions to item gates.
#'
#' Returns a list (one per row of items_u): NULL when the item has no
#' condition, list(item, equals) when the parent question was found by its
#' text, or the raw condition string when it was not.
mw_resolve_gates <- function(items_u) {
  norm <- function(x) tolower(gsub("[^a-z0-9 ]", "", gsub("\\s+", " ", tolower(x %||% ""))))
  texts <- norm(items_u$item_text)
  lapply(seq_len(nrow(items_u)), function(j) {
    cond <- items_u$display_condition[j]
    if (is.na(cond) || !nzchar(cond) || tolower(trimws(cond)) == "none") return(NULL)
    m <- regmatches(cond, regexec("^\\s*If\\s+(.*?)\\s+(IS NOT|IS|EQUALS|=)\\s+(.*?)\\s*$", cond, perl = TRUE))[[1]]
    if (!length(m)) return(cond)
    q <- norm(m[2]); parent <- which(texts == q & seq_along(texts) != j)
    if (!length(parent)) parent <- which(startsWith(texts, substr(q, 1, 40)) & seq_along(texts) != j)
    if (length(parent) != 1) return(cond)
    list(item = items_u$name[parent], equals = m[4], negate = m[3] == "IS NOT")
  })
}

#' Match codebook quest codes to data columns (exact, then trailing digits).
mw_match_columns <- function(quest_codes, columns) {
  out <- match_codebook_to_columns(quest_codes, columns)
  for (i in which(is.na(out))) {
    d <- sub("^quest_", "", quest_codes[i])
    cand <- columns[grepl(paste0("(^|[^0-9])", d, "$"), columns)]
    if (length(cand) == 1) out[i] <- cand
  }
  out
}

#' Propose the metricwire block from a project read.
#'
#' @param project Output of metricwire_project_read().
#' @param config Config list; supplies the connection keys to carry over and
#'   the REDCap id column for redcap_link_field.
#' @param id_pattern Regex the participant ID must match in the account field.
#' @param safety_regex Wording that marks a candidate safety item.
#' @param block_threshold Fraction of a survey's submissions that must answer
#'   an item for that survey to be said to carry it.
#' @return List: config (list(metricwire = ...)), todo, items, sessions.
metricwire_project_to_config <- function(project, config = NULL, id_pattern = "^[0-9]{3,6}$",
                                         safety_regex = "suicid|kill (my|your)self|hurt(ing)? (my|your)self|end (my|your) life|better off dead|not worth living|harm (my|your)self|die|dead",
                                         block_threshold = 0.5) {
  todo <- list()
  note <- function(section, key, status, text) {
    todo[[length(todo) + 1]] <<- tibble::tibble(section = section, key = key, status = status, note = text)
  }
  mw <- config$metricwire %||% list()
  frames <- project$data
  keys <- names(frames)

  # 1. Sessions and the Missed check (lesson C1)
  sessions <- list(); sess_detail <- list()
  for (k in keys) {
    df <- frames[[k]]
    rt <- if ("response_type" %in% names(df)) df$response_type else NA_character_
    n_sub <- sum(grepl("^submi", rt, ignore.case = TRUE)); n_miss <- sum(grepl("^miss", rt, ignore.case = TRUE))
    st <- project$sessions[project$sessions$key == k, ]
    sessions[[k]] <- list(analysis_id = if (is.na(st$analysis_id)) "TODO" else st$analysis_id,
                          analysis_name = if (is.na(st$analysis_name)) k else st$analysis_name,
                          label = if (is.na(st$analysis_name)) k else st$analysis_name,
                          arm = "all", file = st$file)
    if (is.na(st$analysis_id)) note("metricwire", paste0("sessions.", k, ".analysis_id"), "ask", "not known from the data; from the MetricWire analysis page")
    note("metricwire", paste0("sessions.", k, ".arm"), "default", "all; set the arm if only one condition receives this battery")
    if (nrow(df) == 0) {
      note("metricwire", paste0("sessions.", k, ".missed_rows"), "ask", "no data yet (codebook only); the Missed-rows check, observed ranges, prompt blocks and the ID field are pending the first pull")
    } else if (!"response_type" %in% names(df)) {
      note("metricwire", paste0("sessions.", k, ".response_type"), "ask", "no Response Type column; compliance cannot be computed from this export")
    } else if (n_miss == 0) {
      note("metricwire", paste0("sessions.", k), "ask",
           paste0("NO Missed rows in ", n_sub, " submissions: the analysis definition exports Submissions only and compliance will read 100% (lesson C1). Fix at source and re-pull"))
    } else {
      note("metricwire", paste0("sessions.", k, ".missed_rows"), "derived", paste0(n_miss, " Missed of ", n_sub + n_miss, " delivered"))
    }
    sess_detail[[k]] <- tibble::tibble(key = k, n_rows = nrow(df), n_submitted = n_sub, n_missed = n_miss,
                                       n_question_columns = length(mw_question_columns(df)),
                                       survey_names = if ("source_name" %in% names(df)) paste(sort(unique(stats::na.omit(df$source_name))), collapse = " | ") else NA_character_)
  }

  # 2. Items: union of question columns, matched to codebook and coding
  item_rows <- list()
  for (k in keys) {
    df <- frames[[k]]; qcols <- mw_question_columns(df)
    cb <- project$codebooks[[k]]; cod <- project$coding[[k]]
    submitted <- if ("response_type" %in% names(df)) grepl("^submi", df$response_type, ignore.case = TRUE) else rep(TRUE, nrow(df))
    col_code <- if (!is.null(cb) && nrow(cb)) mw_column_to_code(qcols, cb$quest_code) else rep(NA_character_, length(qcols))
    names(col_code) <- qcols
    for (col in qcols) {
      v <- df[[col]][submitted]; v <- v[!is.na(v) & nzchar(v)]
      num <- suppressWarnings(as.numeric(v))
      pct_num <- if (length(v)) mean(!is.na(num)) else NA_real_
      i <- if (!is.na(col_code[[col]])) which(cb$quest_code == col_code[[col]])[1] else NA_integer_
      item_text <- if (!is.na(i)) cb$item_text[i] else NA_character_
      # One item per question: survey copies of a code share the base id
      qcode <- mw_base_code(if (!is.na(i)) cb$quest_code[i] else col)
      qtype <- if (!is.na(i)) toupper(cb$question_type[i] %||% NA) else NA_character_
      coding_rng <- if (!is.null(cod)) { cc <- cod$code[cod$quest_code == qcode]; if (length(cc)) range(cc, na.rm = TRUE) else NULL } else NULL
      cb_rng <- if (!is.na(i) && !is.na(cb$response_min[i]) && !is.na(cb$response_max[i])) c(cb$response_min[i], cb$response_max[i]) else NULL
      item_rows[[length(item_rows) + 1]] <- tibble::tibble(
        session = k, column = col, quest_code = qcode,
        name = if (!is.na(i)) mw_item_name(cb, i) else col,
        item_text = item_text, question_type = qtype,
        survey = if (!is.na(i)) cb$survey_name[i] else NA_character_,
        display_condition = if (!is.na(i)) cb$display_condition[i] else NA_character_,
        declared_lo = (coding_rng %||% cb_rng %||% c(NA, NA))[1], declared_hi = (coding_rng %||% cb_rng %||% c(NA, NA))[2],
        declared_from = if (!is.null(coding_rng)) "coding" else if (!is.null(cb_rng)) "codebook" else NA_character_,
        observed_lo = if (any(!is.na(num))) min(num, na.rm = TRUE) else NA_real_,
        observed_hi = if (any(!is.na(num))) max(num, na.rm = TRUE) else NA_real_,
        n_answered = length(v), pct_numeric = pct_num,
        n_distinct = dplyr::n_distinct(v),
        free_text = identical(qtype, "TEXT") || (length(v) >= 5 && !is.na(pct_num) && pct_num < 0.5 && dplyr::n_distinct(v) / length(v) > 0.5),
        time_field = !is.na(qtype) && qtype %in% c("TIME", "DATE", "DATETIME"),
        multi_select = !is.na(qtype) && qtype %in% c("MULTIPLE_CHOICE", "MULTIPLE_CHOIC"),
        response_options = if (!is.na(i) && "response_options" %in% names(cb)) cb$response_options[i] else NA_character_)
    }
  }
  items <- dplyr::bind_rows(item_rows)
  if (!nrow(items)) stop("[metricwire_project_to_config] no question columns found in any session.", call. = FALSE)
  # Information screens and field-group headers are not items. A field
  # group's child questions are not in the codebook; they only appear as
  # columns in an export, and are flagged there under ema_items.names.
  info <- !is.na(items$question_type) & grepl("^INFORMATION|^FIELD_GROUP", items$question_type)
  if (any(info)) {
    note("metricwire", "ema_items.information", "derived", paste0(sum(info), " information screen(s) / field-group header(s) dropped: ", paste(unique(items$name[info]), collapse = ", ")))
    if (any(grepl("^FIELD_GROUP", items$question_type[info]))) note("metricwire", "ema_items.field_groups", "ask",
      paste0(sum(grepl("^FIELD_GROUP", items$question_type[info])), " field group(s) (", paste(unique(items$name[info & grepl("^FIELD_GROUP", items$question_type)]), collapse = ", "),
             "): their child questions are not listed in the codebook and arrive as unnamed columns on the first pull; name them then"))
    items <- items[!info, ]
  }
  # The same question coded differently in two surveys (lesson C2 across batteries)
  rng_conflict <- items |>
    dplyr::filter(!is.na(.data$declared_lo)) |>
    dplyr::distinct(.data$quest_code, .data$survey, .data$declared_lo, .data$declared_hi) |>
    dplyr::mutate(n_codings = dplyr::n_distinct(paste(.data$declared_lo, .data$declared_hi)), .by = "quest_code") |>
    dplyr::filter(.data$n_codings > 1)
  # One row per item across sessions: same quest code = same item.
  items_u <- items |>
    dplyr::summarise(
      column = paste(unique(.data$column), collapse = " | "),
      name = dplyr::first(stats::na.omit(.data$name)),
      item_text = dplyr::first(stats::na.omit(.data$item_text)),
      question_type = dplyr::first(stats::na.omit(.data$question_type)),
      display_condition = dplyr::first(stats::na.omit(.data$display_condition)),
      declared_lo = dplyr::first(stats::na.omit(.data$declared_lo)), declared_hi = dplyr::first(stats::na.omit(.data$declared_hi)),
      declared_from = dplyr::first(stats::na.omit(.data$declared_from)),
      observed_lo = suppressWarnings(min(.data$observed_lo, na.rm = TRUE)), observed_hi = suppressWarnings(max(.data$observed_hi, na.rm = TRUE)),
      n_answered = sum(.data$n_answered), free_text = any(.data$free_text),
      time_field = any(.data$time_field), multi_select = any(.data$multi_select),
      response_options = dplyr::first(stats::na.omit(.data$response_options)),
      sessions = paste(unique(.data$session), collapse = ","),
      .by = "quest_code") |>
    dplyr::mutate(observed_lo = ifelse(is.finite(.data$observed_lo), .data$observed_lo, NA_real_),
                  observed_hi = ifelse(is.finite(.data$observed_hi), .data$observed_hi, NA_real_))
  items_u$name[is.na(items_u$name)] <- items_u$quest_code[is.na(items_u$name)]
  items_u$name <- make.unique(slug(items_u$name), sep = "_")
  for (qc in unique(rng_conflict$quest_code)) {
    r <- rng_conflict[rng_conflict$quest_code == qc, ]
    nm <- items_u$name[items_u$quest_code == qc]
    note("metricwire", paste0("ema_items.", nm, ".range"), "ask",
         paste0("coded differently by survey: ", paste0(r$survey %||% "?", " ", r$declared_lo, "-", r$declared_hi, collapse = "; "),
                ". Recode to one scale before pooling (lesson C2); the proposal keeps the first"))
  }
  no_cb <- items_u$name[is.na(items_u$item_text)]
  if (length(no_cb)) note("metricwire", "ema_items.names", "ask", paste0(length(no_cb), " column(s) have no codebook entry and keep their column name: ", paste(utils::head(no_cb, 8), collapse = ", ")))

  # 3. Prompt blocks (lesson C3): which survey carries which item
  blocks <- list(); carried <- stats::setNames(vector("list", nrow(items_u)), items_u$quest_code)
  for (k in keys) {
    df <- frames[[k]]
    if (!"source_name" %in% names(df)) next
    submitted <- if ("response_type" %in% names(df)) grepl("^submi", df$response_type, ignore.case = TRUE) else rep(TRUE, nrow(df))
    d <- df[submitted, ]
    for (sv in sort(unique(stats::na.omit(d$source_name)))) {
      rows <- d[d$source_name == sv, ]
      if (!nrow(rows)) next
      its <- character(0)
      for (j in seq_len(nrow(items))) {
        if (items$session[j] != k) next
        col <- items$column[j]
        frac <- mean(!is.na(rows[[col]]) & nzchar(rows[[col]]))
        if (frac >= block_threshold) {
          its <- c(its, items_u$name[items_u$quest_code == items$quest_code[j]])
          carried[[items$quest_code[j]]] <- unique(c(carried[[items$quest_code[j]]], sv))
        }
      }
      blocks[[k]][[slug(sv)]] <- as.list(unique(its))
    }
  }
  if (!length(blocks) && !is.null(project$templates) && nrow(project$templates)) {
    # No data yet: survey membership from the Data Import templates.
    tp <- project$templates
    tp$quest_code <- mw_column_to_code(tp$column, items_u$quest_code)
    for (sv in unique(tp$survey)) {
      its <- items_u$name[match(unique(stats::na.omit(tp$quest_code[tp$survey == sv])), items_u$quest_code)]
      its <- its[!is.na(its) & !its %in% items_u$name[items_u$free_text | items_u$time_field | items_u$multi_select]]
      for (k in keys) blocks[[k]][[slug(sv)]] <- as.list(its)
      for (qc in unique(stats::na.omit(tp$quest_code[tp$survey == sv]))) carried[[qc]] <- unique(c(carried[[qc]], sv))
    }
    unmatched_cols <- tp$column[is.na(tp$quest_code)]
    note("metricwire", "prompt_blocks", "inferred", paste0("from the Data Import templates (no data yet): ", dplyr::n_distinct(tp$survey), " survey(s); ",
                                                          if (length(unmatched_cols)) paste0(length(unmatched_cols), " template column(s) have no codebook entry: ", paste(utils::head(unmatched_cols, 10), collapse = ", ")) else "every template column matched a codebook item"))
  }
  n_surveys <- length(unique(unlist(lapply(blocks, names))))
  if (n_surveys > 1) note("metricwire", "prompt_blocks", "inferred", paste0(n_surveys, " survey name(s); an item is carried by a survey when >= ", 100 * block_threshold, "% of its submissions answer it. Confirm with the PI which prompts carry which blocks"))

  # 4. Ranges: declared vs observed (lesson C2)
  for (j in seq_len(nrow(items_u))) {
    it <- items_u[j, ]
    if (it$free_text) next
    key <- paste0("ema_items.", it$name, ".range")
    if (is.na(it$declared_lo)) {
      if (!is.na(it$observed_lo)) note("metricwire", key, "inferred", paste0("no codebook/coding range; observed ", it$observed_lo, "-", it$observed_hi))
      else note("metricwire", key, "ask", "no declared range and no numeric responses")
    } else {
      status <- if (it$declared_from == "coding") "derived" else "inferred"
      msg <- paste0(it$declared_from, " ", it$declared_lo, "-", it$declared_hi)
      if (!is.na(it$observed_lo) && (it$observed_lo < it$declared_lo || it$observed_hi > it$declared_hi)) {
        status <- "ask"; msg <- paste0(msg, " but OBSERVED ", it$observed_lo, "-", it$observed_hi, ": a zero-based momentary scale against a one-based declaration, or the reverse (lesson C2). Fix the range, do not proceed with NAs")
      } else if (!is.na(it$observed_lo) && it$declared_from == "codebook" && (it$observed_lo > it$declared_lo)) {
        msg <- paste0(msg, "; observed ", it$observed_lo, "-", it$observed_hi, " never reaches the floor")
      }
      note("metricwire", key, status, msg)
    }
  }

  # 5. Safety candidates by wording; thresholds are never derived
  safety <- items_u[!is.na(items_u$item_text) & grepl(safety_regex, items_u$item_text, ignore.case = TRUE), ]
  if (nrow(safety)) note("metricwire", "safety_items", "ask", paste0(nrow(safety), " item(s) whose wording suggests a safety item: ", paste(safety$name, collapse = ", "), ". Set safety_min per item from the protocol; the flag threshold is the study's, not the wording's"))

  # 6. Free text
  ft <- items_u[items_u$free_text, ]
  if (nrow(ft)) note("metricwire", "free_text_fields", "derived", paste0(nrow(ft), " free-text item(s), diverted to _RESTRICTED at 04: ", paste(ft$name, collapse = ", ")))

  # 7. Which account field holds the participant ID
  id_candidates <- unique(unlist(lapply(frames, function(df) names(df)[grepl("^(user_|participant|first_name|last_name)|_(first|last)_name$", names(df))])))
  id_candidates <- setdiff(id_candidates, c("user_id_hex"))
  id_scores <- purrr::map_dfr(id_candidates, function(colname) {
    vals <- unlist(lapply(frames, function(df) if (colname %in% names(df)) df[[colname]] else NULL))
    vals <- trimws(vals[!is.na(vals) & nzchar(vals)])
    tibble::tibble(field = colname, n = length(vals), pct_match = if (length(vals)) mean(grepl(id_pattern, vals)) else 0,
                   lo = suppressWarnings(min(as.numeric(vals[grepl(id_pattern, vals)]), na.rm = TRUE)),
                   hi = suppressWarnings(max(as.numeric(vals[grepl(id_pattern, vals)]), na.rm = TRUE)))
  })
  id_column <- "TODO"; id_range <- NULL
  if (!nrow(id_scores) && all(vapply(frames, nrow, integer(1)) == 0)) {
    note("metricwire", "id_column", "ask", "no data yet; the account field holding the participant id is decided on the first pull")
  } else if (nrow(id_scores) && max(id_scores$pct_match) >= 0.5) {
    best <- id_scores[which.max(id_scores$pct_match), ]
    id_column <- best$field
    id_range <- if (is.finite(best$lo)) as_whole(c(best$lo, best$hi)) else NULL
    others <- id_scores$field[id_scores$pct_match > 0 & id_scores$field != best$field]
    note("metricwire", "id_column", if (best$pct_match >= 0.95) "derived" else "inferred",
         paste0(best$field, ": ", round(100 * best$pct_match), "% of values match ", id_pattern,
                if (length(others)) paste0("; also matches in ", paste(others, collapse = ", "), " (a coalesce resolver as in UFOs may be needed)") else ""))
    if (!is.null(id_range)) note("metricwire", "id_range", "inferred", paste0("observed ", id_range[1], "-", id_range[2], "; declare the protocol's range so out-of-range tokens are rejected"))
  } else if (nrow(id_scores) || any(vapply(frames, nrow, integer(1)) > 0)) {
    note("metricwire", "id_column", "ask", paste0("no account field matches ", id_pattern, " in >= 50% of rows; candidates: ", paste(id_candidates, collapse = ", ")))
  }

  # 8. Gates: the dashboard codebook states them as "If <question> IS <value>"
  gates <- mw_resolve_gates(items_u)
  if (!any(!is.na(items_u$display_condition))) {
    note("metricwire", "ema_items.*.gate", "ask", "gates (an item shown only when another item fired) are not in this codebook; declare them from the survey logic")
  } else {
    for (j in which(!vapply(gates, is.null, logical(1)))) {
      g <- gates[[j]]
      if (is.character(g)) note("metricwire", paste0("ema_items.", items_u$name[j], ".gate"), "ask", paste0("display condition not resolved to an item: ", g))
      else note("metricwire", paste0("ema_items.", items_u$name[j], ".gate"), "derived", paste0("shown only when ", g$item, " is '", g$equals, "'"))
    }
  }

  # 9. Assemble
  ema_items <- lapply(seq_len(nrow(items_u)), function(j) {
    it <- items_u[j, ]
    if (it$free_text || it$time_field || it$multi_select) return(NULL)
    rng <- if (!is.na(it$declared_lo)) c(it$declared_lo, it$declared_hi) else if (!is.na(it$observed_lo)) c(it$observed_lo, it$observed_hi) else c(0, 0)
    raw <- strsplit(it$column, " | ", fixed = TRUE)[[1]]
    list(name = it$name, raw = if (length(raw) > 1) as.list(raw) else raw, quest_code = it$quest_code, range = as_whole(rng), gate = gates[[j]] %||% "none",
         prompts = as.list(carried[[it$quest_code]] %||% list()), item_text = it$item_text %||% NA_character_)
  })
  ema_items <- Filter(Negate(is.null), ema_items)
  block <- list(
    enabled = TRUE,
    base_url = mw$base_url %||% "https://consumer-api.metricwire.com",
    workspace_id = mw$workspace_id %||% "TODO",
    token_url = mw$token_url %||% "https://consumer-api.metricwire.com/oauth/token",
    oauth_id_service = mw$oauth_id_service %||% "mw_client_id", oauth_id_key = mw$oauth_id_key %||% "TODO",
    oauth_secret_service = mw$oauth_secret_service %||% "mw_client_secret", oauth_secret_key = mw$oauth_secret_key %||% "TODO",
    id_column = id_column, id_fields = if (nrow(id_scores)) as.list(id_scores$field[id_scores$pct_match > 0]) else list(),
    redcap_link_field = config$redcap$id_column %||% "id",
    sessions = sessions,
    ema_items = ema_items,
    free_text_fields = as.list(ft$name),
    time_fields = lapply(which(items_u$time_field), function(j) list(name = items_u$name[j], raw = items_u$column[j], item_text = items_u$item_text[j])),
    multi_select_fields = lapply(which(items_u$multi_select & !items_u$free_text), function(j)
      list(name = items_u$name[j], raw = items_u$column[j], item_text = items_u$item_text[j], options = items_u$response_options[j] %||% NA_character_)),
    safety_items = lapply(seq_len(nrow(safety)), function(j) list(name = safety$name[j], item_text = safety$item_text[j], safety_min = NULL)),
    prompt_blocks = blocks)
  if (!is.null(id_range)) block$id_range <- id_range
  if (!is.null(project$studies) && nrow(project$studies)) {
    block$studies_in_workspace <- as.list(project$studies[[intersect(c("name", "internal_name", "internalName"), names(project$studies))[1]]])
    note("metricwire", "study_id", "ask", paste0(nrow(project$studies), " studies in the workspace; two can share a participant-facing name (UFOs). Leave study_id null unless the roster must be restricted"))
  }
  if (any(items_u$time_field)) note("metricwire", "time_fields", "derived", paste0(sum(items_u$time_field), " clock-time question(s) kept as time_fields, not scored: ", paste(items_u$name[items_u$time_field], collapse = ", ")))
  if (any(items_u$multi_select & !items_u$free_text)) note("metricwire", "multi_select_fields", "derived", paste0(sum(items_u$multi_select & !items_u$free_text), " select-all question(s) kept as multi_select_fields (exported as joined codes, not a scale): ", paste(items_u$name[items_u$multi_select & !items_u$free_text], collapse = ", ")))
  note("metricwire", "battery_map", "ask", "which battery each session is, and the evidence (a verified cross-check against randomization), is not in MetricWire")

  list(config = list(metricwire = block),
       todo = dplyr::bind_rows(todo) |> dplyr::mutate(status = factor(.data$status, levels = c("derived", "inferred", "default", "ask"))),
       items = items_u, sessions = dplyr::bind_rows(sess_detail), source = project$source, read_at = project$read_at)
}

#' Print the proposal summary and the questions.
metricwire_config_report <- function(proposal) {
  mw <- proposal$config$metricwire
  log_section(paste0("Proposed metricwire block (", proposal$source, ")"))
  cat("• Sessions: ", paste(names(mw$sessions), collapse = ", "), "\n", sep = "")
  cat("• Items: ", length(mw$ema_items), " scored, ", length(mw$free_text_fields), " free text, ",
      length(mw$safety_items), " safety candidate(s)\n", sep = "")
  cat("• ID column: ", mw$id_column, if (!is.null(mw$id_range)) paste0("  range ", mw$id_range[1], "-", mw$id_range[2]) else "", "\n", sep = "")
  print(proposal$sessions)
  n <- table(proposal$todo$status)
  cat("• Todo: ", paste(names(n), n, sep = " ", collapse = ", "), "\n", sep = "")
  ask <- proposal$todo[proposal$todo$status == "ask", ]
  if (nrow(ask)) {
    cat("\nTo confirm with the study team:\n")
    for (i in seq_len(nrow(ask))) cat("  ", ask$section[i], ".", ask$key[i], ": ", ask$note[i], "\n", sep = "")
  }
  invisible(proposal$todo)
}

#' Merge two proposals (e.g. REDCap then MetricWire): later top-level blocks win.
merge_proposals <- function(a, b) {
  cfg <- a$config
  for (n in names(b$config)) cfg[[n]] <- b$config[[n]]
  todo <- dplyr::bind_rows(a$todo |> dplyr::mutate(status = as.character(.data$status)),
                           b$todo |> dplyr::mutate(status = as.character(.data$status))) |>
    dplyr::mutate(status = factor(.data$status, levels = c("derived", "inferred", "default", "ask")))
  list(config = cfg, todo = todo, source = paste(unique(c(a$source, b$source)), collapse = "+"),
       read_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
}
