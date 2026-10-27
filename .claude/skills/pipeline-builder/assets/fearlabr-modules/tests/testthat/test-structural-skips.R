# Config-driven structural skips must fill downstream items only when the
# trigger says the section was legitimately skipped.

test_that("skip rule fills NA downstream items when trigger == trigger_value", {
  df <- tibble::tibble(
    audit_1 = c(0, 2, 0),
    audit_2 = c(NA, NA, 1),   # row1 skipped->0, row2 stays NA (trigger!=0), row3 keep 1
    audit_3 = c(NA, 3, NA)
  )
  cfg <- list(structural_skips = list(list(
    trigger = "audit_1", trigger_value = 0,
    downstream = c("audit_2", "audit_3"), skip_value = 0
  )))
  out <- suppressMessages(apply_structural_skip_rules(df, cfg))
  expect_equal(out$audit_2, c(0, NA, 1))
  expect_equal(out$audit_3, c(0, 3, 0))
})

test_that("first present trigger candidate wins; missing trigger is a no-op", {
  df <- tibble::tibble(mj_6mo = c(0, 1), cudit_01 = c(NA, NA))
  cfg <- list(structural_skips = list(list(
    trigger = c("cannabis_past6mos", "mj_6mo"),  # only the second exists
    trigger_value = 0, downstream = c("cudit_01"), skip_value = 0
  )))
  out <- suppressMessages(apply_structural_skip_rules(df, cfg))
  expect_equal(out$cudit_01, c(0, NA))

  # No matching trigger column -> unchanged
  df2 <- tibble::tibble(cudit_01 = c(NA, NA))
  out2 <- suppressMessages(apply_structural_skip_rules(df2, cfg))
  expect_equal(out2$cudit_01, c(NA, NA))
})

test_that("absent config block is a clean no-op", {
  df <- tibble::tibble(x = 1:3)
  expect_equal(apply_structural_skip_rules(df, list()), df)
})

# ── trigger_op ────────────────────────────────────────────────────────────
# A rule says when the section WAS SKIPPED. REDCap branching logic says the
# opposite -- when a field is SHOWN -- so derived rules carry the inverted
# operator, and applying every rule as "==" fills the floor value in for
# exactly the people who were asked.

test_that("trigger_op defaults to = so hand-written rules are unchanged", {
  df <- tibble::tibble(audit_1 = c(0, 2), audit_2 = c(NA, NA))
  cfg <- list(structural_skips = list(list(
    trigger = "audit_1", trigger_value = 0,
    downstream = "audit_2", skip_value = 0
  )))
  out <- suppressMessages(apply_structural_skip_rules(df, cfg))
  expect_equal(out$audit_2, c(0, NA))
})

test_that("trigger_op '<>' fills the rows the shown-if condition excludes", {
  # Branching: cssrs3 shown only if [cssrs2] = '1'. So cssrs3 was skipped when
  # cssrs2 != 1, and a blank cssrs3 from someone with cssrs2 == 1 stays blank.
  df <- tibble::tibble(cssrs2 = c(0, 1, 1), cssrs3 = c(NA, NA, 1))
  cfg <- list(structural_skips = list(list(
    trigger = "cssrs2", trigger_op = "<>", trigger_value = 1,
    downstream = "cssrs3", skip_value = 0
  )))
  out <- suppressMessages(apply_structural_skip_rules(df, cfg))
  expect_equal(out$cssrs3, c(0, NA, 1))

  # The un-inverted rule does the opposite, which is the bug this guards.
  cfg_wrong <- cfg
  cfg_wrong$structural_skips[[1]]$trigger_op <- "="
  out_wrong <- suppressMessages(apply_structural_skip_rules(df, cfg_wrong))
  expect_equal(out_wrong$cssrs3, c(NA, 0, 1))
})

test_that("codes are compared as numbers, not strings", {
  # "10" < "9" is TRUE as a string; as a number it is not.
  df <- tibble::tibble(g = c(9, 10), x = c(NA, NA))
  cfg <- list(structural_skips = list(list(
    trigger = "g", trigger_op = ">", trigger_value = 9,
    downstream = "x", skip_value = 0
  )))
  out <- suppressMessages(apply_structural_skip_rules(df, cfg))
  expect_equal(out$x, c(NA, 0))
})

test_that("an unknown trigger_op stops rather than guessing", {
  df <- tibble::tibble(g = 1, x = NA)
  cfg <- list(structural_skips = list(list(
    trigger = "g", trigger_op = "~=", trigger_value = 1,
    downstream = "x", skip_value = 0
  )))
  expect_error(apply_structural_skip_rules(df, cfg), "Unknown trigger_op")
})
