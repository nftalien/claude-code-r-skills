# Shared config for the modality-module tests. Absolute raw_data path so the
# tests never touch a project tree.
builder_test_config <- function(raw_dir = tempfile("raw_")) {
  dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)
  list(
    study = list(name = "BUILD", target_n = 6),
    paths = list(raw_data = raw_dir),
    redcap = list(id_column = "id", randomization_field = "randomize",
                  events = list(baseline = list(raw = "baseline_arm_1", assessment = TRUE),
                                week4 = list(raw = "week_4_arm_1", assessment = TRUE))),
    conditions = list(list(code = "a", redcap_value = 1), list(code = "b", redcap_value = 2)),
    instruments = list(),
    metricwire = list(enabled = FALSE),
    timepoints = list(
      anchor = "baseline",
      schedule = list(
        baseline = list(label = "Baseline", offset_days = 0, window_days = c(-7, 7),
                        redcap_event = "baseline_arm_1",
                        modalities = c("redcap", "ema", "eeg", "sensors")),
        week4 = list(label = "Week 4", offset_days = 28, window_days = c(-3, 7),
                     redcap_event = "week_4_arm_1",
                     modalities = c("redcap", "eeg", "sensors")),
        week12 = list(label = "Week 12", offset_days = 84, window_days = c(-7, 14),
                      redcap_event = "week_12_arm_1", modalities = c("redcap"))
      )
    ),
    eeg = list(
      enabled = TRUE, format = "long", file_glob = "eeg/*_features.csv",
      columns = list(id = "subject", session = "ses", channel = "chan",
                     condition = "cond", measure = "meas", value = "val", n_trials = "ntr"),
      id_transform = list(strip_prefix = "sub-", pad_width = 4),
      id_pattern = "^[0-9]{4}$",
      session_map = list(`ses-01` = "baseline", `ses-02` = "week4"),
      features = list(
        list(name = "ern", measure = "mean_amplitude", condition = "error",
             channels = c("FCz", "Cz"), window_ms = c(0, 100)),
        list(name = "crn", measure = "mean_amplitude", condition = "correct",
             channels = c("FCz", "Cz"), window_ms = c(0, 100))),
      qc = list(min_trials = 6, amplitude_range_uv = c(-50, 50),
                required_channels = c("FCz", "Cz"))
    ),
    sensors = list(
      enabled = TRUE, tz = "America/New_York",
      streams = list(
        accel = list(label = "Wrist actigraphy", file_glob = "sensor/*_accel.csv",
                     grain = "day", columns = list(id = "participant_id", date = "day"),
                     metrics = list(steps = "step_count", wear_minutes = "wear_min"),
                     valid_day_rule = "wear_minutes >= 600",
                     id_transform = list(pad_width = 4), id_pattern = "^[0-9]{4}$"),
        hr = list(label = "Heart rate epochs", file_glob = "sensor/*_hr.csv",
                  grain = "epoch", columns = list(id = "pid", timestamp = "ts"),
                  metrics = list(hr = "bpm", wear_minutes = "wear"),
                  aggregate = list(hr = "mean", wear_minutes = "sum"),
                  valid_day_rule = "wear_minutes >= 2",
                  id_transform = list(pad_width = 4), id_pattern = "^[0-9]{4}$")
      )
    )
  )
}
