# Repairs to participant identifiers are study decisions, so they are declared
# in a file with reasons and applied loudly, never inferred or done in silence.

write_repairs <- function(rows) {
  p <- tempfile(fileext = ".csv"); readr::write_csv(rows, p, na = ""); p
}

test_that("read_id_repairs validates the log and refuses the dangerous shapes", {
  ok <- tibble::tibble(from_id = "1023_error", to_id = "1023", source = "metricwire",
                       reason = "id mistyped at app enrolment", decided_by = "PI", decided_on = "2026-09-06")
  expect_output(r <- read_id_repairs(write_repairs(ok)), "id repairs declared: 1")
  expect_equal(nrow(r), 1); expect_equal(r$to_id, "1023")

  expect_output(expect_equal(nrow(read_id_repairs(tempfile())), 0), "No id_repairs.csv")

  expect_error(read_id_repairs(write_repairs(dplyr::mutate(ok, source = "qualtrics"))), "unknown source")
  expect_error(read_id_repairs(write_repairs(dplyr::mutate(ok, reason = NA))), "needs a reason")
  expect_error(read_id_repairs(write_repairs(dplyr::mutate(ok, to_id = "1023_error"))), "maps an id to itself")
  expect_error(read_id_repairs(write_repairs(dplyr::bind_rows(ok, dplyr::mutate(ok, to_id = "1024")))), "repaired twice")
  # repairing to an id nobody has just moves the problem
  expect_error(read_id_repairs(write_repairs(ok), known_ids = c("1021", "1022")), "do not exist in the roster")
  expect_silent(suppressMessages(invisible(capture.output(read_id_repairs(write_repairs(ok), known_ids = c("1022", "1023"))))))
})

test_that("apply_id_repairs rewrites only the named source and says what it did", {
  reps <- tibble::tibble(from_id = c("1023_error", "0007"), to_id = c("1023", "7"),
                         source = c("metricwire", "any"), reason = c("mistyped at enrolment", "zero padded"),
                         decided_by = NA_character_, decided_on = NA_character_)
  mw <- tibble::tibble(study_id = c("1023_error", "1023", "0007", "1030"), x = 1:4)
  expect_output(out <- apply_id_repairs(mw, reps, "study_id", "metricwire"), "1023_error' -> '1023'  1 row")
  expect_setequal(out$study_id, c("1023", "1023", "7", "1030"))
  expect_equal(sum(out$study_id == "1023"), 2)          # the repaired rows join the participant's own

  rc <- tibble::tibble(record_id = c("0007", "1030"), y = 1:2)
  out2 <- apply_id_repairs(rc, reps, "record_id", "redcap")   # only the "any" repair applies
  expect_setequal(out2$record_id, c("7", "1030"))

  # a repair that matches nothing is called out, not silently ignored
  expect_output(apply_id_repairs(tibble::tibble(study_id = "1030"), reps, "study_id", "metricwire"),
                "matched no rows")
  expect_equal(apply_id_repairs(mw, reps[0, ], "study_id", "metricwire"), mw)
})
