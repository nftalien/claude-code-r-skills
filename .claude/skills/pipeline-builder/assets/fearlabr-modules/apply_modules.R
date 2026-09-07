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
copy_into <- function(src_glob, dst_dir) {
  files <- Sys.glob(file.path(here_dir, src_glob))
  dir.create(dst_dir, recursive = TRUE, showWarnings = FALSE)
  for (f in files) file.copy(f, file.path(dst_dir, basename(f)), overwrite = TRUE)
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
