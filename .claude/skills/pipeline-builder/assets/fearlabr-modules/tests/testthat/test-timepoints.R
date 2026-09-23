# Timepoints are declared once and every modality is checked against them.

test_that("timepoint_schedule tidies the declaration in declared order", {
  s <- timepoint_schedule(builder_test_config())
  expect_equal(s$timepoint, c("baseline", "week4", "week12"))
  expect_equal(s$window_lo, c(-7, 25, 77))
  expect_equal(s$window_hi, c(7, 35, 98))
  expect_true("eeg" %in% s$modalities[[1]])
  expect_false("eeg" %in% s$modalities[[3]])
})

test_that("assert_timepoints_declared stops on the config shapes that would double count", {
  cfg <- builder_test_config()
  cfg$timepoints$schedule$week4$window_days <- c(-30, 7)   # overlaps baseline
  expect_error(assert_timepoints_declared(cfg), "overlap")
  cfg <- builder_test_config()
  cfg$timepoints$schedule$week4$modalities <- c("redcap", "fmri")
  expect_error(assert_timepoints_declared(cfg), "unknown modality")
  cfg <- builder_test_config()
  cfg$timepoints$anchor <- "screening"
  expect_error(assert_timepoints_declared(cfg), "anchor")
  cfg <- builder_test_config()
  cfg$timepoints <- NULL
  expect_error(assert_timepoints_declared(cfg), "no timepoints.schedule")
})

test_that("assign_timepoint uses the windows and returns NA outside them", {
  cfg <- builder_test_config()
  anchor <- as.Date("2025-01-01")
  obs <- anchor + c(0, 5, 20, 30, 90, 200)
  expect_equal(assign_timepoint(obs, anchor, cfg),
               c("baseline", "baseline", NA, "week4", "week12", NA))
})

test_that("timepoint_coverage reports expected participants missing a modality", {
  cfg <- builder_test_config()
  df <- tibble::tibble(id = c("0001", "0001", "0002"), tp = c("baseline", "week4", "baseline"))
  cov <- timepoint_coverage(df, "id", "tp", cfg, modality = "eeg",
                            expected_ids = c("0001", "0002", "0003"))
  # eeg is expected at baseline and week4 only, for 3 participants
  expect_equal(nrow(cov), 6)
  expect_equal(sum(cov$observed), 3)
  s <- timepoint_coverage_summary(cov)
  expect_equal(s$n_expected, c(3, 3))
  expect_equal(s$n_observed, c(2, 1))
  cfg$timepoints$schedule$baseline$modalities <- c("redcap", "eeg", "sensors")
  expect_error(timepoint_coverage(df, "id", "tp", cfg, modality = "ema"), "no timepoint lists")
  skip_if_not_installed("ggplot2")
  expect_s3_class(plot_timepoint_completeness(cov), "ggplot")
})
