# The sensors block is proposed from the exports: vendor preambles,
# table shape, column names, and the wear-time distribution.

sensor_fixture <- function(dir = tempfile("sensor_meta_"), seed = 9) {
  set.seed(seed); dir.create(file.path(dir, "sensor"), recursive = TRUE, showWarnings = FALSE)
  # ActiGraph daily summary with the standard preamble, one file per participant
  for (id in c("0001", "0002")) {
    pre <- c(paste0("------------ Data File Created By ActiGraph wGT3X-BT ActiLife v6.13.4 Firmware v1.9.2 date format M/d/yyyy at 60 second epoch -----------"),
             paste0("Serial Number: MOS2D", id), "Start Time 09:00:00", "Start Date 2/1/2025", "Epoch Period (hh:mm:ss) 00:01:00",
             "Download Time 10:15:00", "Download Date 3/15/2025", "Current Memory Address: 0", "Current Battery Voltage: 4.12     Mode = 61",
             "--------------------------------------------------")
    days <- 40
    tab <- tibble::tibble(`Subject Name` = id, Date = format(as.Date("2025-02-01") + 0:(days - 1), "%m/%d/%Y"),
                          Axis1 = stats::rpois(days, 300000), Steps = stats::rpois(days, 6500),
                          `Wear Time (min)` = c(sample(300:590, 8, TRUE), sample(600:1440, days - 8, TRUE)), Calories = round(stats::runif(days, 1800, 2600)))
    writeLines(c(pre, readr::format_csv(tab)), file.path(dir, "sensor", paste0(id, "_actigraph_daily.csv")))
  }
  # GENEActiv-style header block then an epoch table
  ge <- c("Device Identity", "Device Type,GENEActiv", "Device Model,1.2", "Device Unique Serial Code,047521",
          "Device Firmware Version,Ver06.17", "", "Configuration Info", "Measurement Frequency,100 Hz", "Start Time,2025-02-01 09:00:00:000",
          "Time Zone,GMT -05:00", "", "Subject Info", "Subject Code,0003", "", "Recorded Data")
  ep <- expand.grid(ts = format(as.POSIXct("2025-02-01 00:00:00", tz = "UTC") + seq(0, by = 3600, length.out = 24 * 5), "%Y-%m-%d %H:%M:%S"), stringsAsFactors = FALSE)
  ep$subject_code <- "0003"; ep$x <- round(stats::rnorm(nrow(ep)), 3); ep$y <- round(stats::rnorm(nrow(ep)), 3); ep$z <- round(stats::rnorm(nrow(ep)), 3); ep$lux <- stats::rpois(nrow(ep), 50)
  writeLines(c(ge, readr::format_csv(ep[, c("subject_code", "ts", "x", "y", "z", "lux")])), file.path(dir, "sensor", "0003_geneactiv_epoch.csv"))
  # Fitbit-like sleep summary, plain table
  sl <- tibble::tibble(participant_id = rep(c("0001", "0002"), each = 10), date = rep(format(as.Date("2025-02-01") + 0:9, "%Y-%m-%d"), 2),
                       minutes_asleep = sample(c(0, 300:520), 20, TRUE), sleep_efficiency = sample(70:98, 20, TRUE))
  readr::write_csv(sl, file.path(dir, "sensor", "fitbit_sleep.csv"))
  # AWARE-like phone accelerometer: device id, ms epoch timestamp, UTC
  aw <- tibble::tibble(device_id = rep(c("0001", "0002"), each = 200),
                       timestamp = as.character(rep(as.numeric(as.POSIXct("2025-02-01", tz = "UTC")) * 1000 + seq(0, by = 600000, length.out = 200), 2)),
                       double_values_0 = round(stats::rnorm(400), 3), double_values_1 = round(stats::rnorm(400), 3), double_values_2 = round(stats::rnorm(400), 3))
  readr::write_csv(aw, file.path(dir, "sensor", "aware_accelerometer.csv"))
  dir
}

test_that("column and metric vocabularies match vendor names", {
  d <- sensor_detect_columns(c("Subject Name", "Date", "Axis1", "Steps", "Wear Time (min)", "Calories"))
  expect_equal(d$columns$id, "Subject Name"); expect_equal(d$columns$date, "Date")
  expect_equal(d$metrics$steps, "Steps"); expect_equal(d$metrics$wear_minutes, "Wear Time (min)"); expect_equal(d$metrics$activity_counts, "Axis1")
  d2 <- sensor_detect_columns(c("device_id", "timestamp", "double_values_0", "double_values_1", "double_values_2"))
  expect_equal(d2$columns$id, "device_id"); expect_equal(d2$columns$timestamp, "timestamp"); expect_equal(d2$metrics$accel_x, "double_values_0")
  expect_equal(length(d2$unmatched), 0)
})

test_that("ActiGraph and GENEActiv preambles parse and the table starts after them", {
  d <- sensor_fixture()
  r <- sensor_read_export(file.path(d, "sensor", "0001_actigraph_daily.csv"))
  pre <- attr(r, "preamble")
  expect_equal(pre$vendor, "ActiGraph"); expect_equal(pre$info$serial, "MOS2D0001"); expect_equal(pre$info$epoch_seconds, 60)
  expect_equal(pre$info$start_date, "2/1/2025"); expect_true(attr(r, "header_present"))
  expect_true(all(c("Subject Name", "Date", "Steps") %in% names(r))); expect_equal(nrow(r), 40)
  g <- sensor_read_export(file.path(d, "sensor", "0003_geneactiv_epoch.csv"))
  gp <- attr(g, "preamble")
  expect_equal(gp$vendor, "GENEActiv"); expect_equal(gp$info$serial, "047521"); expect_equal(gp$info$measurement_frequency_hz, 100)
  expect_equal(gp$info$tz_offset, "GMT -05:00"); expect_equal(gp$info$subject_code, "0003")
  expect_true(all(c("subject_code", "ts", "lux") %in% names(g))); expect_equal(nrow(g), 120)
  f <- sensor_read_export(file.path(d, "sensor", "fitbit_sleep.csv"))
  expect_equal(attr(f, "preamble")$vendor, "plain")
})

test_that("grain detection: day, epoch with gaps, and ms epoch timestamps", {
  d <- sensor_fixture()
  a <- sensor_read_export(file.path(d, "sensor", "0001_actigraph_daily.csv"))
  expect_equal(sensor_detect_grain(a, sensor_detect_columns(names(a))$columns)$grain, "day")
  g <- sensor_read_export(file.path(d, "sensor", "0003_geneactiv_epoch.csv"))
  gr <- sensor_detect_grain(g, sensor_detect_columns(names(g))$columns)
  expect_equal(gr$grain, "epoch"); expect_equal(gr$epoch_seconds, 3600)
  w <- sensor_read_export(file.path(d, "sensor", "aware_accelerometer.csv"))
  gw <- sensor_detect_grain(w, sensor_detect_columns(names(w))$columns)
  expect_equal(gw$grain, "epoch"); expect_equal(gw$epoch_seconds, 600)
  expect_equal(format(parse_sensor_time("1738368000000")[1], "%Y-%m-%d"), "2025-02-01")
})

test_that("the sensors proposal derives streams, grain, metrics, rules, devices and asks for tz", {
  d <- sensor_fixture()
  expect_output(p <- sensor_project_read(files = list(accel = file.path(d, "sensor", "*_actigraph_daily.csv"),
                                                      geneactiv = file.path(d, "sensor", "0003_geneactiv_epoch.csv"),
                                                      sleep = file.path(d, "sensor", "fitbit_sleep.csv"),
                                                      phone = file.path(d, "sensor", "aware_accelerometer.csv"))), "vendor ActiGraph")
  prop <- sensor_project_to_config(p)
  s <- prop$config$sensors; t <- prop$todo
  expect_true(s$enabled); expect_equal(s$tz, "TODO"); expect_true(any(t$key == "tz" & t$status == "ask"))
  a <- s$streams$accel
  expect_equal(a$grain, "day"); expect_equal(a$file_glob, "sensor/*_actigraph_daily.csv")
  expect_equal(a$columns, list(id = "Subject Name", date = "Date"))
  expect_equal(a$metrics$wear_minutes, "Wear Time (min)"); expect_equal(a$valid_day_rule, "wear_minutes >= 600")
  expect_true(any(t$key == "streams.accel.valid_day_rule" & t$status == "default" & grepl("keeps 80%", t$note)))
  expect_equal(a$device$vendor, "ActiGraph"); expect_setequal(unlist(a$device$serials), c("MOS2D0001", "MOS2D0002")); expect_equal(a$device$epoch_seconds, 60)
  expect_equal(a$id_transform, list(pad_width = 4)); expect_equal(a$id_pattern, "^[0-9]{4}$")
  g <- s$streams$geneactiv
  expect_equal(g$grain, "epoch"); expect_equal(g$epoch_seconds, 0.01)     # preamble frequency wins over the hourly table gaps
  expect_equal(g$columns$timestamp, "ts"); expect_equal(g$aggregate$light, "mean"); expect_equal(g$aggregate$accel_x, "mean")
  expect_true(any(t$key == "tz" & grepl("GMT -05:00", t$note)))
  expect_equal(g$valid_day_rule, "TODO")
  sl <- s$streams$sleep
  expect_equal(sl$grain, "day"); expect_equal(sl$metrics$sleep_minutes, "minutes_asleep"); expect_equal(sl$valid_day_rule, "sleep_minutes > 0")
  ph <- s$streams$phone
  expect_equal(ph$grain, "epoch"); expect_equal(ph$epoch_seconds, 600); expect_equal(ph$columns$id, "device_id")
  expect_equal(ph$aggregate$accel_x, "mean")
  expect_equal(nrow(prop$streams), 4)
  expect_output(sensor_config_report(prop), "To confirm")
})

test_that("streams are discovered from a raw/sensor directory and merged into a proposal", {
  d <- sensor_fixture()
  p <- sensor_project_read(raw_dir = file.path(d, "sensor"))
  expect_equal(length(p$streams), 4)   # two ActiGraph files share a column set -> one stream
  prop <- sensor_project_to_config(p, config = list(sensors = list(tz = "America/New_York")))
  expect_equal(prop$config$sensors$tz, "America/New_York")
  expect_false(any(prop$todo$key == "tz" & prop$todo$status == "ask" & grepl("local time zone", prop$todo$note)))
  a <- list(config = list(study = list(name = "x")), todo = tibble::tibble(section = "study", key = "n", status = "ask", note = ""), source = "files")
  m <- merge_proposals(a, prop)
  expect_true(m$config$sensors$enabled)
  dd <- tempfile("proj_"); dir.create(dd)
  expect_output(write_proposed_config(m, dir = dd), "Wrote")
  back <- yaml::read_yaml(file.path(dd, "_config.proposed.yml"))
  expect_equal(back$sensors$tz, "America/New_York")
})
