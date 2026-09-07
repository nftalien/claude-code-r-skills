# `condition` is a reserved output name of clean_redcap(): every downstream
# stage reads it as the randomised arm. These tests pin the two ways that used
# to break far from their cause.

crc_config <- function() {
  cfg <- builder_test_config()
  cfg$instruments <- list(
    demo = list(
      items_in_order      = c("q1", "q2"),
      item_range          = c(1, 5),
      total_range         = c(2, 10),
      minimum_valid_items = 1L
    )
  )
  cfg$validation <- list(redcap_calc_tolerance = 0.001)
  cfg
}

crc_data <- function(..., n = 2) {
  ids <- sprintf("%02d", seq_len(n))
  base <- tibble::tibble(
    id                = rep(ids, each = 2),
    redcap_event_name = rep(c("baseline_arm_1", "week_4_arm_1"), times = n),
    q1                = 3L,
    q2                = 4L,
    randomize         = rep(c(1L, 2L), each = 2)[seq_len(n * 2)]
  )
  extra <- list(...)
  for (nm in names(extra)) base[[nm]] <- extra[[nm]]
  base
}

test_that("condition is mapped from the randomisation field", {
  out <- clean_redcap(crc_data(), crc_config())
  expect_true("condition" %in% names(out$assessment_level))
  expect_setequal(unique(out$participant_level$condition), c("a", "b"))
  expect_true("condition" %in% names(out$analysis_wide))
})

test_that("a study field named `condition` is moved aside, not collided with", {
  dat <- crc_data(condition = c(9L, 9L, 8L, 8L))

  expect_output(
    out <- clean_redcap(dat, crc_config()),
    "already has a column named 'condition'"
  )

  # No .x/.y suffixes anywhere, and `condition` holds the arm, not the field.
  expect_false(any(grepl("^condition\\.[xy]$", names(out$assessment_level))))
  expect_true("condition_redcap_raw" %in% names(out$assessment_level))
  expect_setequal(unique(out$participant_level$condition), c("a", "b"))
  expect_setequal(unique(out$participant_level$condition_redcap_raw), c(9L, 8L))
  expect_true("condition" %in% names(out$analysis_wide))
})

test_that("a missing randomisation field degrades to NA with a warning, not a select() error", {
  dat <- crc_data()
  dat$randomize <- NULL

  expect_output(
    out <- clean_redcap(dat, crc_config()),
    "is not in the export"
  )
  expect_true("condition" %in% names(out$assessment_level))
  expect_true(all(is.na(out$assessment_level$condition)))
  expect_true("condition" %in% names(out$analysis_wide))
})

test_that("two randomisation values for one participant is an error", {
  dat <- crc_data()
  dat$randomize <- c(1L, 2L, 2L, 2L)   # id "01" randomised twice

  expect_error(
    clean_redcap(dat, crc_config()),
    "more than one value"
  )
})
