# The manifest enforces the two rules the builder rests on: nothing is
# generated on an unapproved dependency, and nothing is approved unseen.

test_that("new_pipeline_manifest includes stages by enabled modality", {
  cfg <- builder_test_config()
  m <- new_pipeline_manifest(cfg)
  ids <- vapply(m$stages, function(s) s$id, character(1))
  expect_true(all(c("01e_ingest_eeg", "02s_qc_sensor", "07m_link_modalities") %in% ids))
  expect_false("04_prepare_ema" %in% ids)
  link <- m$stages[[match("07m_link_modalities", ids)]]
  expect_setequal(unlist(link$depends_on), c("03_clean_redcap", "02e_qc_eeg", "02s_qc_sensor"))
  cfg$metricwire$enabled <- TRUE; cfg$eeg$enabled <- FALSE
  ids2 <- vapply(new_pipeline_manifest(cfg)$stages, function(s) s$id, character(1))
  expect_true("06_score_ema" %in% ids2); expect_false("02e_qc_eeg" %in% ids2)
})

test_that("mark_stage gates generation on approved dependencies and approval on a render", {
  m <- new_pipeline_manifest(builder_test_config())
  expect_error(mark_stage(m, "01_ingest", "generated"), "waits on unapproved")
  expect_error(mark_stage(m, "00_setup", "approved"), "not 'rendered'")
  m <- mark_stage(m, "00_setup", "generated")
  m <- mark_stage(m, "00_setup", "rendered", render = "output/renders/00_setup.html")
  m <- mark_stage(m, "00_setup", "approved", note = "config echo checked")
  s <- m$stages[[1]]
  expect_equal(s$status, "approved"); expect_false(is.null(s$approved_at))
  expect_equal(s$render, "output/renders/00_setup.html")
  m <- mark_stage(m, "01_ingest", "generated")
  expect_equal(m$stages[[stage_index(m, "01_ingest")]]$status, "generated")
  expect_error(mark_stage(m, "01_ingest", "done"), "arg")
})

test_that("next_stage walks the DAG and resetting upstream invalidates downstream", {
  m <- new_pipeline_manifest(builder_test_config(), include_analysis = FALSE)
  expect_equal(next_stage(m), "00_setup")
  m <- mark_stage(m, "00_setup", "rendered") |> mark_stage("00_setup", "approved")
  expect_equal(next_stage(m), "00b_pipeline_status")
  m <- mark_stage(m, "01_ingest", "rendered") |> mark_stage("01_ingest", "approved")
  m <- mark_stage(m, "02_validate", "rendered") |> mark_stage("02_validate", "approved")
  m <- mark_stage(m, "00_setup", "planned", note = "config changed")
  tbl <- manifest_stages_tbl(m)
  expect_equal(tbl$status[tbl$id %in% c("01_ingest", "02_validate")], c("planned", "planned"))
  expect_match(tbl$notes[tbl$id == "01_ingest"], "upstream '00_setup'")
  expect_equal(next_stage(m), "00_setup")
})

test_that("manifest round-trips through yaml", {
  cfg <- builder_test_config()
  m <- new_pipeline_manifest(cfg)
  m <- mark_stage(m, "00_setup", "rendered") |> mark_stage("00_setup", "approved")
  p <- tempfile(fileext = ".yml")
  write_pipeline_manifest(m, p)
  m2 <- read_pipeline_manifest(p)
  expect_equal(manifest_stages_tbl(m2)$status, manifest_stages_tbl(m)$status)
  expect_equal(unlist(m2$modalities), c("redcap", "eeg", "sensors"))
  expect_equal(nrow(pipeline_status_table(m2)), length(m$stages))
})

test_that("DAG outputs: mermaid text and a layered layout", {
  m <- new_pipeline_manifest(builder_test_config(), include_analysis = FALSE)
  mm <- pipeline_dag_mermaid(m)
  expect_match(mm, "^flowchart LR")
  expect_match(mm, "00_setup --> 01_ingest")
  expect_match(mm, ':::planned')
  lay <- pipeline_dag_layout(m)
  d <- stats::setNames(lay$nodes$x, lay$nodes$id)
  expect_equal(unname(d["00_setup"]), 0L)
  expect_equal(unname(d["02_validate"]), 2L)
  expect_true(d["07m_link_modalities"] > d["03_clean_redcap"])
  expect_true(d["07m_link_modalities"] > d["02e_qc_eeg"])
  skip_if_not_installed("ggplot2")
  expect_s3_class(plot_pipeline_dag(m), "ggplot")
})

test_that("notebook helpers gate, record and approve through _pipeline.yml", {
  p <- tempfile(fileext = ".yml")
  write_pipeline_manifest(new_pipeline_manifest(builder_test_config(), include_analysis = FALSE), p)
  expect_output(builder_stage_gate("00_setup", manifest_path = p), "unlocked")
  expect_error(builder_stage_gate("01_ingest", manifest_path = p), "waits on unapproved")
  expect_output(builder_record_render("00_setup", manifest_path = p), "marked rendered")
  expect_equal(manifest_stages_tbl(read_pipeline_manifest(p))$render[1], "output/renders/00_setup.html")
  expect_output(builder_approve("00_setup", note = "looked at config echo", manifest_path = p),
                "Next stage: 00b_pipeline_status")
  expect_output(builder_stage_gate("01_ingest", manifest_path = p), "ID audit lines")
  # No manifest: the helpers say so and do nothing
  expect_output(builder_stage_gate("00_setup", manifest_path = tempfile()), "skipped")
  expect_null(builder_record_render("00_setup", manifest_path = tempfile()))
})
