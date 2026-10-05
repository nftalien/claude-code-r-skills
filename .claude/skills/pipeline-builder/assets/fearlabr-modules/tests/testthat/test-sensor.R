# Sensor streams: vendor columns in, canonical participant-days out, with the
# valid-day rule read from config and printed, never hardcoded.

write_sensor_exports <- function(cfg) {
  generate_synthetic_modalities_from_config(cfg, outdir = cfg$paths$raw_data, n = 4, days = 10)
}

test_that("day-grain stream ingests to one row per participant-day", {
  cfg <- builder_test_config()
  write_sensor_exports(cfg)
  day <- ingest_sensor_stream(cfg, "accel", write = FALSE)
  expect_setequal(names(day), c("study_id", "sensor_stream", "date", "steps",
                                "wear_minutes", "n_source_rows"))
  expect_s3_class(day$date, "Date")
  expect_false(any(duplicated(day[c("study_id", "date")])))
  expect_true(all(grepl("^[0-9]{4}$", day$study_id)))
})

test_that("epoch-grain stream aggregates to day with the declared functions", {
  cfg <- builder_test_config()
  write_sensor_exports(cfg)
  day <- ingest_sensor_stream(cfg, "hr", write = FALSE)
  expect_false(any(duplicated(day[c("study_id", "date")])))
  expect_true(all(day$n_source_rows >= 1))
  # Direct check of the aggregator
  df <- tibble::tibble(study_id = "0001", date = as.Date("2025-01-01"),
                       hr = c(60, 70), wear_minutes = c(1, 1))
  agg <- aggregate_sensor_to_day(df, c("hr", "wear_minutes"),
                                 list(hr = "mean", wear_minutes = "sum"))
  expect_equal(agg$hr, 65); expect_equal(agg$wear_minutes, 2); expect_equal(agg$n_source_rows, 2)
  expect_error(aggregate_sensor_to_day(df, "hr", list(hr = "median")), "unknown aggregate")
})

test_that("ingest_sensor_stream stops on an unknown stream or a missing export column", {
  cfg <- builder_test_config()
  write_sensor_exports(cfg)
  expect_error(ingest_sensor_stream(cfg, "gps"), "no stream 'gps'")
  cfg$sensors$streams$accel$metrics$steps <- "steps_total"
  expect_error(ingest_sensor_stream(cfg, "accel", write = FALSE), "lacks column")
})

test_that("valid-day rule, coverage and timepoint linkage", {
  cfg <- builder_test_config()
  write_sensor_exports(cfg)
  day <- ingest_sensor_stream(cfg, "accel", write = FALSE)
  expect_error(sensor_valid_days(day, ""), "empty")
  day <- sensor_valid_days(day, cfg$sensors$streams$accel$valid_day_rule)
  expect_equal(day$valid_day, !is.na(day$wear_minutes) & day$wear_minutes >= 600)
  cov <- sensor_coverage(day)
  expect_equal(nrow(cov), dplyr::n_distinct(day$study_id))
  expect_true(all(cov$n_valid_days <= cov$n_days_observed))
  anchors <- tibble::tibble(study_id = unique(day$study_id), anchor_date = as.Date("2025-02-01"))
  linked <- link_sensor_to_timepoints(day, anchors, cfg)
  expect_true(all(linked$timepoint[linked$days_from_anchor <= 7] == "baseline"))
  expect_true(all(is.na(linked$timepoint[linked$days_from_anchor > 7])))
  # A participant with no anchor is reported, not dropped
  expect_output(l2 <- link_sensor_to_timepoints(day, anchors[-1, ], cfg), "no anchor date")
  expect_equal(nrow(l2), nrow(day))
  skip_if_not_installed("ggplot2")
  expect_s3_class(plot_sensor_coverage(day), "ggplot")
})
