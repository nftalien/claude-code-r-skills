#!/usr/bin/env Rscript
# ════════════════════════════════════════════════════════════════════════
# preflight_stage.R — check a generated stage before anyone renders it
# ════════════════════════════════════════════════════════════════════════
#   Rscript scripts/preflight_stage.R 04_prepare_ema
#   R console: source("scripts/preflight_stage.R"); preflight_stage("04_prepare_ema")
#
# Every check here exists because the failure it catches has cost a real
# render, and each of those failures is expensive in a different way:
# a parse error or a missing config key wastes a round trip with the person
# running the stage, while a discarded kable() or a swallowed diagnostic
# SUCCEEDS and quietly omits the thing the verification gate asks to look at.
#
# This is a static check. It reads the .qmd and _config.yml and runs none of
# the stage's code, so it needs no data and can run in any checkout.
# ════════════════════════════════════════════════════════════════════════

preflight_stage <- function(stage, notebook_dir = "notebooks", config = "_config.yml") {

qmd <- if (file.exists(stage)) stage else file.path(notebook_dir, paste0(stage, ".qmd"))
if (!file.exists(qmd)) stop(qmd, " not found. Stages live in ", notebook_dir, "/.")
lines <- readLines(qmd, warn = FALSE, encoding = "UTF-8")

# ── collect the chunks ────────────────────────────────────────────────
starts <- grep("^```[{]r", lines)
ends   <- grep("^```[[:space:]]*$", lines)
chunks <- list()
for (s in starts) {
  e <- ends[ends > s][1]
  if (is.na(e)) next
  body  <- lines[(s + 1):(e - 1)]
  label <- sub(".*label:[[:space:]]*", "",
               grep("^#[|][[:space:]]*label:", body, value = TRUE)[1])
  chunks[[length(chunks) + 1]] <- list(
    label = if (is.na(label)) paste0("(unlabelled, line ", s, ")") else label,
    code  = body[!grepl("^#[|]", body)],
    line  = s)
}
all_code <- unlist(lapply(chunks, `[[`, "code"))
fails <- character()
note  <- function(...) fails <<- c(fails, paste0(...))

# `x[, 1]` parses with an EMPTY argument. Touching one raises "argument is
# missing", and binding one to a variable makes every later reference to that
# variable raise it too -- so the tree walks below reach through lists by
# index and never bind.
empty_arg <- function(x) identical(x, quote(expr = ))

# ── 1. every chunk parses ─────────────────────────────────────────────
cat("1. parse\n")
bad <- 0L
for (ch in chunks) {
  out <- tryCatch({ parse(text = paste(ch$code, collapse = "\n")); "ok" },
                  error = function(e) conditionMessage(e))
  if (!identical(out, "ok")) {
    bad <- bad + 1L
    cat("   FAIL [", ch$label, "] line ", ch$line, ": ", out, "\n", sep = "")
  }
}
cat("   ", length(chunks), " chunks, ", bad, " parse failure(s)\n", sep = "")
if (bad) note(bad, " chunk(s) do not parse")

# ── 2. every config key the stage reads exists ────────────────────────
# A missing key is NULL, and NULL * 100 is numeric(0): a threshold silently
# becomes empty and every comparison against it returns logical(0), which
# surfaces much later as a recycling error naming an innocent variable.
cat("\n2. config keys\n")
cfg <- yaml::read_yaml(config)
# The lookbehind matters: without it `att_cfg$n_sessions` matches as
# `cfg$n_sessions` and gets reported as a missing key that was never read.
pat <- "(?<![A-Za-z0-9._])(?:config|cfg)\\$[A-Za-z_]+(?:\\$[A-Za-z_0-9]+)*"
keys <- unique(unlist(regmatches(all_code, gregexpr(pat, all_code, perl = TRUE))))
missing <- character()
for (k in sort(keys)) {
  parts <- strsplit(sub("^(config|cfg)\\$", "", k), "$", fixed = TRUE)[[1]]
  v <- cfg; ok <- TRUE
  for (p in parts) if (is.list(v) && p %in% names(v)) v <- v[[p]] else { ok <- FALSE; break }
  if (!ok) { missing <- c(missing, k); cat("   *** MISSING *** ", k, "\n", sep = "") }
}
cat("   ", length(keys), " key(s) read, ", length(missing), " missing\n", sep = "")
if (length(missing)) note(length(missing), " config key(s) the stage reads do not exist: ",
                          paste(missing, collapse = ", "))

# ── 3. no kable() whose value is thrown away ──────────────────────────
# knitr auto-prints the visible value of each TOP-LEVEL expression. A braced
# block's value is its LAST expression, so `if (nrow(x)) { kable(x); write_csv(x, f) }`
# writes the file and shows nothing. Walk the parse tree: a wrapped call spans
# several lines and is still one statement, so line shapes cannot decide this.
cat("\n3. discarded kable() calls\n")
has_kable <- function(e) {
  if (empty_arg(e)) return(FALSE)
  if (is.call(e)) {
    head1 <- deparse(e[[1]])[1]
    if (head1 %in% c("kable", "knitr::kable")) return(TRUE)
  }
  if (is.call(e) || is.pairlist(e)) {
    kids <- as.list(e)
    return(any(vapply(seq_along(kids), function(i) has_kable(kids[[i]]), logical(1))))
  }
  FALSE
}
discarded <- 0L
walk <- function(e, lab) {
  if (empty_arg(e) || !is.call(e)) return(invisible(NULL))
  if (identical(e[[1]], as.name("{"))) {
    stmts <- as.list(e)[-1]
    for (i in seq_along(stmts)) {
      if (i < length(stmts) && has_kable(stmts[[i]])) {
        discarded <<- discarded + 1L
        cat("   [", lab, "] value thrown away: ", deparse(stmts[[i]])[1], "\n", sep = "")
      }
    }
  }
  kids <- as.list(e)[-1]
  for (i in seq_along(kids)) if (!empty_arg(kids[[i]]) && is.call(kids[[i]])) walk(kids[[i]], lab)
  invisible(NULL)
}
for (ch in chunks) {
  exprs <- tryCatch(parse(text = paste(ch$code, collapse = "\n")), error = function(e) NULL)
  if (!is.null(exprs)) for (e in exprs) walk(e, ch$label)
}
cat("   ", discarded, " discarded\n", sep = "")
if (discarded) note(discarded, " kable() call(s) are not the last expression of their block, ",
                    "so the table will be missing from the render")

# ── 4. no print(kable()) ──────────────────────────────────────────────
# That prints the markdown SOURCE into the output block as verbatim text
# instead of rendering a table. Strip comments first: a note about it is not it.
cat("\n4. print(kable())\n")
pk <- grep("print\\((knitr::)?kable", sub("#.*$", "", all_code), value = TRUE)
for (x in pk) cat("   ", trimws(x), "\n", sep = "")
cat("   ", length(pk), " occurrence(s)\n", sep = "")
if (length(pk)) note(length(pk), " print(kable()) call(s) will emit verbatim markdown, not a table")

# ── 5. no diagnostic printed in a chunk that then stops ───────────────
# A chunk that calls stop() discards the WHOLE DOCUMENT, not just its own
# output: Quarto produces no HTML and the error string is the only text that
# reaches anyone. A gate that cat()s its evidence and then stops names the
# problem and shows none of it.
# Moving that evidence to an earlier chunk does NOT fix it -- that chunk's
# output dies with the document too. It has to go inside the stop() message,
# e.g. capture.output(print(as.data.frame(x))), so the table travels with the
# error.
cat("\n5. diagnostics swallowed by a stop() in the same chunk\n")
# Compare only statements that can run in the SAME pass. Source order is not
# execution order: `if (a) { cat(x) } else stop(y)` has a print above a stop
# and neither ever sees the other. So walk the tree, and at each braced block
# compare its statements pairwise -- the branches of an if/else are one
# statement at that level and get recursed into separately, never against
# each other.
is_stop  <- function(e) if (is.call(e)) identical(deparse(e[[1]])[1], "stop") else FALSE
contains <- function(e, test) {
  if (empty_arg(e)) return(FALSE)
  if (test(e)) return(TRUE)
  if (is.call(e) || is.pairlist(e)) {
    kids <- as.list(e)
    return(any(vapply(seq_along(kids), function(i) contains(kids[[i]], test), logical(1))))
  }
  FALSE
}
is_print <- function(e) if (is.call(e))
  deparse(e[[1]])[1] %in% c("cat", "print", "message", "kable", "knitr::kable") else FALSE

swallowed <- 0L
check_block <- function(e, lab) {
  if (empty_arg(e) || !is.call(e)) return(invisible(NULL))
  if (identical(e[[1]], as.name("{"))) {
    stmts <- as.list(e)[-1]
    prints <- vapply(seq_along(stmts), function(i) contains(stmts[[i]], is_print), logical(1))
    stops  <- vapply(seq_along(stmts), function(i) contains(stmts[[i]], is_stop),  logical(1))
    first_print <- if (any(prints)) min(which(prints)) else NA_integer_
    later_stop  <- if (!is.na(first_print) && any(stops & seq_along(stmts) > first_print))
      min(which(stops & seq_along(stmts) > first_print)) else NA_integer_
    if (!is.na(later_stop)) {
      swallowed <<- swallowed + 1L
      cat("   [", lab, "] prints at statement ", first_print, ", stops at ", later_stop,
          " -- the output before the stop never reaches the render\n", sep = "")
    }
  }
  kids <- as.list(e)[-1]
  for (i in seq_along(kids)) if (!empty_arg(kids[[i]]) && is.call(kids[[i]])) check_block(kids[[i]], lab)
  invisible(NULL)
}
for (ch in chunks) {
  exprs <- tryCatch(parse(text = paste(ch$code, collapse = "\n")), error = function(e) NULL)
  if (is.null(exprs)) next
  # The chunk body itself is a statement sequence, so wrap it as one block.
  check_block(as.call(c(list(as.name("{")), as.list(exprs))), ch$label)
}
cat("   ", swallowed, " chunk(s)\n", sep = "")
if (swallowed) note(swallowed, " chunk(s) print diagnostics and then stop(); ",
                    "put that evidence INSIDE the stop() message -- moving it to an earlier ",
                    "chunk does not help, the whole document is discarded either way")

# ── 6. libraries attached, not merely imported ────────────────────────
# fearlabr imports dplyr without attaching it, so a body using dplyr verbs or
# %>% dies at whichever chunk reaches them first.
cat("\n6. packages attached vs used\n")
# One line often attaches several: `library(dplyr); library(tidyr); ...`.
# A gsub() is greedy and keeps only the last, which reported every earlier
# package as unattached.
lib_hits <- regmatches(all_code, gregexpr("library\\([A-Za-z0-9.]+\\)", all_code))
libs <- unique(gsub("^library\\(|\\)$", "", unlist(lib_hits)))
need <- c(dplyr     = "\\b(mutate|filter|select|coalesce|bind_rows|count|arrange|group_by|summarise)\\(|%>%",
          tidyr     = "\\b(pivot_wider|pivot_longer)\\(",
          tibble    = "\\btibble\\(",
          readr     = "\\b(read_csv|write_csv)\\(",
          stringr   = "\\bstr_[a-z_]+\\(",
          purrr     = "\\b(map|map_[a-z]+|reduce|keep|pmap|walk)\\(",
          lubridate = "\\b(ymd_hms|dmy_hms|mdy_hms|with_tz|force_tz)\\(")
# A namespace-qualified call needs no attach, so `tibble::tibble()` must not
# count as a use of tibble. Strip every pkg::fun before scanning.
unqualified <- gsub("[A-Za-z0-9.]+::[A-Za-z0-9._]+", "", sub("#.*$", "", all_code))
unattached <- character()
for (p in names(need)) {
  used <- any(grepl(need[[p]], unqualified))
  if (used && !p %in% libs) {
    unattached <- c(unattached, p)
    cat("   *** used but not attached *** ", p, "\n", sep = "")
  }
}
cat("   attached: ", paste(libs, collapse = ", "), "\n", sep = "")
if (length(unattached)) note(length(unattached), " package(s) used but not attached: ",
                             paste(unattached, collapse = ", "))

# ── 7. every function called is defined somewhere ─────────────────────
# Catches a call to a helper that was renamed, or deleted along with the block
# it sat in, and catches plain typos. This one is worth the machinery: an
# undefined helper fails only when its chunk RUNS, so it surfaces as a render
# error two thirds of the way through rather than at parse time.
cat("\n7. functions called but never defined\n")
defined <- character()
collect_defs <- function(e) {
  if (empty_arg(e) || !is.call(e)) return(invisible(NULL))
  if (deparse(e[[1]])[1] %in% c("<-", "=", "<<-") && length(e) == 3 &&
      is.name(e[[2]]) && is.call(e[[3]]) && identical(e[[3]][[1]], as.name("function"))) {
    defined <<- c(defined, as.character(e[[2]]))
  }
  # A function's formal arguments can themselves be called inside its body
  # (`by_arm(d, f)` ... `f(d)`); they are defined for that body.
  if (identical(e[[1]], as.name("function")) && length(e) >= 2 && !is.null(e[[2]])) {
    defined <<- c(defined, names(e[[2]]))
  }
  kids <- as.list(e)[-1]
  for (i in seq_along(kids)) if (!empty_arg(kids[[i]]) && is.call(kids[[i]])) collect_defs(kids[[i]])
  invisible(NULL)
}
called <- character()
collect_calls <- function(e) {
  if (empty_arg(e) || !is.call(e)) return(invisible(NULL))
  if (is.name(e[[1]])) called <<- c(called, as.character(e[[1]]))
  kids <- as.list(e)
  for (i in seq_along(kids)) if (!empty_arg(kids[[i]]) && is.call(kids[[i]])) collect_calls(kids[[i]])
  invisible(NULL)
}
for (ch in chunks) {
  exprs <- tryCatch(parse(text = paste(ch$code, collapse = "\n")), error = function(e) NULL)
  if (is.null(exprs)) next
  for (e in exprs) { collect_defs(e); collect_calls(e) }
}
# Project helpers: a stage that sources R/*.R (the fearlabr-pipeline
# `local_r` idiom) may call anything defined there. Collect those
# definitions from the project's R/ directory, found upward from the stage.
all_code <- paste(unlist(lapply(chunks, `[[`, "code")), collapse = "\n")
if (grepl("here::here\\(\"R\"\\)|source\\(", all_code)) {
  proj <- normalizePath(dirname(qmd))
  for (up in 1:3) { if (dir.exists(file.path(proj, "R"))) break; proj <- dirname(proj) }
  helper_files <- list.files(file.path(proj, "R"), pattern = "\\.R$", full.names = TRUE)
  for (hf in helper_files) {
    exprs <- tryCatch(parse(hf), error = function(e) NULL)
    if (!is.null(exprs)) for (e in exprs) collect_defs(e)
  }
  if (length(helper_files)) cat("   (", length(helper_files), " project helper file(s) under R/ counted as definitions)\n", sep = "")
}
# Operators, control flow and subsetting are calls too; only plain names can be
# the sort of helper this check is about.
called <- unique(called[grepl("^[A-Za-z.][A-Za-z0-9._]*$", called)])
called <- setdiff(called, c("if", "for", "while", "repeat", "function", "return", "break", "next"))

# Anything an attached package exports is defined. A package that will not load
# is not evidence of a missing function, so skip it and say so.
base_pkgs <- c("base", "stats", "utils", "methods", "graphics", "grDevices", "tools")
unloadable <- character()
exported <- character()
for (pk in unique(c(base_pkgs, libs))) {
  ok <- tryCatch({ loadNamespace(pk); TRUE }, error = function(e) FALSE)
  if (ok) exported <- c(exported, getNamespaceExports(pk)) else unloadable <- c(unloadable, pk)
}
undefined <- setdiff(called, c(defined, exported))
for (u in sort(undefined)) cat("   *** not defined anywhere *** ", u, "()\n", sep = "")
if (length(unloadable))
  cat("   (could not load ", paste(unloadable, collapse = ", "),
      ", so functions from it are not checked)\n", sep = "")
cat("   ", length(called), " function(s) called, ", length(defined),
    " defined in the stage, ", length(undefined), " unaccounted for\n", sep = "")
if (length(undefined)) note(length(undefined), " function(s) are called but defined nowhere: ",
                            paste(sort(undefined), collapse = ", "))

# ── 8. the render must be one self-contained file ─────────────────────
cat("\n8. embed-resources\n")
yaml_end <- grep("^---[[:space:]]*$", lines)
hdr <- if (length(yaml_end) >= 2) lines[yaml_end[1]:yaml_end[2]] else character()
if (any(grepl("embed-resources:[[:space:]]*true", hdr))) {
  cat("   present\n")
} else {
  cat("   *** absent ***\n")
  note("embed-resources: true is missing from the YAML, so the render will not be ",
       "one self-contained file that can be sent for review")
}

# ── verdict ───────────────────────────────────────────────────────────
cat("\n", strrep("-", 68), "\n", sep = "")
if (!length(fails)) {
  cat("✓ preflight clean: ", basename(qmd), " is ready to render\n", sep = "")
} else {
  cat("✗ ", length(fails), " problem(s) to fix before rendering:\n", sep = "")
  for (f in fails) cat("  - ", f, "\n", sep = "")
}
invisible(length(fails) == 0)
}

# Command-line shim. `--file=` is present only when R was started ON this
# script, so this is skipped whenever the file is source()d instead.
if (any(grepl("^--file=.*preflight_stage\\.R$", commandArgs()))) {
  .args <- commandArgs(trailingOnly = TRUE)
  if (length(.args) != 1) {
    stop("Usage: Rscript scripts/preflight_stage.R <stage id>, e.g. 04_prepare_ema\n",
         "  From the R console instead: ",
         "source(\"scripts/preflight_stage.R\"); preflight_stage(\"04_prepare_ema\")")
  }
  ok <- preflight_stage(.args[1])
  quit(status = if (isTRUE(ok)) 0L else 1L)
}
