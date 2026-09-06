
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
