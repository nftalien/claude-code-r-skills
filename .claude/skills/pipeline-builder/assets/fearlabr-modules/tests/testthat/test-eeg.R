# The EEG module takes a preprocessed long export and puts it into the
# study's ID and timepoint vocabulary; it must fail loudly on a crosswalk
# that matches nothing.

write_eeg_export <- function(cfg, path = file.path(cfg$paths$raw_data, "eeg", "S_features.csv")) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  df <- generate_synthetic_eeg(cfg, n = 4)
  readr::write_csv(df, path, na = "")
  path
}

test_that("ingest_eeg_features maps export columns, ids and sessions", {
  cfg <- builder_test_config()
  p <- write_eeg_export(cfg)
  long <- ingest_eeg_features(cfg, write = FALSE)
  expect_setequal(names(long), c("study_id", "eeg_session", "timepoint", "channel",
                                 "condition", "measure", "value", "n_trials", "source_file"))
  expect_true(all(grepl("^[0-9]{4}$", long$study_id)))
  expect_setequal(unique(long$timepoint), c("baseline", "week4"))
  expect_type(long$value, "double")
  expect_equal(basename(p), unique(long$source_file))
})

test_that("ingest_eeg_features stops when a required export column is missing", {
  cfg <- builder_test_config()
  write_eeg_export(cfg)
  cfg$eeg$columns$value <- "amplitude_uv"
  expect_error(ingest_eeg_features(cfg, write = FALSE), "lacks column")
  cfg <- builder_test_config()
  expect_error(ingest_eeg_features(cfg, write = FALSE), "no files match")
})

test_that("an unmapped session is warned about and kept with timepoint NA", {
  cfg <- builder_test_config()
  write_eeg_export(cfg)
  cfg$eeg$session_map <- list(`ses-01` = "baseline")
  expect_warning(long <- ingest_eeg_features(cfg, write = FALSE), "not in eeg.session_map")
  expect_true(any(is.na(long$timepoint)))
  expect_true(all(long$eeg_session[is.na(long$timepoint)] == "ses-02"))
})

test_that("eeg_qc_summary flags low trials, out-of-range amplitude, missing channels", {
  cfg <- builder_test_config()
  write_eeg_export(cfg)
  long <- ingest_eeg_features(cfg, write = FALSE)
  qc <- eeg_qc_summary(long, cfg)
  expect_true(all(qc$pass))
  bad <- long
  bad$n_trials[bad$study_id == "0001" & bad$timepoint == "baseline"] <- 3L
  bad$value[bad$study_id == "0002" & bad$timepoint == "week4"][1] <- 999
  bad <- bad[!(bad$study_id == "0003" & bad$channel == "FCz"), ]
  qc <- eeg_qc_summary(bad, cfg)
  expect_true(qc$flag_low_trials[qc$study_id == "0001" & qc$timepoint == "baseline"])
  expect_true(qc$flag_amplitude_oob[qc$study_id == "0002" & qc$timepoint == "week4"])
  expect_true(all(qc$flag_missing_channels[qc$study_id == "0003"]))
  expect_equal(sum(!qc$pass), 4)
  skip_if_not_installed("ggplot2")
  expect_s3_class(plot_eeg_qc(qc), "ggplot")
})

test_that("eeg_feature_table averages declared channels and stops on a feature matching nothing", {
  cfg <- builder_test_config()
  write_eeg_export(cfg)
  long <- ingest_eeg_features(cfg, write = FALSE)
  ft <- eeg_feature_table(long, cfg)
  expect_setequal(names(ft), c("study_id", "timepoint", "ern", "crn"))
  expect_equal(nrow(ft), 4 * 2)
  manual <- long |>
    dplyr::filter(condition == "error", channel %in% c("FCz", "Cz"),
                  study_id == "0001", timepoint == "baseline") |>
    dplyr::pull(value) |> mean()
  expect_equal(ft$ern[ft$study_id == "0001" & ft$timepoint == "baseline"], manual)
  cfg$eeg$features[[1]]$condition <- "omission"
  expect_error(eeg_feature_table(long, cfg), "EEG feature 'ern'")
  skip_if_not_installed("ggplot2")
  expect_s3_class(plot_eeg_features(ft), "ggplot")
})

test_that("eeg_normalize_id strips the prefix and pads only numeric ids", {
  expect_equal(eeg_normalize_id(c("sub-12", "sub-0034", "P9"),
                                list(strip_prefix = "sub-", pad_width = 4)),
               c("0012", "0034", "P9"))
})
