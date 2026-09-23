# minimum_valid_items = ceiling(prop * n_items). Rounding up is the rule: a
# participant may miss one item only when the remainder still clears prop.

thr_cfg <- function(...) {
  list(instruments = list(...))
}
instr <- function(n, min_valid) {
  list(items_in_order = paste0("q", seq_len(n)), minimum_valid_items = min_valid)
}

test_that("the rule is ceiling(0.8 * n) across scale lengths", {
  cfg <- thr_cfg(twenty = instr(20, 16), twelve = instr(12, 10),
                 five = instr(5, 4), four = instr(4, 4), three = instr(3, 3))
  out <- suppressMessages(check_scoring_thresholds(cfg))
  expect_true(all(out$ok))
  expect_equal(out$expected, c(16L, 10L, 4L, 4L, 3L))
  # A short scale needs every item, because 3 of 4 is 75% and does not clear 80%.
  expect_equal(out$full_scale, c(FALSE, FALSE, FALSE, TRUE, TRUE))
})

test_that("a loosened threshold is an error naming the instrument", {
  cfg <- thr_cfg(pss = instr(4, 3), ucla = instr(20, 16))
  expect_error(check_scoring_thresholds(cfg),
               "pss: declared 3 of 4, rule says 4")
  # ... and the passing instrument is not named in the error
  expect_error(check_scoring_thresholds(cfg), "1 instrument\\(s\\) deviate")
})

test_that("strict = FALSE reports instead of stopping", {
  cfg <- thr_cfg(pss = instr(4, 3))
  expect_output(out <- check_scoring_thresholds(cfg, strict = FALSE), "deviate")
  expect_false(out$ok)
})

test_that("prop comes from validation$min_valid_prop when set", {
  cfg <- thr_cfg(ten = instr(10, 7))
  cfg$validation <- list(min_valid_prop = 0.7)
  out <- suppressMessages(check_scoring_thresholds(cfg))
  expect_true(all(out$ok))
  # The same config fails against the 0.8 default.
  cfg$validation <- NULL
  expect_error(check_scoring_thresholds(cfg), "rule says 8")
})

test_that("a missing minimum_valid_items is a deviation, not a pass", {
  cfg <- thr_cfg(x = list(items_in_order = paste0("q", 1:6)))
  expect_error(check_scoring_thresholds(cfg), "declared NA of 6")
})

test_that("instruments without items, and an empty config, are no-ops", {
  # cat() writes to stdout, so this is expect_output, not expect_silent.
  expect_output(check_scoring_thresholds(list()), "No instruments configured")
  out <- suppressMessages(check_scoring_thresholds(thr_cfg(x = list(items_in_order = character(0)))))
  expect_equal(nrow(out), 0)
})

test_that("an out-of-range prop stops", {
  expect_error(check_scoring_thresholds(thr_cfg(x = instr(4, 4)), prop = 0), "prop must be")
  expect_error(check_scoring_thresholds(thr_cfg(x = instr(4, 4)), prop = 1.5), "prop must be")
})
