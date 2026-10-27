# ════════════════════════════════════════════════════════════════════════
# R/sensor_project_config.R — Propose the sensors block from the exports
# ════════════════════════════════════════════════════════════════════════
# A sensor export is its own metadata: the vendor preamble (ActiGraph,
# GENEActiv) names the device, epoch length and sometimes the time zone;
# the table's shape says the grain; the column names say the metrics; the
# wear-time distribution says what a valid-day rule would keep. This
# module reads one or more exports per stream and proposes the stream's
# config, with every value marked derived, inferred, default or ask.
#
# Vendors handled:
#   ActiGraph  CSV with the "------------ Data File Created By ActiGraph"
#              preamble (serial, epoch period, start date/time, download)
#   GENEActiv  CSV whose header block is "key,value" lines under section
#              titles ("Device Identity", "Configuration Info", ...) until
#              "Recorded Data"
#   Fitbit, Garmin, Oura   plain tables, metrics by name
#   AWARE, Beiwe, mindLAMP plain tables with a device id and an epoch
#              timestamp (ms or s since 1970, UTC); tz stays an ask
# ════════════════════════════════════════════════════════════════════════

sensor_column_vocabulary <- function() list(
  id = c("study_id", "participant_id", "participant", "subject", "subject_id", "id", "pid", "subject_code", "user_id", "device_id", "serial", "serial_number", "patient_id"),
  date = c("date", "day", "night_of", "calendar_date", "sleep_date", "summary_date", "date_local"),
  timestamp = c("timestamp", "datetime", "date_time", "time", "start_time", "epoch_time", "utc_timestamp", "timestamp_utc", "time_utc", "start_timestamp", "ts", "time_stamp", "epoch", "epoch_start", "recorded_at"))

sensor_metric_vocabulary <- function() list(
  steps = c("steps", "step_count", "stepcount", "step", "nsteps", "total_steps"),
  wear_minutes = c("wear_minutes", "wear_min", "wear_time", "wear", "worn_minutes", "wear_time_min", "valid_wear", "wear_time_minutes", "minutes_worn"),
  sleep_minutes = c("sleep_minutes", "total_sleep_time", "tst", "minutes_asleep", "asleep", "total_sleep_time_min", "sleep_duration", "total_sleep"),
  efficiency = c("sleep_efficiency", "efficiency"),
  hr = c("heart_rate", "hr", "bpm", "heartrate", "resting_heart_rate", "hr_bpm", "heart_rate_bpm"),
  activity_counts = c("axis1", "counts", "vector_magnitude", "vm", "activity_counts", "activity", "vectormagnitude"),
  mvpa_minutes = c("mvpa", "mvpa_minutes", "moderate_vigorous", "mvpa_min"),
  sedentary_minutes = c("sedentary", "sedentary_minutes", "sedentary_min"),
  calories = c("calories", "kcal", "energy_expenditure", "active_calories"),
  distance = c("distance", "distance_km", "distance_m", "distance_km_total"),
  light = c("lux", "light", "light_exposure", "light_level"),
  accel_x = c("x", "accel_x", "acc_x", "double_values_0", "x_axis"),
  accel_y = c("y", "accel_y", "acc_y", "double_values_1", "y_axis"),
  accel_z = c("z", "accel_z", "acc_z", "double_values_2", "z_axis"))

sensor_aggregate_default <- function(metric) {
  if (metric %in% c("hr", "efficiency", "light", "accel_x", "accel_y", "accel_z")) "mean" else "sum"
}

#' Match export columns to canonical id/date/timestamp and metric names.
sensor_detect_columns <- function(names) {
  sn <- mw_snake(names); used <- character(0)
  pick <- function(vocab) {
    hit <- which(sn %in% vocab & !names %in% used)
    if (!length(hit)) hit <- which(vapply(sn, function(s) any(vapply(vocab, function(v) s == v || startsWith(s, paste0(v, "_")) || endsWith(s, paste0("_", v)), logical(1))), logical(1)) & !names %in% used)
    if (length(hit)) { used <<- c(used, names[hit[1]]); names[hit[1]] } else NULL
  }
  cols <- list()
  for (k in names(sensor_column_vocabulary())) { v <- pick(sensor_column_vocabulary()[[k]]); if (!is.null(v)) cols[[k]] <- v }
  metrics <- list()
  for (m in names(sensor_metric_vocabulary())) { v <- pick(sensor_metric_vocabulary()[[m]]); if (!is.null(v)) metrics[[m]] <- v }
  list(columns = cols, metrics = metrics, unmatched = setdiff(names, used))
}

# ── Preambles ──────────────────────────────────────────────────────────

#' Detect and parse a vendor preamble; return where the table starts.
sensor_read_preamble <- function(lines) {
  head <- lines[seq_len(min(80, length(lines)))]
  if (grepl("ActiGraph", head[1], ignore.case = TRUE)) {
    end <- grep("^-{5,}", head); end <- if (length(end) >= 2) end[2] else if (length(end)) end[1] else 1
    pre <- head[seq_len(end)]
    grab <- function(pat) { h <- grep(pat, pre, ignore.case = TRUE, value = TRUE); if (length(h)) trimws(sub(paste0(".*", pat, "\\s*:?\\s*"), "", h[1], ignore.case = TRUE)) else NA_character_ }
    epoch <- grab("Epoch Period \\(hh:mm:ss\\)")
    ep_s <- if (!is.na(epoch)) { p <- suppressWarnings(as.numeric(strsplit(epoch, ":")[[1]])); if (length(p) == 3 && !any(is.na(p))) p[1] * 3600 + p[2] * 60 + p[3] else NA_real_ } else NA_real_
    return(list(vendor = "ActiGraph", skip = end,
                info = list(serial = grab("Serial Number"), epoch_seconds = ep_s, start_time = grab("Start Time"), start_date = grab("Start Date"),
                            download_time = grab("Download Time"), download_date = grab("Download Date"), software = trimws(sub("^-+\\s*|\\s*-+$", "", head[1])), mode = grab("Mode"))))
  }
  if (any(grepl("^Device Identity|GENEActiv", head[1:3], ignore.case = TRUE))) {
    end <- grep("^Recorded Data", head, ignore.case = TRUE)
    end <- if (length(end)) end[1] else length(head)
    pre <- head[seq_len(end)]
    kv <- pre[grepl(",", pre, fixed = TRUE)]
    k <- trimws(sub(",.*$", "", kv)); v <- trimws(sub("^[^,]*,", "", kv))
    get <- function(pat) { i <- grep(pat, k, ignore.case = TRUE); if (length(i)) v[i[1]] else NA_character_ }
    freq <- suppressWarnings(as.numeric(gsub("[^0-9.]", "", get("Measurement Frequency"))))
    return(list(vendor = "GENEActiv", skip = end,
                info = list(serial = get("Serial Code|Serial Number"), measurement_frequency_hz = freq,
                            epoch_seconds = if (!is.na(freq) && freq > 0) 1 / freq else NA_real_,
                            start_time = get("^Start Time"), tz_offset = get("Time Zone"), subject_code = get("Subject Code"),
                            device_type = get("Device Type"), firmware = get("Firmware"))))
  }
  list(vendor = "plain", skip = 0L, info = list())
}

#' Read one export: preamble (if any) and the table as character.
sensor_read_export <- function(path) {
  stopifnot(file.exists(path))
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8", n = 200)
  pre <- sensor_read_preamble(lines)
  skip <- pre$skip
  # Some exports put a blank line between the preamble and the header row.
  all_lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  while (skip < length(all_lines) && !nzchar(trimws(all_lines[skip + 1]))) skip <- skip + 1
  first <- all_lines[skip + 1]
  fields <- strsplit(first, ",", fixed = TRUE)[[1]]
  header_present <- !all(grepl("^\\s*-?[0-9.]+\\s*$|^\\s*$|^[0-9/: -]+$", fields))
  df <- readr::read_csv(I(paste(all_lines[(skip + 1):length(all_lines)], collapse = "\n")),
                        col_names = header_present, col_types = readr::cols(.default = readr::col_character()),
                        show_col_types = FALSE, name_repair = "minimal")
  if (!header_present) names(df) <- paste0("V", seq_len(ncol(df)))
  attr(df, "preamble") <- pre; attr(df, "header_present") <- header_present; attr(df, "source_file") <- basename(path)
  df
}

# ── Grain ──────────────────────────────────────────────────────────────

parse_sensor_time <- function(x, tz = "UTC") {
  num <- suppressWarnings(as.numeric(x))
  if (mean(!is.na(num)) > 0.9) {
    secs <- ifelse(num > 1e11, num / 1000, num)   # ms epoch vs s epoch
    return(as.POSIXct(secs, origin = "1970-01-01", tz = tz))
  }
  lubridate::parse_date_time(x, orders = c("Ymd HMS", "Ymd HM", "mdY HMS", "mdY HM", "dmY HMS", "Ymd", "mdY", "dmY"), tz = tz, quiet = TRUE)
}

#' Day or epoch, with the epoch length when epoch.
sensor_detect_grain <- function(df, cols) {
  if (is.null(cols$timestamp)) return(list(grain = "day", epoch_seconds = NA_real_, rows_per_id_day = 1))
  ts <- parse_sensor_time(df[[cols$timestamp]])
  d <- as.Date(format(ts, "%Y-%m-%d"))
  id <- if (!is.null(cols$id)) df[[cols$id]] else "one"
  per <- tibble::tibble(id = id, d = d) |> dplyr::count(.data$id, .data$d)
  rpd <- stats::median(per$n)
  if (rpd <= 1) return(list(grain = "day", epoch_seconds = NA_real_, rows_per_id_day = rpd))
  gaps <- unlist(lapply(split(ts, id), function(t) { t <- sort(t[!is.na(t)]); if (length(t) > 1) as.numeric(diff(t), units = "secs") else NULL }))
  list(grain = "epoch", epoch_seconds = if (length(gaps)) stats::median(gaps) else NA_real_, rows_per_id_day = rpd)
}

# ── Read and derive ────────────────────────────────────────────────────

#' Gather sensor exports per stream.
#'
#' @param config Config list (sensors.streams globs and paths.raw_data), optional.
#' @param files Named list stream key -> path(s) or glob(s). When NULL the
#'   configured globs are used; when neither, every CSV under raw/sensor is
#'   read and grouped into one stream per distinct column set.
sensor_project_read <- function(config = NULL, files = NULL, raw_dir = NULL) {
  groups <- list()
  if (!is.null(files)) {
    for (k in names(files)) groups[[k]] <- expand_paths(files[[k]])
  } else if (!is.null(config$sensors$streams)) {
    for (k in names(config$sensors$streams)) groups[[k]] <- builder_glob_files(config, config$sensors$streams[[k]]$file_glob)
  } else {
    dir <- raw_dir %||% file.path(resolve_path(config$paths$raw_data %||% "data/raw", config), "sensor")
    fs <- list.files(dir, pattern = "\\.csv$", full.names = TRUE, ignore.case = TRUE)
    if (length(fs)) {
      sig <- vapply(fs, function(f) paste(names(sensor_read_export(f)), collapse = "|"), character(1))
      for (s in unique(sig)) {
        fs_s <- fs[sig == s]
        key <- slug(sub("\\.csv$", "", sub("^[^_]+_", "", basename(fs_s[1]))))
        groups[[if (nzchar(key)) key else paste0("stream_", length(groups) + 1)]] <- fs_s
      }
    }
  }
  groups <- Filter(length, groups)
  if (!length(groups)) stop("[sensor_project_read] no sensor export found; pass files = list(<stream> = <path or glob>).", call. = FALSE)
  streams <- list()
  for (k in names(groups)) {
    reads <- lapply(groups[[k]], sensor_read_export)
    vend <- unique(vapply(reads, function(r) attr(r, "preamble")$vendor, character(1)))
    cat("• ", k, ": ", length(reads), " file(s), vendor ", paste(vend, collapse = "/"), ", ", sum(vapply(reads, nrow, integer(1))), " rows\n", sep = "")
    streams[[k]] <- list(files = groups[[k]], reads = reads)
  }
  list(source = "files", streams = streams, read_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"))
}

#' Propose the sensors block.
sensor_project_to_config <- function(project, config = NULL, id_pattern = NULL, wear_rule_minutes = 600) {
  todo <- list()
  note <- function(section, key, status, text) todo[[length(todo) + 1]] <<- tibble::tibble(section = section, key = key, status = status, note = text)
  tz <- config$sensors$tz
  streams <- list(); detail <- list()
  for (k in names(project$streams)) {
    st <- project$streams[[k]]; reads <- st$reads
    df <- dplyr::bind_rows(lapply(reads, function(r) { r <- tibble::as_tibble(r); r$source_file <- attr(r, "source_file"); r }))
    pre <- attr(reads[[1]], "preamble")
    det <- sensor_detect_columns(setdiff(names(df), "source_file"))
    sk <- paste0("streams.", k)
    spec <- list(label = paste(pre$vendor, if (!is.null(det$metrics)) paste(names(det$metrics)[1:min(3, length(det$metrics))], collapse = "/")))
    # glob
    fn <- basename(st$files)
    spec$file_glob <- paste0("sensor/", if (length(fn) == 1) sub("^[^_]+_", "*_", fn) else paste0("*", Reduce(function(a, b) { i <- 0; while (i < min(nchar(a), nchar(b)) && substr(a, nchar(a) - i, nchar(a) - i) == substr(b, nchar(b) - i, nchar(b) - i)) i <- i + 1; substr(a, nchar(a) - i + 1, nchar(a)) }, fn)))
    note("sensors", paste0(sk, ".file_glob"), "inferred", paste0("from ", length(fn), " file name(s): ", spec$file_glob))
    if (!isTRUE(attr(reads[[1]], "header_present"))) note("sensors", paste0(sk, ".columns"), "ask", "no header row after the preamble; columns are V1..Vn. Re-export with column names")
    # columns and grain
    cols <- det$columns
    if (is.null(cols$id)) {
      if (!is.na(pre$info$serial %||% NA) || !is.na(pre$info$subject_code %||% NA)) {
        note("sensors", paste0(sk, ".columns.id"), "ask", paste0("no id column; the preamble carries ", if (!is.na(pre$info$subject_code %||% NA)) paste0("subject code ", pre$info$subject_code) else paste0("device serial ", pre$info$serial), ". One file per participant: the id will be taken from the file name or a device roster"))
      } else note("sensors", paste0(sk, ".columns.id"), "ask", paste0("no column looks like a participant id; candidates: ", paste(det$unmatched, collapse = ", ")))
    }
    grain <- sensor_detect_grain(df, cols)
    spec$grain <- grain$grain
    spec$columns <- list(id = cols$id %||% "TODO")
    if (grain$grain == "day") {
      spec$columns$date <- cols$date %||% cols$timestamp %||% "TODO"
      if (is.null(cols$date) && is.null(cols$timestamp)) note("sensors", paste0(sk, ".columns.date"), "ask", "no date column found")
    } else {
      spec$columns$timestamp <- cols$timestamp
      ep <- if (!is.na(pre$info$epoch_seconds %||% NA)) pre$info$epoch_seconds else grain$epoch_seconds
      spec$epoch_seconds <- as_whole(round(ep, 3))
      note("sensors", paste0(sk, ".grain"), "derived", paste0("epoch: median ", grain$rows_per_id_day, " rows per participant-day; epoch ", round(ep, 1), " s", if (!is.na(pre$info$epoch_seconds %||% NA)) " from the preamble" else " from the timestamp gaps"))
    }
    if (grain$grain == "day") note("sensors", paste0(sk, ".grain"), "derived", "day: one row per participant-day")
    # metrics
    if (!length(det$metrics)) note("sensors", paste0(sk, ".metrics"), "ask", paste0("no column matched a known metric; columns: ", paste(det$unmatched, collapse = ", ")))
    spec$metrics <- det$metrics
    for (m in names(det$metrics)) note("sensors", paste0(sk, ".metrics.", m), "inferred", paste0("<- ", det$metrics[[m]]))
    if (length(det$unmatched)) note("sensors", paste0(sk, ".metrics.unmatched"), "derived", paste0("columns not mapped: ", paste(utils::head(det$unmatched, 10), collapse = ", ")))
    if (grain$grain == "epoch" && length(det$metrics)) {
      spec$aggregate <- stats::setNames(lapply(names(det$metrics), sensor_aggregate_default), names(det$metrics))
      note("sensors", paste0(sk, ".aggregate"), "default", paste(paste0(names(spec$aggregate), "=", unlist(spec$aggregate)), collapse = ", "))
    }
    # valid-day rule
    if ("wear_minutes" %in% names(det$metrics)) {
      w <- suppressWarnings(as.numeric(df[[det$metrics$wear_minutes]])); w <- w[!is.na(w)]
      if (grain$grain == "epoch" && length(w)) {
        # per-day sums for the distribution
        ts <- parse_sensor_time(df[[cols$timestamp]]); dd <- as.Date(format(ts, "%Y-%m-%d"))
        w <- tibble::tibble(id = df[[cols$id %||% names(df)[1]]], d = dd, w = suppressWarnings(as.numeric(df[[det$metrics$wear_minutes]]))) |>
          dplyr::summarise(w = sum(.data$w, na.rm = TRUE), .by = c("id", "d")) |> dplyr::pull("w")
      }
      spec$valid_day_rule <- paste0("wear_minutes >= ", wear_rule_minutes)
      note("sensors", paste0(sk, ".valid_day_rule"), "default", paste0(spec$valid_day_rule, ": keeps ", round(100 * mean(w >= wear_rule_minutes), 1), "% of ", length(w), " participant-days (median wear ", stats::median(w), ")"))
    } else if ("sleep_minutes" %in% names(det$metrics)) {
      spec$valid_day_rule <- "sleep_minutes > 0"
      note("sensors", paste0(sk, ".valid_day_rule"), "default", "sleep_minutes > 0")
    } else {
      spec$valid_day_rule <- "TODO"
      note("sensors", paste0(sk, ".valid_day_rule"), "ask", "no wear or sleep metric to base a rule on; state the protocol's")
    }
    # ids
    if (!is.null(cols$id)) {
      it <- infer_id_transform(df[[cols$id]])
      if (length(it$transform)) { spec$id_transform <- it$transform; spec$id_pattern <- id_pattern %||% it$pattern; note("sensors", paste0(sk, ".id_transform"), "inferred", it$note) }
      else note("sensors", paste0(sk, ".id_transform"), "ask", paste0(it$note, "; if these are device serials, a device roster (serial -> participant) is needed"))
    }
    # device
    if (pre$vendor != "plain") {
      dev <- Filter(function(x) !is.null(x) && !(length(x) == 1 && is.na(x)), pre$info)
      serials <- unique(unlist(lapply(reads, function(r) attr(r, "preamble")$info$serial)))
      dev$serials <- as.list(serials[!is.na(serials)]); dev$vendor <- pre$vendor
      spec$device <- dev
      note("sensors", paste0(sk, ".device"), "derived", paste0(pre$vendor, " preamble: ", paste(setdiff(names(dev), "serials"), collapse = ", "), if (length(dev$serials)) paste0("; ", length(dev$serials), " serial(s)") else ""))
      if (!is.null(pre$info$tz_offset) && !is.na(pre$info$tz_offset) && is.null(tz)) note("sensors", "tz", "ask", paste0("GENEActiv header gives offset '", pre$info$tz_offset, "'; pick the named zone (e.g. America/New_York) that matches"))
    }
    streams[[k]] <- spec
    detail[[k]] <- tibble::tibble(stream = k, vendor = pre$vendor, n_files = length(reads), n_rows = nrow(df), grain = grain$grain,
                                  id = cols$id %||% NA_character_, metrics = paste(names(det$metrics), collapse = ","))
  }
  block <- list(enabled = TRUE, tz = tz %||% "TODO", streams = streams)
  if (is.null(tz)) note("sensors", "tz", "ask", "local time zone for epoch timestamps (phone apps export UTC); a wrong zone moves evening epochs to the next day")
  list(config = list(sensors = block),
       todo = dplyr::bind_rows(todo) |> dplyr::mutate(status = factor(.data$status, levels = c("derived", "inferred", "default", "ask"))),
       streams = dplyr::bind_rows(detail), source = project$source, read_at = project$read_at)
}

sensor_config_report <- function(proposal) {
  log_section("Proposed sensors block")
  print(proposal$streams)
  n <- table(proposal$todo$status); cat("• Todo: ", paste(names(n), n, sep = " ", collapse = ", "), "\n", sep = "")
  ask <- proposal$todo[proposal$todo$status == "ask", ]
  if (nrow(ask)) { cat("\nTo confirm with the study team:\n"); for (i in seq_len(nrow(ask))) cat("  ", ask$section[i], ".", ask$key[i], ": ", ask$note[i], "\n", sep = "") }
  invisible(proposal$todo)
}
