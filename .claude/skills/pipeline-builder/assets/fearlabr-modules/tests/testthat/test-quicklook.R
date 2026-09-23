test_that("summarise_render_log counts the pipeline glyphs and returns warning lines", {
  log <- c("✓ Loaded fearlabr 0.2.0", "• REDCap raw  n=100", "⚠️ 3 EEG value(s) were not numeric",
           "⏭ No MetricWire data present", "✓ Wrote snapshot")
  s <- summarise_render_log(log)
  expect_equal(unname(s$counts), c(2, 1, 1, 1))
  expect_equal(s$warn_lines, "⚠️ 3 EEG value(s) were not numeric")
  expect_equal(s$skip_lines, "⏭ No MetricWire data present")
})

test_that("modality_coverage_dashboard binds summaries and checks columns", {
  cfg <- builder_test_config()
  df <- tibble::tibble(id = c("0001", "0002"), tp = c("baseline", "baseline"))
  a <- timepoint_coverage_summary(timepoint_coverage(df, "id", "tp", cfg, "eeg"))
  b <- timepoint_coverage_summary(timepoint_coverage(df, "id", "tp", cfg, "sensors"))
  d <- modality_coverage_dashboard(a, b)
  expect_equal(nrow(d), 4)
  expect_setequal(unique(d$modality), c("eeg", "sensors"))
  expect_equal(nrow(modality_coverage_dashboard(list(a, b))), 4)
  expect_error(modality_coverage_dashboard(tibble::tibble(x = 1)), "missing column")
  skip_if_not_installed("ggplot2")
  expect_s3_class(plot_coverage_dashboard(d), "ggplot")
})

test_that("plot_ema_compliance_heatmap aggregates to participant-day", {
  ema <- tibble::tibble(study_id = rep(c("0001", "0002"), each = 4),
                        ema_date = rep(as.Date("2025-01-01") + 0:1, 4),
                        completed = c(TRUE, FALSE, TRUE, TRUE, FALSE, FALSE, TRUE, FALSE))
  skip_if_not_installed("ggplot2")
  p <- plot_ema_compliance_heatmap(ema)
  expect_s3_class(p, "ggplot")
  expect_equal(nrow(p$data), 4)
})
