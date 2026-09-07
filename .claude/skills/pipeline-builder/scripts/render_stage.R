#!/usr/bin/env Rscript
# ════════════════════════════════════════════════════════════════════════
# render_stage.R — render one pipeline stage and file its HTML
# ════════════════════════════════════════════════════════════════════════
#   Rscript scripts/render_stage.R 00_setup
#
# Why this exists instead of `quarto render <file> --output-dir output/renders`:
# --output-dir puts Quarto into project mode for a single file, which creates
# notebooks/.quarto and deletes it at the end. On Windows that delete fails
# whenever the editor's file monitor or the antivirus holds a handle in that
# tree ("os error 32 ... used by another process"), after the render has
# already succeeded. Rendering in place avoids project mode entirely; this
# script then moves the HTML to output/renders/<id>.html, which is where
# builder_record_render() records it and where 00b looks for it.
# ════════════════════════════════════════════════════════════════════════
# Two ways to call this, because both are natural and getting it wrong wastes
# a round trip:
#   terminal:  Rscript scripts/render_stage.R 03_clean_redcap
#   R console: source("scripts/render_stage.R"); render_stage("03_clean_redcap")
# The body is a function; the command-line shim at the bottom calls it.

render_stage <- function(stage) {

id <- sub("\\.qmd$", "", basename(stage))
qmd <- file.path("notebooks", paste0(id, ".qmd"))
if (!file.exists(qmd)) stop(qmd, " not found. Stages live in notebooks/.")

# The engine ships in pkg/ and is installed separately. A pull that brings a
# newer tarball leaves the notebook calling functions the installed build does
# not have, which fails deep inside a chunk with "could not find function".
# Cheaper to say so here.
tb <- file.path("pkg", "fearlabr_0.2.0.tar.gz")
if (file.exists(tb)) {
  desc <- system.file("DESCRIPTION", package = "fearlabr")
  if (!nzchar(desc)) {
    stop("fearlabr is not installed. Run:  Rscript scripts/install_deps.R")
  }
  if (file.mtime(tb) > file.mtime(desc)) {
    stop("pkg/fearlabr_0.2.0.tar.gz is newer than the installed fearlabr.\n",
         "  The notebooks may call functions this build does not have. Install it, then restart R:\n",
         "    install.packages(\"pkg/fearlabr_0.2.0.tar.gz\", repos = NULL, type = \"source\")")
  }
}

quarto <- Sys.which("quarto")
if (!nzchar(quarto)) {
  # RStudio ships its own copy; use it when quarto is not on the PATH.
  guesses <- c("C:/Program Files/RStudio/resources/app/bin/quarto/bin/quarto.exe",
               "/Applications/RStudio.app/Contents/Resources/app/bin/quarto/bin/quarto",
               "/usr/lib/rstudio/resources/app/bin/quarto/bin/quarto")
  hit <- guesses[file.exists(guesses)]
  if (!length(hit)) stop("quarto not found on the PATH. Install Quarto, or open a terminal from RStudio.")
  quarto <- hit[1]
}

cat("Rendering ", qmd, "\n", sep = "")
status <- system2(quarto, c("render", shQuote(qmd)))
html <- file.path("notebooks", paste0(id, ".html"))
if (status != 0 || !file.exists(html)) {
  stop("render failed for ", id, " (quarto exit ", status, "). Read the message above: the failing chunk is named.")
}

dest_dir <- "output/renders"
dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
dest <- file.path(dest_dir, paste0(id, ".html"))
if (!file.rename(html, dest)) {                 # rename fails across volumes
  file.copy(html, dest, overwrite = TRUE); file.remove(html)
}
# embed-resources makes one self-contained file; drop the sidecar if a stage
# is ever rendered without it.
side <- file.path("notebooks", paste0(id, "_files"))
if (dir.exists(side)) unlink(side, recursive = TRUE)

cat("\u2713 ", dest, " (", round(file.size(dest) / 1024), " KB)\n", sep = "")
cat("  Look at it, then approve in the R console: builder_approve(\"", id, "\")\n", sep = "")

invisible(dest)
}

# Command-line shim. `--file=` is present only when R was started ON this
# script, so this is skipped whenever the file is source()d instead --
# interactive session or not.
if (any(grepl("^--file=.*render_stage\\.R$", commandArgs()))) {
  .args <- commandArgs(trailingOnly = TRUE)
  if (length(.args) != 1) {
    stop("Usage: Rscript scripts/render_stage.R <stage id>, e.g. 00_setup\n",
         "  From the R console instead: ",
         "source(\"scripts/render_stage.R\"); render_stage(\"00_setup\")")
  }
  render_stage(.args[1])
}
