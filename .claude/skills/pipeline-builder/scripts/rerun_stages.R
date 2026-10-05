#!/usr/bin/env Rscript
# ════════════════════════════════════════════════════════════════════════
# rerun_stages.R — render a run of already-verified stages in order,
# approving each so the next one's gate opens
# ════════════════════════════════════════════════════════════════════════
#   Rscript scripts/rerun_stages.R 03_clean_redcap 03b_lock_redcap 04_prepare_ema ...
#
# For the case where an upstream fix resets a chain of stages whose
# notebooks did not change. Each stage is rendered with render_stage.R,
# filed at output/renders/<id>.html, and approved, in the order given. The
# run stops at the first render that fails, and stages after it are left
# untouched, so the manifest always says exactly how far the chain got.
#
# This is a convenience, not a substitute for looking: the renders are
# still the record, and the person owns the approval. Open the ones the
# fix was expected to change before committing _pipeline.yml.
# ════════════════════════════════════════════════════════════════════════
suppressPackageStartupMessages(library(fearlabr))
source("scripts/render_stage.R")

stages <- commandArgs(trailingOnly = TRUE)
if (!length(stages)) {
  stop("Usage: Rscript scripts/rerun_stages.R <stage id> [<stage id> ...], in pipeline order")
}
for (id in stages) {
  if (!file.exists(file.path("notebooks", paste0(id, ".qmd")))) stop("No notebooks/", id, ".qmd")
}

t0 <- Sys.time()
done <- character()
for (id in stages) {
  cat("\n══ ", id, " (", length(done) + 1, " of ", length(stages), ") ══\n", sep = "")
  render_stage(id)                       # stops on failure; nothing after it runs
  builder_approve(id)
  done <- c(done, id)
  # Stages that take a subgroup parameter are rendered again per subgroup
  # declared in analysis.subgroups, so the subgroup set is never stale.
  if (id %in% c("10_outcomes_models", "11_secondary_analyses")) {
    cfg <- fearlabr::read_config()
    for (key in names(cfg$analysis$subgroups)) render_stage(id, key)
  }
}
cat("\n✓ ", length(done), " stage(s) rendered and approved in ",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1), " min: ",
    paste(done, collapse = ", "), "\n", sep = "")
cat("  Renders are in output/renders/. Look at the ones the fix should have changed, then:\n",
    "    git pull --no-rebase --no-edit\n",
    "    git add _pipeline.yml\n",
    "    git commit -m \"Re-render and approve ", done[1], " through ", done[length(done)], "\"\n",
    "    git push\n", sep = "")
