# ════════════════════════════════════════════════════════════════════════
# R/pipeline_manifest.R — The stage-by-stage build record (_pipeline.yml)
# ════════════════════════════════════════════════════════════════════════
# The builder works one stage at a time: generate the notebook, render it,
# show the person the render, wait for them to approve it, then unlock the
# next stage. That sequence needs a record that survives the chat, so it
# lives in `_pipeline.yml` at the project root next to `_config.yml`.
#
# Status vocabulary, in order:
#   planned    the stage is in the plan; no notebook written yet
#   generated  the QMD exists
#   rendered   the QMD rendered; the HTML is at `render`
#   approved   a person looked at the render and said it is right
#   failed     the render stopped; `notes` holds the reason
#
# A stage cannot be approved from any state but rendered, and a stage cannot
# be generated while a dependency is unapproved. Those two rules are the
# whole point: nothing downstream is built on a stage nobody has looked at.
# ════════════════════════════════════════════════════════════════════════

stage_status_levels <- function() c("planned", "generated", "rendered", "approved", "failed")

#' Every stage the builder knows, with its modality and dependencies.
#'
#' `verify` says what the person is asked to look at before approving.
#' Add a row here when a modality module adds a stage; the manifest,
#' the status table and the DAG all derive from this.
builder_stage_registry <- function() {
  tibble::tribble(
    # `gating` is FALSE for a stage whose content is derived from the manifest
    # rather than from data. There is nothing in it to verify against a study
    # artifact, and it is re-rendered as the build progresses, so approving it
    # is a formality that comes back every time. next_stage() steps over these.
    ~id,                    ~label,                    ~modality, ~depends_on,
    ~verify,                                                     ~gating,
    "00_setup",             "Setup",                   "core",    character(0),
    "config echo; secrets guard; timepoint schedule table", TRUE,
    "00b_pipeline_status",  "Pipeline status",         "core",    "00_setup",
    "DAG and status table match the plan", FALSE,
    "01_ingest",            "Ingest REDCap + EMA",     "redcap",  "00_setup",
    "ID audit lines; row counts; which export was read", TRUE,
    "02_validate",          "Validate",                "redcap",  "01_ingest",
    "required columns; duplicate keys; dictionary diff", TRUE,
    "03_clean_redcap",      "Clean + score REDCap",    "redcap",  "02_validate",
    "calc-field mismatch table; out-of-range table; timepoint completeness", TRUE,
    "03b_lock_redcap",      "Analysis sets / lock",    "redcap",  "03_clean_redcap",
    "CONSORT flow; ITT/mITT/PP counts", TRUE,
    "04_prepare_ema",       "Prepare EMA",             "ema",     "01_ingest",
    "canonical name crosswalk; free text diverted", TRUE,
    "05_clean_ema",         "Clean EMA",               "ema",     "04_prepare_ema",
    "compliance heatmap; exclusions log", TRUE,
    "06_score_ema",         "Score EMA",               "ema",     "05_clean_ema",
    "schema match audit; observed min/max per item", TRUE,
    "07_link_redcap_ema",   "Link REDCap + EMA",       "ema",     c("03_clean_redcap", "06_score_ema"),
    "linkage audit; only-in-each lists", TRUE,
    "01e_ingest_eeg",       "Ingest EEG features",     "eeg",     "00_setup",
    "ID audit; session -> timepoint map; unmapped sessions", TRUE,
    "02e_qc_eeg",           "EEG QC + features",       "eeg",     "01e_ingest_eeg",
    "QC tile; feature distributions; flagged participants", TRUE,
    "01s_ingest_sensor",    "Ingest sensor streams",   "sensors", "00_setup",
    "ID audit per stream; unparseable dates; duplicate days", TRUE,
    "02s_qc_sensor",        "Sensor coverage",         "sensors", "01s_ingest_sensor",
    "valid-day rule printed; coverage tile; per-participant table", TRUE,
    "07m_link_modalities",  "Link modalities",         "multi",   c("03_clean_redcap"),
    "cross-modality coverage dashboard; only-in-each across modalities", TRUE,
    "07c_id_audit",         "ID audit",                "core",    "07m_link_modalities",
    "UpSet; format inventory; only-in-each", TRUE,
    "08_feasibility",       "Feasibility",             "analysis", "07m_link_modalities",
    "registry F entries against benchmarks", TRUE,
    "10_outcomes_models",   "Outcomes models",         "analysis", "08_feasibility",
    "validation gates; identification table", TRUE
  )
}

#' Which modalities a config turns on.
config_modalities <- function(config) {
  m <- "redcap"
  if (isTRUE(config$metricwire$enabled)) m <- c(m, "ema")
  if (isTRUE(config$eeg$enabled)) m <- c(m, "eeg")
  if (isTRUE(config$sensors$enabled)) m <- c(m, "sensors")
  m
}

#' Build a fresh manifest for a study from its config.
#'
#' Stages are included when their modality is on (core, multi and analysis
#' always are). 07m additionally depends on the last stage of every enabled
#' non-REDCap modality, so cross-modality linkage cannot be built before each
#' modality has been approved on its own.
#'
#' @param config Config list.
#' @param modalities Override the config-derived modality set.
#' @param include_analysis Include 08/10? Default TRUE.
new_pipeline_manifest <- function(config, modalities = NULL, include_analysis = TRUE) {
  modalities <- modalities %||% config_modalities(config)
  reg <- builder_stage_registry()
  keep <- reg$modality %in% c("core", "multi", modalities) |
    (include_analysis & reg$modality == "analysis")
  reg <- reg[keep, ]
  tails <- c(ema = "07_link_redcap_ema", eeg = "02e_qc_eeg", sensors = "02s_qc_sensor")
  extra <- unname(tails[intersect(names(tails), modalities)])
  stages <- lapply(seq_len(nrow(reg)), function(i) {
    deps <- reg$depends_on[[i]]
    if (reg$id[i] == "07m_link_modalities") deps <- unique(c(deps, extra))
    deps <- intersect(deps, reg$id)
    list(id = reg$id[i], label = reg$label[i], modality = reg$modality[i],
         qmd = paste0(reg$id[i], ".qmd"), depends_on = as.list(deps),
         verify = reg$verify[i], status = "planned", render = NULL,
         notes = "", updated_at = NULL, approved_at = NULL)
  })
  list(study = config$study$name %||% "study",
       created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
       modalities = as.list(modalities),
       timepoints = as.list(names(config$timepoints$schedule %||% list())),
       stages = stages)
}

read_pipeline_manifest <- function(path = here::here("_pipeline.yml")) {
  if (!file.exists(path)) stop("Pipeline manifest not found: ", path, call. = FALSE)
  m <- yaml::read_yaml(path)
  attr(m, "manifest_path") <- normalizePath(path)
  m
}

write_pipeline_manifest <- function(manifest, path = attr(manifest, "manifest_path") %||% here::here("_pipeline.yml")) {
  attr(manifest, "manifest_path") <- NULL
  yaml::write_yaml(manifest, path)
  invisible(path)
}

#' Stages as a tibble (one row each; depends_on is a list-column).
manifest_stages_tbl <- function(manifest) {
  purrr::map_dfr(manifest$stages, function(s) {
    tibble::tibble(
      id = s$id, label = s$label %||% s$id, modality = s$modality %||% "core",
      status = s$status %||% "planned",
      depends_on = list(as.character(unlist(s$depends_on))),
      render = as.character(s$render %||% NA_character_),
      notes = as.character(s$notes %||% ""),
      updated_at = as.character(s$updated_at %||% NA_character_),
      approved_at = as.character(s$approved_at %||% NA_character_)
    )
  })
}

stage_index <- function(manifest, id) {
  ids <- vapply(manifest$stages, function(s) s$id, character(1))
  i <- match(id, ids)
  if (is.na(i)) stop("[manifest] no stage '", id, "'. Stages: ", paste(ids, collapse = ", "), call. = FALSE)
  i
}

#' Stop unless every dependency of a stage is approved.
assert_stage_ready <- function(manifest, id) {
  s <- manifest$stages[[stage_index(manifest, id)]]
  tbl <- manifest_stages_tbl(manifest)
  deps <- as.character(unlist(s$depends_on))
  st <- tbl$status[match(deps, tbl$id)]
  bad <- deps[is.na(st) | st != "approved"]
  if (length(bad)) {
    stop("[assert_stage_ready] '", id, "' waits on unapproved stage(s): ",
         paste(bad, collapse = ", "), ". Render and approve those first.", call. = FALSE)
  }
  invisible(TRUE)
}

#' Record a status change.
#'
#' @param manifest Manifest list.
#' @param id Stage id.
#' @param status One of stage_status_levels().
#' @param note Optional free text (a failure reason, what was checked).
#' @param render Optional path to the rendered HTML.
#' @param force Allow approving a stage that has not been rendered.
mark_stage <- function(manifest, id, status, note = NULL, render = NULL, force = FALSE) {
  status <- match.arg(status, stage_status_levels())
  i <- stage_index(manifest, id)
  s <- manifest$stages[[i]]
  if (status == "generated") assert_stage_ready(manifest, id)
  # Approving something already approved is a no-op, not a mistake: it happens
  # when a step is repeated. Only approving something never rendered is wrong.
  if (status == "approved" && identical(s$status, "approved")) {
    cat("\u2022 ", id, " is already approved (", s$approved_at %||% "earlier", "); nothing to do\n", sep = "")
    return(manifest)
  }
  if (status == "approved" && !identical(s$status, "rendered") && !isTRUE(force)) {
    stop("[mark_stage] '", id, "' is '", s$status, "', not 'rendered'. A stage is ",
         "approved only after its render has been looked at.",
         if (identical(s$status, "planned")) " Render it first." else "", call. = FALSE)
  }
  now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  s$status <- status
  s$updated_at <- now
  if (!is.null(note)) s$notes <- note
  if (!is.null(render)) s$render <- render
  if (status == "approved") s$approved_at <- now
  # Un-approving upstream invalidates what was built on it.
  manifest$stages[[i]] <- s
  if (status %in% c("planned", "failed")) manifest <- invalidate_downstream(manifest, id)
  manifest
}

#' Reset every stage downstream of `id` to planned if it was past that.
invalidate_downstream <- function(manifest, id) {
  tbl <- manifest_stages_tbl(manifest)
  todo <- id; seen <- character(0)
  while (length(todo)) {
    cur <- todo[1]; todo <- todo[-1]; seen <- c(seen, cur)
    kids <- tbl$id[purrr::map_lgl(tbl$depends_on, ~ cur %in% .x)]
    for (k in setdiff(kids, seen)) {
      j <- stage_index(manifest, k)
      if (manifest$stages[[j]]$status != "planned") {
        manifest$stages[[j]]$status <- "planned"
        manifest$stages[[j]]$notes <- paste0("reset: upstream '", id, "' changed")
        manifest$stages[[j]]$approved_at <- NULL
      }
      todo <- c(todo, k)
    }
  }
  manifest
}

#' The next stage to work on: first unapproved stage whose deps are approved.
next_stage <- function(manifest) {
  tbl <- manifest_stages_tbl(manifest)
  reg <- builder_stage_registry()
  advisory <- tbl$id %in% reg$id[!reg$gating]

  ready <- function(i) {
    deps <- tbl$depends_on[[i]]
    tbl$status[i] != "approved" &&
      all(tbl$status[match(deps, tbl$id)] == "approved")
  }
  # Real work first. A stage whose content is derived from the manifest gates
  # nothing and is re-rendered as the build moves, so nominating it would put
  # a formality ahead of the next actual stage -- every time.
  for (i in seq_len(nrow(tbl))) if (!advisory[i] && ready(i)) return(tbl$id[i])
  for (i in seq_len(nrow(tbl))) if (advisory[i] && ready(i)) return(tbl$id[i])
  NULL
}

#' Status table for printing in 00b and in the chat.
pipeline_status_table <- function(manifest) {
  manifest_stages_tbl(manifest) |>
    dplyr::mutate(depends_on = purrr::map_chr(.data$depends_on, ~ paste(.x, collapse = ", "))) |>
    dplyr::select("id", "label", "modality", "status", "depends_on", "approved_at", "notes")
}

#' Mermaid flowchart text for the DAG, nodes coloured by status.
pipeline_dag_mermaid <- function(manifest) {
  tbl <- manifest_stages_tbl(manifest)
  node <- function(id) gsub("[^A-Za-z0-9_]", "_", id)
  lines <- c("flowchart LR")
  for (i in seq_len(nrow(tbl))) {
    lines <- c(lines, sprintf('  %s["%s<br/>%s"]:::%s', node(tbl$id[i]), tbl$id[i],
                              tbl$label[i], tbl$status[i]))
  }
  for (i in seq_len(nrow(tbl))) {
    for (d in tbl$depends_on[[i]]) lines <- c(lines, sprintf("  %s --> %s", node(d), node(tbl$id[i])))
  }
  lines <- c(lines,
             "  classDef planned fill:#F2F2F2,stroke:#999,color:#333",
             "  classDef generated fill:#FFF3D6,stroke:#E9A03B,color:#333",
             "  classDef rendered fill:#DCE9F2,stroke:#2A6F97,color:#333",
             "  classDef approved fill:#2A6F97,stroke:#1B4965,color:#fff",
             "  classDef failed fill:#F8D7DA,stroke:#B8336A,color:#333")
  paste(lines, collapse = "\n")
}

#' Layered layout of the DAG (longest path from a root = column).
pipeline_dag_layout <- function(manifest) {
  tbl <- manifest_stages_tbl(manifest)
  depth <- stats::setNames(rep(NA_integer_, nrow(tbl)), tbl$id)
  # Iterate until stable; the graph is small and acyclic by construction.
  for (iter in seq_len(nrow(tbl) + 1)) {
    for (i in seq_len(nrow(tbl))) {
      deps <- tbl$depends_on[[i]]
      depth[tbl$id[i]] <- if (length(deps) == 0) 0L else {
        dd <- depth[deps]; if (any(is.na(dd))) NA_integer_ else max(dd) + 1L
      }
    }
    if (!any(is.na(depth))) break
  }
  if (any(is.na(depth))) stop("[pipeline_dag_layout] dependency cycle or unknown dependency.", call. = FALSE)
  tbl$x <- as.integer(depth[tbl$id])
  tbl <- tbl |>
    dplyr::group_by(.data$x) |>
    dplyr::mutate(y = dplyr::row_number() - (dplyr::n() + 1) / 2) |>
    dplyr::ungroup()
  edges <- purrr::map_dfr(seq_len(nrow(tbl)), function(i) {
    deps <- tbl$depends_on[[i]]
    if (!length(deps)) return(tibble::tibble(from = character(), to = character()))
    tibble::tibble(from = deps, to = tbl$id[i])
  })
  edges <- edges |>
    dplyr::left_join(tbl[, c("id", "x", "y")], by = c("from" = "id")) |>
    dplyr::rename(x0 = "x", y0 = "y") |>
    dplyr::left_join(tbl[, c("id", "x", "y")], by = c("to" = "id")) |>
    dplyr::rename(x1 = "x", y1 = "y")
  list(nodes = tbl, edges = edges)
}

#' ggplot of the DAG with nodes coloured by status.
plot_pipeline_dag <- function(manifest) {
  lay <- pipeline_dag_layout(manifest)
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    message("ggplot2 not installed; returning the layout instead.")
    return(invisible(lay))
  }
  cols <- c(planned = "#BFBFBF", generated = "#E9A03B", rendered = "#7FB2D6",
            approved = "#2A6F97", failed = "#B8336A")
  ggplot2::ggplot() +
    ggplot2::geom_segment(data = lay$edges,
                          ggplot2::aes(x = .data$x0, y = .data$y0, xend = .data$x1, yend = .data$y1),
                          colour = "grey60") +
    ggplot2::geom_label(data = lay$nodes,
                        ggplot2::aes(x = .data$x, y = .data$y, label = .data$id,
                                     fill = .data$status),
                        colour = "black", size = 3, label.padding = ggplot2::unit(0.25, "lines")) +
    ggplot2::scale_fill_manual(values = cols, drop = FALSE, name = "Status") +
    ggplot2::scale_x_continuous(breaks = NULL) +
    ggplot2::scale_y_continuous(breaks = NULL) +
    ggplot2::labs(x = NULL, y = NULL) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(panel.grid = ggplot2::element_blank())
}

# ── Notebook-facing helpers ────────────────────────────────────────────
# Each generated stage opens with builder_stage_gate() and closes with
# builder_record_render(); the person approves in the console with
# builder_approve(). Without a _pipeline.yml all three are no-ops that say
# so, so a notebook still runs in a project that never used the builder.

#' Refuse to run a stage whose dependencies are unapproved; print what to verify.
builder_stage_gate <- function(id, manifest_path = here::here("_pipeline.yml")) {
  if (!file.exists(manifest_path)) {
    cat("• No _pipeline.yml; stage gate skipped for ", id, "\n", sep = "")
    return(invisible(NULL))
  }
  m <- read_pipeline_manifest(manifest_path)
  assert_stage_ready(m, id)
  s <- m$stages[[stage_index(m, id)]]
  cat("✓ Stage ", id, " unlocked. Before approving, look at: ", s$verify %||% "the render", "\n", sep = "")
  invisible(m)
}

#' Record that a stage rendered (called as the last chunk of the notebook).
builder_record_render <- function(id, manifest_path = here::here("_pipeline.yml"),
                                  render_dir = "output/renders") {
  if (!file.exists(manifest_path)) {
    cat("• No _pipeline.yml; render of ", id, " not recorded\n", sep = "")
    return(invisible(NULL))
  }
  m <- read_pipeline_manifest(manifest_path)
  m <- mark_stage(m, id, "rendered", render = file.path(render_dir, paste0(id, ".html")))
  write_pipeline_manifest(m, manifest_path)
  cat("✓ _pipeline.yml: ", id, " marked rendered. Approve in the R console with ",
      "builder_approve(\"", id, "\")\n", sep = "")
  invisible(m)
}

#' Approve a rendered stage and name the next one.
builder_approve <- function(id, note = NULL, manifest_path = here::here("_pipeline.yml")) {
  m <- read_pipeline_manifest(manifest_path)
  m <- mark_stage(m, id, "approved", note = note)
  write_pipeline_manifest(m, manifest_path)
  nxt <- next_stage(m)
  cat("✓ ", id, " approved. ", if (is.null(nxt)) "Every stage is approved." else
      paste0("Next stage: ", nxt), "\n", sep = "")
  invisible(m)
}
