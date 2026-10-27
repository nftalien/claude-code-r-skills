# Synthetic modality files must pass the modules' own gates on a clean config,
# and must be written where the ingest globs look.

test_that("synthetic EEG uses export column names and passes QC", {
  cfg <- builder_test_config()
  df <- generate_synthetic_eeg(cfg, n = 5)
  expect_true(all(c("subject", "ses", "chan", "cond", "meas", "val", "ntr") %in% names(df)))
  expect_true(all(grepl("^sub-", df$subject)))
  expect_setequal(unique(df$ses), c("ses-01", "ses-02"))
  expect_true(all(df$ntr >= 8))
  cfg$eeg$enabled <- FALSE
  expect_null(generate_synthetic_eeg(cfg))
})

test_that("synthetic files land on the ingest globs and the full modality path runs", {
  cfg <- builder_test_config()
  paths <- generate_synthetic_modalities_from_config(cfg, outdir = cfg$paths$raw_data, n = 5, days = 12)
  expect_true(file.exists(paths$eeg))
  expect_setequal(names(paths$sensors), c("accel", "hr"))
  expect_equal(builder_glob_files(cfg, cfg$eeg$file_glob), paths$eeg)
  long <- ingest_eeg_features(cfg, write = TRUE)
  expect_true(file.exists(file.path(cfg$paths$raw_data, "BUILD_eeg_features_latest.rds")))
  expect_true(all(eeg_qc_summary(long, cfg)$pass))
  ft <- eeg_feature_table(long, cfg)
  expect_equal(nrow(ft), 10)
  for (sk in c("accel", "hr")) {
    day <- ingest_sensor_stream(cfg, sk, write = TRUE)
    expect_true(file.exists(file.path(cfg$paths$raw_data,
                                      paste0("BUILD_sensor_", sk, "_day_latest.rds"))))
    day <- sensor_valid_days(day, cfg$sensors$streams[[sk]]$valid_day_rule)
    expect_true(any(day$valid_day))
  }
})
