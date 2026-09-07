#!/usr/bin/env Rscript
# ════════════════════════════════════════════════════════════════════════
# apply_modules.R — add the pipeline-builder modules to a fearlabr source tree
# ════════════════════════════════════════════════════════════════════════
# Usage (terminal, not the R console):
#   Rscript apply_modules.R /path/to/fearlabr-package
#
# Copies R/*.R and tests/testthat/* from this directory into the package,
# appends NAMESPACE.additions to NAMESPACE (no duplicates), bumps the
# DESCRIPTION Version to 0.2.0 when it is lower, and prepends NEWS-0.2.0.md
# to NEWS.md. Idempotent: running it twice changes nothing the second time.
# Then, from the package directory:
#   R CMD build .  &&  R CMD INSTALL fearlabr_0.2.0.tar.gz
# or devtools::test() / devtools::check() before tagging.
# ════════════════════════════════════════════════════════════════════════

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1 || !dir.exists(args[1])) {
  stop("Usage: Rscript apply_modules.R /path/to/fearlabr-package")
}
pkg <- normalizePath(args[1])
here_dir <- normalizePath(dirname(sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1])))
if (is.na(here_dir) || !dir.exists(here_dir)) here_dir <- getwd()

stopifnot(file.exists(file.path(pkg, "DESCRIPTION")), file.exists(file.path(pkg, "NAMESPACE")))
desc <- readLines(file.path(pkg, "DESCRIPTION"))
if (!any(grepl("^Package: fearlabr$", desc))) stop(pkg, " is not the fearlabr package.")

# 1. R files and tests
# Copies overwrite. A module file that shadows a file fearlabr already ships
# replaces it wholesale -- which silently dropped three upstream tests once,
# so say which files are being replaced rather than leaving it to be noticed.
copy_into <- function(src_glob, dst_dir) {
  files <- Sys.glob(file.path(here_dir, src_glob))
  dir.create(dst_dir, recursive = TRUE, showWarnings = FALSE)
  shadowed <- character(0)
  for (f in files) {
    dst <- file.path(dst_dir, basename(f))
    if (file.exists(dst) &&
        !identical(readLines(dst, warn = FALSE), readLines(f, warn = FALSE))) {
      shadowed <- c(shadowed, basename(f))
    }
    file.copy(f, dst, overwrite = TRUE)
  }
  if (length(shadowed)) {
    cat("⚠️  replaced ", length(shadowed), " existing file(s) in ", dst_dir, ": ",
        paste(shadowed, collapse = ", "),
        "\n   The module copy must carry everything the fearlabr copy had.\n", sep = "")
  }
  length(files)
}
n_r <- copy_into("R/*.R", file.path(pkg, "R"))
n_t <- copy_into("tests/testthat/*.R", file.path(pkg, "tests", "testthat"))
cat("✓ Copied ", n_r, " R file(s) and ", n_t, " test file(s)\n", sep = "")

# 1b. Patch R/clean_redcap.R so `condition` is always created and never collides
#     with a study field of the same name. Anchor-based and idempotent: if the
#     upstream block has changed shape, stop rather than half-apply.
cr_path <- file.path(pkg, "R", "clean_redcap.R")
if (!file.exists(cr_path)) {
  cat("• clean_redcap.R not present — condition patch skipped\n")
} else {
  cr <- readLines(cr_path)
  if (any(grepl("condition_redcap_raw", cr, fixed = TRUE))) {
    cat("• clean_redcap.R already carries the condition patch\n")
  } else {
    start <- grep("^  # Map condition \\(only meaningful at randomization event\\)$", cr)
    stop_at <- grep("^  # Long, assessment-level", cr)
    if (length(start) != 1 || length(stop_at) != 1 || stop_at[1] <= start[1]) {
      stop("Cannot locate the condition block in R/clean_redcap.R. ",
           "fearlabr has changed upstream; re-cut patches/clean_redcap-condition.txt.")
    }
    old <- cr[start:(stop_at - 1L)]
    if (!any(grepl("randomization_field %in% names(scored)", old, fixed = TRUE)) ||
        !any(grepl("left_join(rand, by = id_col)", old, fixed = TRUE))) {
      stop("The condition block in R/clean_redcap.R is not the one this patch ",
           "was written against. Refusing to patch.")
    }
    new <- readLines(file.path(here_dir, "patches", "clean_redcap-condition.txt"))
    cr <- c(cr[seq_len(start - 1L)], new, "", cr[stop_at:length(cr)])
    writeLines(cr, cr_path)
    cat("✓ clean_redcap.R: condition block patched (", length(old),
        " lines -> ", length(new), ")\n", sep = "")
  }
}

# 1b2. Patch R/clean_redcap.R to honour each instrument's reverse_coded list.
cr2 <- readLines(cr_path)
if (any(grepl("rev_declared", cr2, fixed = TRUE))) {
  cat("• clean_redcap.R already reverses reverse_coded items\n")
} else {
  sig <- grep("^score_instrument <- function\\(df, instr_name, instr_cfg", cr2)
  if (length(sig) != 1) {
    stop("Cannot locate score_instrument() in R/clean_redcap.R; re-cut ",
         "patches/clean_redcap-reverse_coded.txt.")
  }
  hit <- which(cr2 == "  out <- df" & seq_along(cr2) > sig[1])
  if (!length(hit)) stop("Cannot locate the 'out <- df' anchor in score_instrument().")
  new <- readLines(file.path(here_dir, "patches", "clean_redcap-reverse_coded.txt"))
  cr2 <- c(cr2[seq_len(hit[1] - 1L)], new, cr2[(hit[1] + 1L):length(cr2)])
  writeLines(cr2, cr_path)
  cat("✓ clean_redcap.R: reverse_coded honoured\n")
}

# 1b3. Patch R/clean_redcap.R for mean scoring. Some instruments are scored as
#      the mean of their items rather than a sum (the Brief Aggression
#      Questionnaire is scored 1-7 by its author), and subscales hard-coded
#      "prorated_sum" so they could not follow their instrument.
cr3 <- readLines(cr_path)
if (any(grepl('method == "mean"', cr3, fixed = TRUE))) {
  cat("• clean_redcap.R already supports mean scoring\n")
} else {
  i <- grep('^  \\} else if \\(method == "raw_sum"\\) \\{$', cr3)
  j <- grep('^        method          = "prorated_sum"$', cr3)
  if (length(i) != 1 || length(j) != 1) {
    stop("Cannot locate the scoring-method blocks in R/clean_redcap.R; re-cut ",
         "the mean-scoring patch.")
  }
  cr3[j] <- '        method          = sub$score_method %||% instr_cfg$score_method %||% "prorated_sum"'
  cr3 <- append(cr3, c(
    '  } else if (method == "mean") {',
    '    # Mean of the available items. Proration is meaningless here: the mean',
    '    # of what was answered already is the score, on the item scale.',
    '    score[ok] <- rowMeans(M[ok, , drop = FALSE], na.rm = TRUE)'
  ), after = i - 1L)
  writeLines(cr3, cr_path)
  cat("✓ clean_redcap.R: mean scoring added; subscales follow their instrument\n")
}

# 1c. Patch R/structural_skips.R so a rule's trigger_op is honoured. Without it
#     the operator is decorative and every rule is applied as "==", which
#     inverts every rule derived from REDCap branching logic.
ss_path <- file.path(pkg, "R", "structural_skips.R")
if (!file.exists(ss_path)) {
  cat("• structural_skips.R not present — trigger_op patch skipped\n")
} else {
  ss <- readLines(ss_path)
  if (any(grepl("trig_op", ss, fixed = TRUE))) {
    cat("• structural_skips.R already honours trigger_op\n")
  } else {
    start <- grep("^    trig_val   <- rule\\$trigger_value", ss)
    stop_at <- grep('^        length\\(downstream\\), " downstream item\\(s\\)', ss)
    if (length(start) != 1 || length(stop_at) != 1 || stop_at[1] <= start[1]) {
      stop("Cannot locate the rule-application block in R/structural_skips.R. ",
           "fearlabr has changed upstream; re-cut patches/structural_skips-trigger_op.txt.")
    }
    old <- ss[start:stop_at]
    if (!any(grepl("out[[trig]] == trig_val", old, fixed = TRUE))) {
      stop("The rule-application block in R/structural_skips.R is not the one ",
           "this patch was written against. Refusing to patch.")
    }
    new <- readLines(file.path(here_dir, "patches", "structural_skips-trigger_op.txt"))
    ss <- c(ss[seq_len(start - 1L)], new, ss[(stop_at + 1L):length(ss)])
    writeLines(ss, ss_path)
    cat("✓ structural_skips.R: trigger_op honoured (", length(old),
        " lines -> ", length(new), ")\n", sep = "")
  }
}

# 2. NAMESPACE exports
ns <- readLines(file.path(pkg, "NAMESPACE"))
add <- readLines(file.path(here_dir, "NAMESPACE.additions"))
add <- add[grepl("^export\\(", add)]
new <- setdiff(add, ns)
if (length(new)) {
  # Keep exports together: insert before the first import() line if any.
  imp <- grep("^import", ns)
  ns <- if (length(imp)) append(ns, new, after = imp[1] - 1) else c(ns, new)
  writeLines(ns, file.path(pkg, "NAMESPACE"))
}
cat("✓ NAMESPACE: ", length(new), " new export(s)\n", sep = "")

# 3. Version
ver_line <- grep("^Version:", desc)
cur <- trimws(sub("^Version:", "", desc[ver_line]))
if (utils::compareVersion(cur, "0.2.0") < 0) {
  desc[ver_line] <- "Version: 0.2.0"
  writeLines(desc, file.path(pkg, "DESCRIPTION"))
  cat("✓ DESCRIPTION: ", cur, " -> 0.2.0\n", sep = "")
} else cat("• DESCRIPTION already at ", cur, "\n", sep = "")

# 4. NEWS
news_path <- file.path(pkg, "NEWS.md")
news_new <- readLines(file.path(here_dir, "NEWS-0.2.0.md"))
news_old <- if (file.exists(news_path)) readLines(news_path) else character(0)
if (!any(grepl("^# fearlabr 0.2.0", news_old))) {
  writeLines(c(news_new, "", news_old), news_path)
  cat("✓ NEWS.md: 0.2.0 entry added\n")
} else cat("• NEWS.md already has the 0.2.0 entry\n")

cat("\nNext (terminal): cd ", pkg, " && R CMD build . && R CMD INSTALL fearlabr_0.2.0.tar.gz\n", sep = "")
