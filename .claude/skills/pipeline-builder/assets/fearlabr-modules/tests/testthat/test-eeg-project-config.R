# The eeg block is proposed from the export, the BrainVision header and
# marker files, and the BIDS sidecars; recording parameters land in the
# config (one source of truth).

eeg_fixture <- function(dir = tempfile("eeg_meta_"), n = 8, seed = 5) {
  set.seed(seed); dir.create(file.path(dir, "eeg"), recursive = TRUE, showWarnings = FALSE)
  ids <- sprintf("sub-%03d", seq_len(n))
  grid <- expand.grid(subject = ids, session = c("ses-01", "ses-02"), channel = c("FCz", "Cz", "Pz"),
                      condition = c("error", "correct"), measure = "mean_amplitude", KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
  grid$value <- round(stats::rnorm(nrow(grid), ifelse(grid$condition == "error", -6, -1), 3), 3)
  grid$nave <- sample(12:40, nrow(grid), TRUE)
  grid <- grid[!(grid$subject == "sub-003" & grid$channel == "Pz"), ]     # one participant lacks Pz
  readr::write_csv(grid, file.path(dir, "eeg", "flanker_features.csv"))
  vhdr <- c(
    "BrainVision Data Exchange Header File Version 1.0",
    "; Data created by the BrainVision Recorder", "",
    "[Common Infos]", "Codepage=UTF-8", "DataFile=sub-001_ses-01_task-flanker_eeg.eeg",
    "MarkerFile=sub-001_ses-01_task-flanker_eeg.vmrk", "DataFormat=BINARY", "DataOrientation=MULTIPLEXED",
    "NumberOfChannels=3", "; Sampling interval in microseconds", "SamplingInterval=2000", "",
    "[Binary Infos]", "BinaryFormat=IEEE_FLOAT_32", "",
    "[Channel Infos]", "; Each entry: Ch<Channel number>=<Name>,<Reference channel name>,",
    "Ch1=FCz,,0.1,µV", "Ch2=Cz,,0.1,µV", "Ch3=Pz,,0.1,µV", "",
    "[Comment]", "", "BrainAmp DC amplifier", "",
    "A m p l i f i e r  S e t u p", "============================",
    "Number of channels: 3", "Sampling Rate [Hz]: 500", "Sampling Interval [µS]: 2000", "",
    "Channels", "--------",
    "#     Name      Phys. Chn.    Resolution / Unit   Low Cutoff [s]   High Cutoff [Hz]   Notch [Hz]    Gradient         Offset",
    "1     FCz         1                0.1 µV             10              1000              Off",
    "2     Cz          2                0.1 µV             10              1000              Off",
    "3     Pz          3                0.1 µV             10              1000              Off")
  writeLines(vhdr, file.path(dir, "eeg", "sub-001_ses-01_task-flanker_eeg.vhdr"), useBytes = TRUE)
  mk <- c("BrainVision Data Exchange Marker File, Version 1.0", "", "[Common Infos]", "Codepage=UTF-8",
          "DataFile=sub-001_ses-01_task-flanker_eeg.eeg", "", "[Marker Infos]",
          "; Each entry: Mk<Marker number>=<Type>,<Description>,<Position in data points>,",
          "Mk1=New Segment,,1,1,0,20250201093000000000",
          sprintf("Mk%d=Stimulus,S%3d,%d,1,0", 2:61, rep(c(1, 2), 30), seq(500, by = 750, length.out = 60)),
          sprintf("Mk%d=Response,R  1,%d,1,0", 62:91, seq(800, by = 1500, length.out = 30)))
  writeLines(mk, file.path(dir, "eeg", "sub-001_ses-01_task-flanker_eeg.vmrk"))
  writeLines(jsonlite::toJSON(list(TaskName = "flanker", SamplingFrequency = 500, EEGReference = "Cz", PowerLineFrequency = 60,
                                   SoftwareFilters = list(highpass = list(cutoff = 0.1)), EEGChannelCount = 3,
                                   CapManufacturer = "Easycap", Manufacturer = "Brain Products", ManufacturersModelName = "BrainAmp DC",
                                   EEGPlacementScheme = "10-20"), auto_unbox = TRUE, pretty = TRUE),
             file.path(dir, "eeg", "sub-001_ses-01_task-flanker_eeg.json"))
  writeLines(c("participant_id\tage\tsex", paste0(ids, "\t", 20 + seq_len(n), "\tF")), file.path(dir, "eeg", "participants.tsv"))
  writeLines(c("onset\tduration\ttrial_type", paste0(seq(1, by = 1.5, length.out = 40), "\t0\t", rep(c("error", "correct"), c(10, 30)))),
             file.path(dir, "eeg", "sub-001_ses-01_task-flanker_events.tsv"))
  writeLines(c("bin 1", "Error trials", ".{S  1}{R  1}", "", "bin 2", "Correct trials", ".{S  2}{R  1}"),
             file.path(dir, "eeg", "flanker_bins.txt"))
  dir
}
eeg_fixture_config <- function() {
  cfg <- builder_test_config()
  cfg$timepoints$schedule$week4$modalities <- c("redcap", "sensors")
  cfg$timepoints$schedule$week12$modalities <- c("redcap", "eeg")   # eeg at baseline and week12 -> ses-01, ses-02
  cfg
}

test_that("column detection and the ID transform", {
  det <- eeg_detect_columns(c("subject", "session", "channel", "condition", "measure", "value", "nave", "extra"))
  expect_equal(det$columns$id, "subject"); expect_equal(det$columns$n_trials, "nave"); expect_equal(det$unmatched, "extra")
  det2 <- eeg_detect_columns(c("ERPset", "chlabel", "binlabel", "value"))
  expect_equal(det2$columns$id, "ERPset"); expect_equal(det2$columns$channel, "chlabel"); expect_equal(det2$columns$condition, "binlabel")
  it <- infer_id_transform(c("sub-001", "sub-012", "sub-100"))
  expect_equal(it$transform, list(strip_prefix = "sub-", pad_width = 3)); expect_equal(it$pattern, "^[0-9]{3}$")
  expect_equal(infer_id_transform(c("12", "7"))$transform, list(pad_width = 2))
  expect_true(is.na(infer_id_transform(c("A", "B"))$pattern))
})

test_that("BrainVision header and marker files parse", {
  d <- eeg_fixture()
  h <- brainvision_read_vhdr(file.path(d, "eeg", "sub-001_ses-01_task-flanker_eeg.vhdr"))
  expect_equal(h$sampling_rate_hz, 500); expect_equal(h$n_channels, 3L)
  expect_equal(h$channels$name, c("FCz", "Cz", "Pz")); expect_equal(h$unit, "µV")
  expect_equal(h$hardware_filters$low_cutoff_s, 10); expect_equal(h$hardware_filters$high_cutoff_hz, 1000); expect_equal(h$hardware_filters$notch_hz, "Off")
  expect_match(h$amplifier, "BrainAmp")
  expect_match(h$reference, "common")
  m <- brainvision_read_vmrk(file.path(d, "eeg", "sub-001_ses-01_task-flanker_eeg.vmrk"))
  expect_equal(nrow(m), 91); expect_equal(m$type[1], "New Segment"); expect_false(is.na(m$date[1]))
  s <- brainvision_marker_summary(m)
  expect_equal(s$n[s$type == "Stimulus" & s$description == "S  1"], 30)
  expect_equal(sum(s$n[s$type == "Response"]), 30)
  bad <- tempfile(fileext = ".vhdr"); writeLines("not a header", bad)
  expect_error(brainvision_read_vhdr(bad), "BrainVision header line")
})

test_that("BIDS sidecars and the ERPLAB bin descriptor parse", {
  d <- eeg_fixture()
  j <- bids_read_eeg_json(file.path(d, "eeg", "sub-001_ses-01_task-flanker_eeg.json"))
  expect_equal(j$SamplingFrequency, 500); expect_equal(j$EEGReference, "Cz")
  p <- bids_read_participants(file.path(d, "eeg", "participants.tsv")); expect_equal(nrow(p), 8)
  e <- bids_read_events(file.path(d, "eeg", "sub-001_ses-01_task-flanker_events.tsv"))
  ec <- bids_event_counts(e); expect_equal(ec$n[ec$condition == "correct"], 30)
  b <- erplab_read_bin_descriptor(file.path(d, "eeg", "flanker_bins.txt"))
  expect_equal(b$label, c("Error trials", "Correct trials")); expect_equal(b$bin, 1:2)
})

test_that("the eeg proposal derives columns, ids, session map, features, QC defaults and the recording block", {
  d <- eeg_fixture(); cfg <- eeg_fixture_config()
  expect_output(p <- eeg_project_read(exports = file.path(d, "eeg", "flanker_features.csv"),
                                      vhdr = file.path(d, "eeg", "*.vhdr"), vmrk = file.path(d, "eeg", "*.vmrk"),
                                      eeg_json = file.path(d, "eeg", "*_eeg.json"), participants = file.path(d, "eeg", "participants.tsv"),
                                      events = file.path(d, "eeg", "*_events.tsv"), bin_descriptor = file.path(d, "eeg", "flanker_bins.txt")),
                "BrainVision header")
  prop <- eeg_project_to_config(p, config = cfg, redcap_ids = sprintf("%04d", 1:8))
  b <- prop$config$eeg; t <- prop$todo
  expect_true(b$enabled); expect_equal(b$file_glob, "eeg/*_features.csv")
  expect_equal(b$columns$id, "subject"); expect_equal(b$columns$n_trials, "nave"); expect_equal(b$columns$value, "value")
  expect_equal(b$id_transform, list(strip_prefix = "sub-", pad_width = 3)); expect_equal(b$id_pattern, "^[0-9]{3}$")
  # 3-wide ids do not match 4-wide REDCap ids: asked, not silently accepted
  expect_true(any(t$key == "id_pattern" & t$status == "ask"))
  expect_equal(b$session_map, list(`ses-01` = "baseline", `ses-02` = "week12"))
  expect_true(any(t$key == "session_map.ses-02" & t$status == "inferred" & grepl("position 2", t$note)))
  expect_setequal(unlist(b$qc$required_channels), c("FCz", "Cz"))     # Pz missing for sub-003
  expect_equal(length(b$features), 2)
  expect_setequal(vapply(b$features, function(f) f$name, character(1)), c("mean_amplitude_error", "mean_amplitude_correct"))
  expect_true(any(t$key == "features.*.window_ms" & t$status == "ask"))
  expect_true(any(t$key == "qc.amplitude_range_uv" & t$status == "default"))
  expect_equal(b$qc$amplitude_range_uv[1] %% 10, 0)
  expect_true(any(t$key == "qc.min_trials" & t$status == "default")); expect_true(b$qc$min_trials >= 12)
  r <- b$recording
  expect_equal(r$sampling_rate_hz, 500L); expect_equal(r$n_channels, 3L); expect_match(r$amplifier, "BrainAmp")
  expect_equal(r$hardware_filters$high_cutoff_hz, 1000); expect_equal(r$powerline_hz, 60); expect_equal(r$cap, "Easycap")
  expect_match(r$source, "sub-001_ses-01_task-flanker_eeg.vhdr")
  expect_true(any(t$key == "recording.markers" & grepl("S  1 \\(30\\)", t$note)))
  expect_true(any(grepl("ERPLAB bins", t$note))); expect_true(any(grepl("BIDS events", t$note)))
  expect_output(eeg_config_report(prop), "Recording: 500 Hz")
})

test_that("a wide export is flagged rather than crosswalked, and a missing header is asked for", {
  d <- tempfile("eeg_wide_"); dir.create(d)
  wide <- tibble::tibble(subject = c("sub-001", "sub-002"), session = "ses-01", condition = "error",
                         FCz = c(-5.1, -4.2), Cz = c(-4.0, -3.9), Pz = c(-2.2, -2.5), Fz = c(-3, -3))
  readr::write_csv(wide, file.path(d, "wide_features.csv"))
  p <- eeg_project_read(exports = file.path(d, "wide_features.csv"))
  prop <- eeg_project_to_config(p)
  expect_true(any(prop$todo$key == "format" & prop$todo$status == "ask" & grepl("WIDE", prop$todo$note)))
  expect_null(prop$config$eeg$features)
  expect_true(any(prop$todo$key == "recording" & prop$todo$status == "ask"))
  expect_error(eeg_project_read(exports = file.path(d, "nothing_*.csv")), "nothing to read")
})

test_that("headers that disagree on sampling rate are asked about", {
  d <- eeg_fixture()
  j <- file.path(d, "eeg", "sub-001_ses-01_task-flanker_eeg.json")
  writeLines(jsonlite::toJSON(list(SamplingFrequency = 1000, EEGReference = "Cz"), auto_unbox = TRUE), j)
  p <- eeg_project_read(exports = file.path(d, "eeg", "flanker_features.csv"), vhdr = file.path(d, "eeg", "*.vhdr"), eeg_json = j)
  prop <- eeg_project_to_config(p, config = eeg_fixture_config())
  expect_true(any(prop$todo$key == "recording.sampling_rate_hz" & prop$todo$status == "ask" & grepl("1000", prop$todo$note)))
})
