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

# ── reverse-coded items ───────────────────────────────────────────────────
# `reverse_coded` sat in every derived REDCap config and was read by nothing.

rc_rev_config <- function(reverse = c("q2")) {
  cfg <- crc_config()
  cfg$instruments <- list(
    pss = list(
      items_in_order      = c("q1", "q2"),
      item_range          = c(0, 4),
      total_range         = c(0, 8),
      minimum_valid_items = 1L,
      score_method        = "raw_sum",
      reverse_coded       = reverse
    )
  )
  cfg
}

test_that("declared items are reversed about the item range", {
  dat <- crc_data()
  dat$q1 <- 1L; dat$q2 <- 1L        # reversed q2 = 0 + 4 - 1 = 3
  out <- clean_redcap(dat, rc_rev_config())
  expect_true(all(out$assessment_level$pss_total == 4))
  # The raw item value is preserved for export and missingness reporting.
  expect_true(all(out$assessment_level$q2 == 1L))
})

test_that("no reverse_coded list leaves scoring unchanged", {
  dat <- crc_data(); dat$q1 <- 1L; dat$q2 <- 1L
  out <- clean_redcap(dat, rc_rev_config(reverse = NULL))
  expect_true(all(out$assessment_level$pss_total == 2))
})

test_that("reversal is applied before the subscale, not only the total", {
  cfg <- rc_rev_config()
  cfg$instruments$pss$subscales <- list(neg = list(items = "q2"))
  dat <- crc_data(); dat$q1 <- 1L; dat$q2 <- 1L
  out <- clean_redcap(dat, cfg)
  expect_true(all(out$assessment_level$pss_neg == 3))
})

test_that("a reverse_coded name that is not an item stops", {
  dat <- crc_data(); dat$q1 <- 1L; dat$q2 <- 1L
  expect_error(clean_redcap(dat, rc_rev_config(reverse = "q3")),
               "not in items_in_order")
})

test_that("reversal keeps out-of-range values detectable", {
  dat <- crc_data(); dat$q1 <- 1L
  dat$q2 <- c(1L, 1L, 9L, 9L)       # 9 is outside 0-4
  out <- clean_redcap(dat, rc_rev_config())
  expect_true(any(out$assessment_level$pss_n_items_oob > 0))
})

# ── mean scoring ──────────────────────────────────────────────────────────
# Some instruments are scored as the mean of their items, on the item scale
# (the Brief Aggression Questionnaire is scored 1-7 by its author).

crc_mean_config <- function() {
  cfg <- crc_config()
  cfg$instruments <- list(
    baq = list(
      items_in_order      = c("q1", "q2"),
      item_range          = c(1, 7),
      total_range         = c(1, 7),
      minimum_valid_items = 1L,
      score_method        = "mean",
      reverse_coded       = "q1",
      subscales           = list(pair = list(items = c("q1", "q2")))
    )
  )
  cfg
}

test_that("score_method 'mean' scores on the item scale", {
  dat <- crc_data(); dat$q1 <- 2L; dat$q2 <- 5L   # reversed q1 = 1+7-2 = 6
  out <- clean_redcap(dat, crc_mean_config())
  expect_true(all(out$assessment_level$baq_total == 5.5))
  expect_true(all(out$assessment_level$baq_total_in_range))
})

test_that("a subscale follows its instrument's score_method", {
  dat <- crc_data(); dat$q1 <- 2L; dat$q2 <- 5L
  out <- clean_redcap(dat, crc_mean_config())
  # prorated_sum would give 11 here; the mean is 5.5
  expect_true(all(out$assessment_level$baq_pair == 5.5))
})

test_that("a subscale can override its instrument's score_method", {
  cfg <- crc_mean_config()
  cfg$instruments$baq$subscales$pair$score_method <- "raw_sum"
  dat <- crc_data(); dat$q1 <- 2L; dat$q2 <- 5L
  out <- clean_redcap(dat, cfg)
  expect_true(all(out$assessment_level$baq_pair == 11))
  expect_true(all(out$assessment_level$baq_total == 5.5))
})

test_that("subscales still default to prorated_sum", {
  cfg <- crc_config()
  cfg$instruments$demo$subscales <- list(pair = list(items = c("q1", "q2")))
  dat <- crc_data()                              # q1 = 3, q2 = 4
  out <- clean_redcap(dat, cfg)
  expect_true(all(out$assessment_level$demo_pair == 7))
})

# ── item value recodes ────────────────────────────────────────────────────
# A response option stored at a value the measure does not use. The DUDIT
# scores its last two items 0/2/4; one project coded them 0/2/3.

crc_recode_config <- function(recode = list(q2 = list(`3` = 4))) {
  cfg <- crc_config()
  cfg$instruments <- list(
    dudit = list(
      items_in_order      = c("q1", "q2"),
      item_range          = c(0, 4),
      total_range         = c(0, 8),
      minimum_valid_items = 1L,
      score_method        = "raw_sum",
      recode              = recode
    )
  )
  cfg
}

test_that("a declared value is recoded before scoring", {
  dat <- crc_data(); dat$q1 <- 0L; dat$q2 <- 3L      # 3 scores as 4
  expect_output(out <- clean_redcap(dat, crc_recode_config()), "recoded q2")
  expect_true(all(out$assessment_level$dudit_total == 4))
  expect_true(all(out$assessment_level$q2 == 3L))    # raw column untouched
})

test_that("values outside the map are left alone", {
  dat <- crc_data(); dat$q1 <- 0L; dat$q2 <- c(0L, 2L, 3L, NA)
  out <- suppressMessages(clean_redcap(dat, crc_recode_config()))
  # 0 and 2 are not in the map and pass through; 3 becomes 4; the NA row still
  # scores, from q1 alone, because minimum_valid_items is 1.
  expect_equal(sort(out$assessment_level$dudit_total), c(0, 0, 2, 4))
})

test_that("recode runs before reversal, so reversal pivots on the real value", {
  cfg <- crc_recode_config()
  cfg$instruments$dudit$reverse_coded <- "q2"        # 0 + 4 - 4 = 0, not 0+4-3 = 1
  dat <- crc_data(); dat$q1 <- 0L; dat$q2 <- 3L
  out <- suppressMessages(clean_redcap(dat, cfg))
  expect_true(all(out$assessment_level$dudit_total == 0))
})

test_that("a recode naming a non-item stops", {
  dat <- crc_data(); dat$q1 <- 0L; dat$q2 <- 3L
  expect_error(clean_redcap(dat, crc_recode_config(list(q9 = list(`3` = 4)))),
               "not one of its items_in_order")
})

test_that("a non-numeric recode map stops", {
  dat <- crc_data(); dat$q1 <- 0L; dat$q2 <- 3L
  expect_error(clean_redcap(dat, crc_recode_config(list(q2 = list(yes = 4)))),
               "must map numeric")
})
