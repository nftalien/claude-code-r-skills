# Booleans where labels should be, and REDCap fields that reuse fearlabr's
# output names, are caught before any render.

test_that("assert_config_labels stops on YAML booleans in labels and option values", {
  yml <- c("metricwire:", "  items:", "    - name: inperson_contact", "      options:",
           "        - value: 0", "          label: No", "        - value: 1", "          label: Yes",
           "instruments:", "  phq9:", "    label: PHQ-9")
  f <- tempfile(fileext = ".yml"); writeLines(yml, f)
  cfg <- yaml::read_yaml(f)
  expect_true(is.logical(cfg$metricwire$items[[1]]$options[[1]]$label))
  expect_error(assert_config_labels(cfg), "2 config element")
  expect_error(assert_config_labels(cfg), "metricwire\\$items\\$\\[1\\]\\$options\\$\\[1\\]\\$label")

  # Quoted labels pass; so does a config written by yaml::write_yaml()
  writeLines(sub("label: (Yes|No)$", 'label: "\\1"', yml), f)
  expect_silent(assert_config_labels(yaml::read_yaml(f)))
  yaml::write_yaml(list(items = list(list(options = list(list(value = 1L, label = "Yes"))))), f)
  expect_silent(assert_config_labels(yaml::read_yaml(f)))
})

test_that("assert_config_labels ignores booleans that are meant to be booleans", {
  cfg <- list(metricwire = list(enabled = TRUE), eeg = list(enabled = FALSE),
              instruments = list(x = list(reverse_coded = list(), scored = TRUE)))
  expect_silent(assert_config_labels(cfg))
})

test_that("reserved output columns are the ones clean_redcap writes", {
  expect_true(all(c("condition", "wave", "study_id") %in% fearlabr_reserved_columns()))
})
