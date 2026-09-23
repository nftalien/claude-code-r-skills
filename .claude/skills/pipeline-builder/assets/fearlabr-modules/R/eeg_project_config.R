# ════════════════════════════════════════════════════════════════════════
# R/eeg_project_config.R — Propose the eeg block from the EEG files themselves
# ════════════════════════════════════════════════════════════════════════
# There is no EEG metadata system to query. What exists is the feature
# export the preprocessing tool wrote, the BrainVision header and marker
# files from the recording (.vhdr, .vmrk), and, when the lab keeps BIDS,
# the sidecars (participants.tsv, *_eeg.json, *_events.tsv) and an ERPLAB
# bin descriptor. This module reads those and proposes:
#
#   columns       crosswalk from the export header, by name vocabulary
#   id_transform  from the shape of the IDs (prefix, zero padding)
#   session_map   export session labels against the declared timepoints
#   features      one candidate per measure x condition present
#   qc            thresholds from the observed distributions, marked default
#   recording     sampling rate, channels, reference, filters, amplifier and
#                 software, from .vhdr and *_eeg.json, for the methods
#                 section and the COBIDAS MEEG review; the pipeline never
#                 computes on it. One source of truth: it lives in _config.yml.
#
# Statuses as elsewhere: derived, inferred, default, ask. Which timepoints
# expect EEG, which feature the plan names, and the window in ms are asked.
# ════════════════════════════════════════════════════════════════════════

# ── Export header ──────────────────────────────────────────────────────

eeg_column_vocabulary <- function() list(
  id        = c("study_id", "subject", "subject_id", "participant", "participant_id", "sub", "id", "pid", "erpset"),
  session   = c("session", "ses", "visit", "timepoint", "wave", "time", "run"),
  channel   = c("channel", "chan", "electrode", "roi", "ch", "chlabel", "chindex"),
  condition = c("condition", "bin", "bin_label", "binlabel", "trial_type", "event", "cond", "marker"),
  measure   = c("measure", "metric", "component", "feature", "quantity", "measurement"),
  value     = c("value", "amplitude", "mean_amplitude", "mean_amp", "latency", "peak", "area", "val", "measurement_value"),
  n_trials  = c("n_trials", "ntrials", "nave", "trials", "n_epochs", "nepochs", "trial_count", "accepted_trials", "n_accepted"))

#' Propose the eeg.columns crosswalk from an export's column names.
#'
#' @return List: columns (canonical -> export name, only for matches) and
#'   detail (tibble canonical, export, how).
eeg_detect_columns <- function(names) {
  vocab <- eeg_column_vocabulary(); sn <- mw_snake(names)
  used <- character(0); out <- list(); rows <- list()
  for (k in names(vocab)) {
    hit <- which(sn %in% vocab[[k]] & !names %in% used)
    how <- "exact"
    if (!length(hit)) {
      hit <- which(vapply(sn, function(s) any(startsWith(s, vocab[[k]]) | endsWith(s, vocab[[k]])), logical(1)) & !names %in% used)
      how <- "partial"
    }
    if (length(hit)) {
      out[[k]] <- names[hit[1]]; used <- c(used, names[hit[1]])
      rows[[k]] <- tibble::tibble(canonical = k, export = names[hit[1]], how = how)
    }
  }
  list(columns = out, detail = dplyr::bind_rows(rows), unmatched = setdiff(names, used))
}

eeg_channel_regex <- function() "^(fp|af|f|fc|ft|c|cp|t|tp|p|po|o|i|cz|fz|pz|oz|fcz|cpz|m|a|tp)[0-9]{0,2}(z)?$"

#' Read a feature export (CSV or TSV) as character; detect wide layout.
eeg_read_export <- function(path) {
  stopifnot(file.exists(path))
  df <- if (grepl("\\.tsv$|\\.txt$", path, ignore.case = TRUE)) {
    readr::read_tsv(path, col_types = readr::cols(.default = readr::col_character()), show_col_types = FALSE, name_repair = "minimal")
  } else readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()), show_col_types = FALSE, name_repair = "minimal")
  det <- eeg_detect_columns(names(df))
  chan_like <- names(df)[grepl(eeg_channel_regex(), tolower(gsub("_?uv$", "", names(df))))]
  wide <- is.null(det$columns$value) && length(chan_like) >= 3
  attr(df, "detect") <- det; attr(df, "wide") <- wide; attr(df, "channel_columns") <- chan_like
  attr(df, "source_file") <- basename(path)
  df
}

# ── BrainVision ────────────────────────────────────────────────────────

bv_sections <- function(lines) {
  sec <- NA_character_; out <- list()
  for (ln in lines) {
    if (grepl("^\\[.+\\]\\s*$", ln)) { sec <- gsub("^\\[|\\]\\s*$", "", ln); out[[sec]] <- character(0); next }
    if (!is.na(sec)) out[[sec]] <- c(out[[sec]], ln)
  }
  out
}
bv_kv <- function(lines) {
  lines <- lines[!grepl("^\\s*;", lines) & grepl("=", lines, fixed = TRUE)]
  k <- sub("=.*$", "", lines); v <- sub("^[^=]*=", "", lines)
  stats::setNames(as.list(trimws(v)), trimws(k))
}
bv_num <- function(x) suppressWarnings(as.numeric(gsub("[^0-9.eE+-]", "", x %||% NA_character_)))

#' Parse a BrainVision header (.vhdr).
#'
#' @return List: file, software, data_file, marker_file, data_format,
#'   n_channels, sampling_interval_us, sampling_rate_hz, channels (tibble
#'   name, reference, resolution, unit), reference, unit, hardware_filters
#'   (low_cutoff_s, high_cutoff_hz, notch_hz), amplifier, recorder_version.
brainvision_read_vhdr <- function(path) {
  stopifnot(file.exists(path))
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  lines <- iconv(lines, from = "UTF-8", to = "UTF-8", sub = "")
  if (!any(grepl("Brain ?Vision", lines[1:min(3, length(lines))], ignore.case = TRUE))) {
    stop("[brainvision_read_vhdr] ", basename(path), " does not start with a BrainVision header line.", call. = FALSE)
  }
  sec <- bv_sections(lines)
  ci <- bv_kv(sec[["Common Infos"]] %||% character(0))
  ch_lines <- sec[["Channel Infos"]] %||% character(0)
  ch_lines <- ch_lines[grepl("^Ch[0-9]+=", ch_lines)]
  channels <- purrr::map_dfr(ch_lines, function(l) {
    v <- strsplit(sub("^Ch[0-9]+=", "", l), ",", fixed = TRUE)[[1]]
    v <- c(v, rep("", 4 - length(v)))[1:4]
    tibble::tibble(number = as.integer(sub("^Ch([0-9]+)=.*$", "\\1", l)),
                   name = gsub("\\\\1", ",", trimws(v[1])), reference = trimws(v[2]),
                   resolution = suppressWarnings(as.numeric(v[3])), unit = trimws(v[4]))
  })
  comment <- sec[["Comment"]] %||% character(0)
  grab <- function(pattern) { h <- grep(pattern, comment, ignore.case = TRUE, value = TRUE); if (length(h)) trimws(sub(paste0(".*", pattern, "\\s*:?\\s*"), "", h[1], ignore.case = TRUE)) else NA_character_ }
  si <- bv_num(ci$SamplingInterval)
  sr_comment <- bv_num(grab("Sampling Rate \\[Hz\\]"))
  sr <- if (!is.na(si) && si > 0) 1e6 / si else sr_comment
  # Hardware filter row: "1     Fp1         1                0.1 µV             10              1000              Off"
  hw <- list(low_cutoff_s = NA_real_, high_cutoff_hz = NA_real_, notch_hz = NA_character_)
  hdr_i <- grep("Low Cutoff", comment, ignore.case = TRUE)
  if (length(hdr_i)) {
    rows <- comment[(hdr_i[1] + 1):length(comment)]
    rows <- rows[grepl("^\\s*[0-9]+\\s+\\S+", rows)]
    if (length(rows)) {
      f <- strsplit(trimws(rows[1]), "\\s+")[[1]]
      # #, Name, Phys.Chn., Resolution, Unit, LowCutoff, HighCutoff, Notch
      if (length(f) >= 8) hw <- list(low_cutoff_s = suppressWarnings(as.numeric(f[6])), high_cutoff_hz = suppressWarnings(as.numeric(f[7])), notch_hz = f[8])
    }
  }
  amp <- grep("BrainAmp|actiCHamp|LiveAmp|QuickAmp|V-Amp|amplifier", comment, ignore.case = TRUE, value = TRUE)
  amp <- if (length(amp)) trimws(amp[!grepl("A m p l i f i e r", amp)][1]) else NA_character_
  ref <- unique(channels$reference[nzchar(channels$reference)])
  list(file = basename(path), software = trimws(lines[1]),
       recorder_version = grab("Version"),
       data_file = ci$DataFile, marker_file = ci$MarkerFile, data_format = ci$DataFormat,
       n_channels = as.integer(bv_num(ci$NumberOfChannels)) %||% nrow(channels),
       sampling_interval_us = si, sampling_rate_hz = sr,
       channels = channels,
       reference = if (length(ref) == 1) ref else if (!length(ref)) "common (unnamed in header)" else paste(ref, collapse = "/"),
       unit = if (nrow(channels)) names(sort(table(channels$unit), decreasing = TRUE))[1] else NA_character_,
       hardware_filters = hw, amplifier = if (is.na(amp) || !nzchar(amp)) NA_character_ else amp)
}

#' Parse a BrainVision marker file (.vmrk).
#'
#' @return Tibble number, type, description, position, size, channel, date.
brainvision_read_vmrk <- function(path) {
  stopifnot(file.exists(path))
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  sec <- bv_sections(lines)
  mk <- sec[["Marker Infos"]] %||% character(0)
  mk <- mk[grepl("^Mk[0-9]+=", mk)]
  purrr::map_dfr(mk, function(l) {
    v <- strsplit(sub("^Mk[0-9]+=", "", l), ",", fixed = TRUE)[[1]]
    v <- c(v, rep("", 6 - length(v)))[1:6]
    tibble::tibble(number = as.integer(sub("^Mk([0-9]+)=.*$", "\\1", l)), type = trimws(v[1]),
                   description = trimws(v[2]), position = suppressWarnings(as.integer(v[3])),
                   size = suppressWarnings(as.integer(v[4])), channel = suppressWarnings(as.integer(v[5])),
                   date = if (nzchar(trimws(v[6]))) trimws(v[6]) else NA_character_)
  })
}

#' Marker counts by type and description (trial counts per code).
brainvision_marker_summary <- function(markers) {
  markers |>
    dplyr::filter(!.data$type %in% c("New Segment", "")) |>
    dplyr::count(.data$type, .data$description, name = "n") |>
    dplyr::arrange(.data$type, dplyr::desc(.data$n))
}

# ── BIDS sidecars and ERPLAB ───────────────────────────────────────────

bids_read_eeg_json <- function(path) {
  stopifnot(file.exists(path))
  j <- jsonlite::fromJSON(path, simplifyVector = TRUE)
  j$file <- basename(path); j
}
bids_read_participants <- function(path) {
  stopifnot(file.exists(path))
  readr::read_tsv(path, col_types = readr::cols(.default = readr::col_character()), show_col_types = FALSE)
}
bids_read_events <- function(path) {
  stopifnot(file.exists(path))
  ev <- readr::read_tsv(path, col_types = readr::cols(.default = readr::col_character()), show_col_types = FALSE)
  ev$file <- basename(path); ev
}
bids_event_counts <- function(events) {
  col <- intersect(c("trial_type", "value", "event_type"), names(events))[1]
  if (is.na(col)) return(tibble::tibble(condition = character(), n = integer()))
  events |> dplyr::count(condition = .data[[col]], name = "n") |> dplyr::arrange(dplyr::desc(.data$n))
}

#' ERPLAB bin descriptor: "bin N" line, label line, then the criterion line.
erplab_read_bin_descriptor <- function(path) {
  stopifnot(file.exists(path))
  lines <- trimws(readLines(path, warn = FALSE))
  i <- grep("^bin\\s+[0-9]+", lines, ignore.case = TRUE)
  if (!length(i)) stop("[erplab_read_bin_descriptor] no 'bin N' lines in ", basename(path), call. = FALSE)
  tibble::tibble(bin = as.integer(sub("^bin\\s+([0-9]+).*$", "\\1", lines[i], ignore.case = TRUE)),
                 label = ifelse(i + 1 <= length(lines), lines[i + 1], NA_character_),
                 criterion = ifelse(i + 2 <= length(lines), lines[i + 2], NA_character_))
}

#' A long trial-count table (id, session?, condition, n_trials) from any tool.
eeg_read_trial_counts <- function(path) {
  stopifnot(file.exists(path))
  df <- readr::read_csv(path, col_types = readr::cols(.default = readr::col_character()), show_col_types = FALSE)
  det <- eeg_detect_columns(names(df))
  need <- c("id", "condition", "n_trials"); miss <- setdiff(need, names(det$columns))
  if (length(miss)) stop("[eeg_read_trial_counts] cannot find column(s) for ", paste(miss, collapse = ", "), call. = FALSE)
  out <- tibble::tibble(id = df[[det$columns$id]], condition = df[[det$columns$condition]],
                        n_trials = suppressWarnings(as.integer(df[[det$columns$n_trials]])))
  out$session <- if (!is.null(det$columns$session)) df[[det$columns$session]] else NA_character_
  out
}

# ── Read everything ────────────────────────────────────────────────────

expand_paths <- function(x) {
  if (is.null(x)) return(character(0))
  out <- unlist(lapply(x, function(p) if (file.exists(p) && !dir.exists(p)) p else Sys.glob(p)))
  unique(out[file.exists(out)])
}

#' Gather EEG metadata from files.
#'
#' @param config Config list (for eeg.file_glob and paths.raw_data), optional.
#' @param exports Feature export paths or globs; default eeg.file_glob.
#' @param vhdr,vmrk,eeg_json,participants,events,bin_descriptor,trial_counts
#'   Paths or globs; each optional.
eeg_project_read <- function(config = NULL, exports = NULL, vhdr = NULL, vmrk = NULL, eeg_json = NULL,
                             participants = NULL, events = NULL, bin_descriptor = NULL, trial_counts = NULL) {
  ex <- expand_paths(exports)
  if (!length(ex) && !is.null(config)) ex <- builder_glob_files(config, config$eeg$file_glob %||% "eeg/*.csv")
  tables <- lapply(ex, eeg_read_export); names(tables) <- basename(ex)
  for (f in names(tables)) cat("• export ", f, ": ", nrow(tables[[f]]), " rows, ", ncol(tables[[f]]), " columns",
                              if (isTRUE(attr(tables[[f]], "wide"))) " (WIDE layout)" else "", "\n", sep = "")
  vh <- lapply(expand_paths(vhdr), brainvision_read_vhdr)
  if (length(vh)) cat("• ", length(vh), " BrainVision header(s); first: ", vh[[1]]$sampling_rate_hz, " Hz, ",
                      vh[[1]]$n_channels, " channels\n", sep = "")
  vm <- lapply(expand_paths(vmrk), brainvision_read_vmrk)
  if (length(vm)) cat("• ", length(vm), " marker file(s)\n", sep = "")
  js <- lapply(expand_paths(eeg_json), bids_read_eeg_json)
  pt <- if (length(expand_paths(participants))) bids_read_participants(expand_paths(participants)[1]) else NULL
  evs <- lapply(expand_paths(events), bids_read_events)
  bins <- if (length(expand_paths(bin_descriptor))) erplab_read_bin_descriptor(expand_paths(bin_descriptor)[1]) else NULL
  tc <- if (length(expand_paths(trial_counts))) dplyr::bind_rows(lapply(expand_paths(trial_counts), eeg_read_trial_counts)) else NULL
  if (!length(tables) && !length(vh) && !length(js)) stop("[eeg_project_read] nothing to read: no export, .vhdr or *_eeg.json found.", call. = FALSE)
  list(source = "files", exports = tables, vhdr = vh, vmrk = vm, eeg_json = js, participants = pt,
       events = evs, bins = bins, trial_counts = tc, read_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
}

# ── Derivation ─────────────────────────────────────────────────────────

#' Prefix and padding from a vector of IDs.
infer_id_transform <- function(ids) {
  ids <- unique(trimws(as.character(ids))); ids <- ids[!is.na(ids) & nzchar(ids)]
  if (!length(ids)) return(list(transform = list(), pattern = NA_character_, note = "no ids"))
  pre <- sub("[0-9]+$", "", ids)
  prefix <- if (dplyr::n_distinct(pre) == 1 && nzchar(pre[1])) pre[1] else ""
  num <- sub("^.*?([0-9]+)$", "\\1", ids)
  numeric_tail <- grepl("[0-9]+$", ids)
  if (!all(numeric_tail)) return(list(transform = list(), pattern = NA_character_,
                                      note = paste0("ids do not end in digits: ", paste(utils::head(ids[!numeric_tail], 5), collapse = ", "))))
  w <- max(nchar(num))
  list(transform = c(if (nzchar(prefix)) list(strip_prefix = prefix), list(pad_width = w)),
       pattern = paste0("^[0-9]{", w, "}$"),
       note = paste0(if (nzchar(prefix)) paste0("prefix '", prefix, "' stripped; ") else "", "numeric part padded to ", w))
}

round_out <- function(lo, hi, to = 10) c(floor(lo / to) * to, ceiling(hi / to) * to)

#' Propose the eeg block.
#'
#' @param project Output of eeg_project_read().
#' @param config Config list; timepoints.schedule drives the session map and
#'   redcap.id_column labels the crosswalk check.
#' @param redcap_ids Optional character vector of REDCap IDs for the overlap check.
eeg_project_to_config <- function(project, config = NULL, redcap_ids = NULL) {
  todo <- list()
  note <- function(section, key, status, text) todo[[length(todo) + 1]] <<- tibble::tibble(section = section, key = key, status = status, note = text)
  block <- list(enabled = TRUE, format = "long")
  tables <- project$exports

  # Files and glob
  if (length(tables)) {
    fn <- names(tables)
    stem_glob <- if (length(fn) == 1) sub("^[^_]+_", "*_", fn) else {
      suf <- Reduce(function(a, b) { i <- 0; while (i < min(nchar(a), nchar(b)) && substr(a, nchar(a) - i, nchar(a) - i) == substr(b, nchar(b) - i, nchar(b) - i)) i <- i + 1; substr(a, nchar(a) - i + 1, nchar(a)) }, fn)
      paste0("*", suf)
    }
    block$file_glob <- paste0("eeg/", stem_glob)
    note("eeg", "file_glob", "inferred", paste0("from ", length(fn), " export file name(s): ", block$file_glob))
  }

  # Columns
  long <- NULL
  if (length(tables)) {
    wide <- vapply(tables, function(t) isTRUE(attr(t, "wide")), logical(1))
    if (any(wide)) {
      note("eeg", "format", "ask", paste0("WIDE export (channels as columns: ", paste(utils::head(attr(tables[[which(wide)[1]]], "channel_columns"), 6), collapse = ", "),
                                          "). 0.2.0 reads long only; reshape at export (references/modality-eeg.md) or pivot_longer before ingest"))
    }
    all_names <- unique(unlist(lapply(tables, names)))
    det <- eeg_detect_columns(all_names)
    block$columns <- det$columns
    for (i in seq_len(nrow(det$detail))) note("eeg", paste0("columns.", det$detail$canonical[i]), "inferred", paste0(det$detail$export[i], " (", det$detail$how[i], " name match)"))
    for (k in c("id", "channel", "measure", "value")) if (is.null(det$columns[[k]]) && !any(wide)) note("eeg", paste0("columns.", k), "ask", paste0("no export column looks like ", k, "; candidates: ", paste(det$unmatched, collapse = ", ")))
    if (length(det$unmatched)) note("eeg", "columns.unmatched", "derived", paste0("export columns not used: ", paste(det$unmatched, collapse = ", ")))
    if (!any(wide) && all(c("id", "channel", "measure", "value") %in% names(det$columns))) {
      long <- dplyr::bind_rows(lapply(tables, function(t) {
        out <- tibble::tibble(.rows = nrow(t))
        for (k in names(det$columns)) out[[k]] <- if (det$columns[[k]] %in% names(t)) t[[det$columns[[k]]]] else NA_character_
        out
      }))
      long$value_num <- suppressWarnings(as.numeric(long$value))
      long$n_trials_num <- if ("n_trials" %in% names(long)) suppressWarnings(as.integer(long$n_trials)) else NA_integer_
    }
  }

  # IDs
  ids <- if (!is.null(long)) long$id else if (!is.null(project$participants)) project$participants[[1]] else NULL
  if (!is.null(ids)) {
    it <- infer_id_transform(ids)
    if (length(it$transform)) { block$id_transform <- it$transform; block$id_pattern <- it$pattern
      note("eeg", "id_transform", "inferred", paste0(it$note, "; ", dplyr::n_distinct(ids), " participant(s)")) }
    else note("eeg", "id_transform", "ask", it$note)
    if (!is.null(redcap_ids) && length(it$transform)) {
      norm <- eeg_normalize_id(ids, it$transform)
      ov <- length(intersect(unique(norm), as.character(redcap_ids)))
      note("eeg", "id_pattern", if (ov == dplyr::n_distinct(norm)) "derived" else "ask",
           paste0(ov, " of ", dplyr::n_distinct(norm), " EEG ids found in REDCap after the transform"))
    }
  }

  # Sessions -> timepoints
  if (!is.null(long) && "session" %in% names(long)) {
    labels <- sort(unique(stats::na.omit(long$session)))
    sched <- if (!is.null(config$timepoints$schedule)) tryCatch(timepoint_schedule(config), error = function(e) NULL) else NULL
    smap <- list()
    if (!is.null(sched)) {
      expects <- sched$timepoint[purrr::map_lgl(sched$modalities, ~ "eeg" %in% .x)]
      cand <- if (length(expects)) expects else sched$timepoint
      for (l in labels) {
        sl <- slug(l); hit <- NA_character_; how <- NA_character_
        if (sl %in% sched$timepoint) { hit <- sl; how <- "exact key" }
        else if (sl %in% slug(sched$label)) { hit <- sched$timepoint[slug(sched$label) == sl][1]; how <- "exact label" }
        else {
          n <- suppressWarnings(as.integer(sub("^.*?([0-9]+).*$", "\\1", l)))
          if (!is.na(n) && grepl("[0-9]", l) && n >= 1 && n <= length(cand)) { hit <- cand[n]; how <- paste0("position ", n, " among timepoints", if (length(expects)) " expecting eeg" else "") }
        }
        if (!is.na(hit)) { smap[[l]] <- hit; note("eeg", paste0("session_map.", l), if (grepl("exact", how)) "derived" else "inferred", paste0(l, " -> ", hit, " (", how, ")")) }
        else note("eeg", paste0("session_map.", l), "ask", paste0("no timepoint matches '", l, "'; declared: ", paste(sched$timepoint, collapse = ", ")))
      }
    } else {
      for (l in labels) { smap[[l]] <- l; note("eeg", paste0("session_map.", l), "ask", "no timepoints declared yet; map after the REDCap proposal") }
    }
    block$session_map <- smap
    if (!is.null(sched)) {
      expects <- sched$timepoint[purrr::map_lgl(sched$modalities, ~ "eeg" %in% .x)]
      if (!length(expects)) note("timepoints", "schedule.*.modalities", "ask", paste0("no timepoint lists eeg; the export has sessions ", paste(labels, collapse = ", ")))
    }
  }

  # Channels, features, QC
  if (!is.null(long)) {
    chans <- sort(unique(stats::na.omit(long$channel)))
    per <- long |> dplyr::distinct(.data$id, .data$session, .data$channel) |> dplyr::count(.data$channel, name = "n")
    n_units <- nrow(dplyr::distinct(long, .data$id, .data$session))
    req <- per$channel[per$n == n_units]
    block$qc <- list()
    if (length(req)) { block$qc$required_channels <- as.list(req); note("eeg", "qc.required_channels", "derived", paste0(length(req), " of ", length(chans), " channels present for every participant-session")) }
    if (length(project$vhdr)) {
      hdr_ch <- unique(unlist(lapply(project$vhdr, function(h) h$channels$name)))
      missing_in_export <- setdiff(hdr_ch, chans)
      if (length(missing_in_export)) note("eeg", "channels", "derived", paste0(length(missing_in_export), " recorded channel(s) absent from the export (expected after ROI averaging): ", paste(utils::head(missing_in_export, 8), collapse = ", ")))
    }
    conds <- if ("condition" %in% names(long)) sort(unique(stats::na.omit(long$condition))) else character(0)
    meas <- sort(unique(stats::na.omit(long$measure)))
    feats <- list()
    combos <- long |> dplyr::distinct(.data$measure, .data$condition)
    if (!"condition" %in% names(combos)) combos$condition <- NA_character_
    for (i in seq_len(nrow(combos))) {
      m <- combos$measure[i]; cnd <- combos$condition[i]
      ch_here <- sort(unique(long$channel[long$measure == m & (is.na(cnd) | long$condition %in% cnd)]))
      nm <- slug(paste(m, if (is.na(cnd)) "" else cnd))
      f <- list(name = nm, measure = m, channels = as.list(ch_here))
      if (!is.na(cnd)) f$condition <- cnd
      feats[[length(feats) + 1]] <- f
    }
    block$features <- feats
    note("eeg", "features", "inferred", paste0(length(feats), " candidate(s), one per measure x condition (", paste(meas, collapse = ", "), " x ",
                                               if (length(conds)) paste(conds, collapse = ", ") else "no condition column", "). Keep the ones the plan names, rename, and set window_ms and the channels to average"))
    note("eeg", "features.*.window_ms", "ask", "the export does not carry the measurement window; from the preprocessing script")
    v <- long$value_num[!is.na(long$value_num)]
    if (length(v) >= 20) {
      q <- stats::quantile(v, c(0.005, 0.995)); rng <- round_out(q[1], q[2], 10)
      if (rng[1] == rng[2]) rng <- rng + c(-10, 10)
      block$qc$amplitude_range_uv <- as_whole(rng)
      note("eeg", "qc.amplitude_range_uv", "default", paste0("[", rng[1], ", ", rng[2], "] from the 0.5 and 99.5 percentiles (", round(q[1], 2), ", ", round(q[2], 2), ") rounded outward; unit as exported"))
    } else note("eeg", "qc.amplitude_range_uv", "ask", "too few values to propose a range")
    nt <- long$n_trials_num[!is.na(long$n_trials_num)]
    if (!length(nt) && !is.null(project$trial_counts)) nt <- project$trial_counts$n_trials[!is.na(project$trial_counts$n_trials)]
    if (length(nt) >= 5) {
      floor5 <- max(1L, as.integer(floor(stats::quantile(nt, 0.05))))
      block$qc$min_trials <- floor5
      note("eeg", "qc.min_trials", "default", paste0(floor5, " = 5th percentile of trial counts (median ", stats::median(nt), ", min ", min(nt), ")"))
    } else {
      block$qc$min_trials <- 6L
      note("eeg", "qc.min_trials", "ask", "no trial counts in the export or a trial-count file; 6 written as a placeholder")
    }
  }

  # Conditions from markers, bins, events
  cond_sources <- list()
  if (length(project$vmrk)) {
    ms <- dplyr::bind_rows(lapply(project$vmrk, brainvision_marker_summary)) |> dplyr::summarise(n = sum(.data$n), .by = c("type", "description"))
    cond_sources$markers <- ms
    note("eeg", "recording.markers", "derived", paste0(nrow(ms), " marker code(s) across ", length(project$vmrk), " .vmrk file(s): ",
                                                       paste(utils::head(paste0(ms$type, " ", ms$description, " (", ms$n, ")"), 6), collapse = ", ")))
  }
  if (!is.null(project$bins)) { cond_sources$bins <- project$bins; note("eeg", "features.*.condition", "derived", paste0("ERPLAB bins: ", paste(paste0(project$bins$bin, "=", project$bins$label), collapse = "; "))) }
  if (length(project$events)) { ec <- dplyr::bind_rows(lapply(project$events, bids_event_counts)) |> dplyr::summarise(n = sum(.data$n), .by = "condition"); cond_sources$events <- ec
    note("eeg", "features.*.condition", "derived", paste0("BIDS events trial_type: ", paste(paste0(ec$condition, " (", ec$n, ")"), collapse = ", "))) }

  # Recording block: one source of truth, in the config
  rec <- list()
  if (length(project$vhdr)) {
    h <- project$vhdr[[1]]
    srs <- unique(stats::na.omit(vapply(project$vhdr, function(x) x$sampling_rate_hz, numeric(1))))
    rec$sampling_rate_hz <- as_whole(srs[1]); rec$n_channels <- h$n_channels; rec$reference <- h$reference; rec$unit <- h$unit
    rec$hardware_filters <- list(low_cutoff_s = as_whole(h$hardware_filters$low_cutoff_s), high_cutoff_hz = as_whole(h$hardware_filters$high_cutoff_hz), notch_hz = h$hardware_filters$notch_hz); rec$amplifier <- h$amplifier; rec$software <- h$software
    rec$channels <- as.list(h$channels$name)
    rec$source <- paste0("BrainVision header ", h$file, if (length(project$vhdr) > 1) paste0(" (+", length(project$vhdr) - 1, " more)") else "")
    if (length(srs) > 1) note("eeg", "recording.sampling_rate_hz", "ask", paste0("headers disagree: ", paste(srs, collapse = ", "), " Hz"))
    else note("eeg", "recording", "derived", paste0(rec$sampling_rate_hz, " Hz, ", rec$n_channels, " channels, reference ", rec$reference, ", filters ", h$hardware_filters$low_cutoff_s, " s / ", h$hardware_filters$high_cutoff_hz, " Hz / notch ", h$hardware_filters$notch_hz, if (!is.na(h$amplifier)) paste0(", ", h$amplifier) else ""))
    if (is.na(h$amplifier)) note("eeg", "recording.amplifier", "ask", "not found in the header comment")
  }
  if (length(project$eeg_json)) {
    j <- project$eeg_json[[1]]
    pick <- function(k) if (!is.null(j[[k]])) j[[k]] else NULL
    js <- list(sampling_rate_hz = pick("SamplingFrequency"), reference = pick("EEGReference"), powerline_hz = pick("PowerLineFrequency"),
               software_filters = pick("SoftwareFilters"), hardware_filters_bids = pick("HardwareFilters"),
               n_channels = pick("EEGChannelCount"), cap = paste(c(pick("CapManufacturer"), pick("CapManufacturersModelName")), collapse = " "),
               manufacturer = paste(c(pick("Manufacturer"), pick("ManufacturersModelName")), collapse = " "),
               placement_scheme = pick("EEGPlacementScheme"), ground = pick("EEGGround"), task = pick("TaskName"),
               software_versions = pick("SoftwareVersions"), source_bids = j$file)
    js <- Filter(function(x) !is.null(x) && !(is.character(x) && !nzchar(trimws(x))), js)
    if (!is.null(rec$sampling_rate_hz) && !is.null(js$sampling_rate_hz) && !isTRUE(all.equal(as.numeric(rec$sampling_rate_hz), as.numeric(js$sampling_rate_hz)))) {
      note("eeg", "recording.sampling_rate_hz", "ask", paste0("BrainVision header says ", rec$sampling_rate_hz, " Hz, *_eeg.json says ", js$sampling_rate_hz))
    }
    for (k in names(js)) if (is.null(rec[[k]])) rec[[k]] <- js[[k]]
    note("eeg", "recording (BIDS)", "derived", paste0("from ", j$file, ": ", paste(setdiff(names(js), "source_bids"), collapse = ", ")))
  }
  if (length(rec)) block$recording <- rec else note("eeg", "recording", "ask", "no .vhdr or *_eeg.json; sampling rate, reference and filters for the methods section are not recorded")

  list(config = list(eeg = block),
       todo = dplyr::bind_rows(todo) |> dplyr::mutate(status = factor(.data$status, levels = c("derived", "inferred", "default", "ask"))),
       long = long, conditions = cond_sources, source = project$source, read_at = project$read_at)
}

eeg_config_report <- function(proposal) {
  b <- proposal$config$eeg
  log_section("Proposed eeg block")
  cat("• Columns: ", paste(names(b$columns), unlist(b$columns), sep = " <- ", collapse = ", "), "\n", sep = "")
  cat("• Sessions: ", if (length(b$session_map)) paste(names(b$session_map), unlist(b$session_map), sep = " -> ", collapse = ", ") else "none", "\n", sep = "")
  cat("• Features: ", length(b$features), "   QC: ", paste(names(b$qc), collapse = ", "), "\n", sep = "")
  if (!is.null(b$recording)) cat("• Recording: ", b$recording$sampling_rate_hz %||% "?", " Hz, ", b$recording$n_channels %||% "?", " ch, ref ", b$recording$reference %||% "?", "\n", sep = "")
  n <- table(proposal$todo$status); cat("• Todo: ", paste(names(n), n, sep = " ", collapse = ", "), "\n", sep = "")
  ask <- proposal$todo[proposal$todo$status == "ask", ]
  if (nrow(ask)) { cat("\nTo confirm with the study team:\n"); for (i in seq_len(nrow(ask))) cat("  ", ask$section[i], ".", ask$key[i], ": ", ask$note[i], "\n", sep = "") }
  invisible(proposal$todo)
}
