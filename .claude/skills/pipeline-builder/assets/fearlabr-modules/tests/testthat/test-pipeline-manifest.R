
test_that("approving an already-approved stage is a no-op, not an error", {
  cfg <- list(metricwire = list(enabled = FALSE), timepoints = list(
    anchor = "baseline", anchor_date_column = "d",
    schedule = list(baseline = list(label = "B", offset_days = 0, window_days = c(-7, 7),
                                    redcap_event = "baseline_arm_1", modalities = "redcap"))))
  m <- new_pipeline_manifest(cfg, include_analysis = FALSE)
  m <- mark_stage(m, "00_setup", "generated")
  m <- mark_stage(m, "00_setup", "rendered", render = "output/renders/00_setup.html")
  m <- mark_stage(m, "00_setup", "approved", note = "checked")
  expect_equal(pipeline_status_table(m)$status[1], "approved")

  expect_output(m2 <- mark_stage(m, "00_setup", "approved"), "already approved")
  expect_equal(pipeline_status_table(m2)$status[1], "approved")
  expect_equal(m2$stages[[1]]$notes, "checked")          # the original note survives

  # a stage that was never rendered still refuses, and now says what to do
  expect_error(mark_stage(m, "01_ingest", "approved"), "Render it first")
})

# ── advisory stages ───────────────────────────────────────────────────────
# 00b_pipeline_status renders the manifest itself. Nothing depends on it, and
# it is re-rendered as the build moves, so nominating it as "next" put a
# formality ahead of the real next stage every time it was re-rendered.

test_that("the registry marks the manifest-derived stage as non-gating", {
  reg <- builder_stage_registry()
  expect_false(reg$gating[reg$id == "00b_pipeline_status"])
  expect_true(all(reg$gating[reg$id != "00b_pipeline_status"]))
})

test_that("next_stage steps over an advisory stage to the real work", {
  cfg <- builder_test_config()
  m <- new_pipeline_manifest(cfg, modalities = "redcap", include_analysis = FALSE)
  m <- mark_stage(m, "00_setup", "generated")
  m <- mark_stage(m, "00_setup", "rendered", render = "r.html")
  m <- mark_stage(m, "00_setup", "approved")
  # Both 00b and 01_ingest are now ready; 01_ingest is the one that gates work.
  expect_equal(next_stage(m), "01_ingest")
})

test_that("an advisory stage is nominated once nothing gating is left", {
  cfg <- builder_test_config()
  m <- new_pipeline_manifest(cfg, modalities = "redcap", include_analysis = FALSE)
  for (id in setdiff(manifest_stages_tbl(m)$id, "00b_pipeline_status")) {
    m <- mark_stage(m, id, "generated")
    m <- mark_stage(m, id, "rendered", render = "r.html")
    m <- mark_stage(m, id, "approved")
  }
  expect_equal(next_stage(m), "00b_pipeline_status")
})

test_that("next_stage is NULL when every stage is approved", {
  cfg <- builder_test_config()
  m <- new_pipeline_manifest(cfg, modalities = "redcap", include_analysis = FALSE)
  for (id in manifest_stages_tbl(m)$id) {
    m <- mark_stage(m, id, "generated")
    m <- mark_stage(m, id, "rendered", render = "r.html")
    m <- mark_stage(m, id, "approved")
  }
  expect_null(next_stage(m))
})
