# The config proposal is read from REDCap, not retyped. These tests pin what
# is derived, what is inferred from names, what is defaulted, and what is
# left as a question, on both the file path and the API path.

fixture_dir <- function() {
  # The skill ships the fixtures under assets/example-redcap-metadata; the
  # tests carry a copy so the package tests stand alone.
  d <- tempfile("redcap_meta_"); dir.create(d)
  dict <- c(
    '"Variable / Field Name","Form Name","Section Header","Field Type","Field Label","Choices, Calculations, OR Slider Labels","Field Note","Text Validation Type OR Show Slider Number","Text Validation Min","Text Validation Max","Identifier?","Branching Logic (Show field only if...)","Required Field?","Custom Alignment","Question Number (surveys only)","Matrix Group Name","Matrix Ranking?","Field Annotation"',
    '"record_id","demographics","","text","Record ID","","","","","","","","","","","","",""',
    '"email","demographics","","text","Email","","","email","","","y","","","","","","",""',
    '"consent_date","demographics","","text","Consent date","","","date_ymd","","","","","","","","","",""',
    '"demo_age","demographics","","text","Age","","","integer","18","99","","","","","","","",""',
    '"demo_sex","demographics","","radio","Sex","0, Male | 1, Female","","","","","","","","","","","",""',
    '"randomize","randomization","","radio","Condition","1, Intervention | 2, Control","","","","","","","","","","","",""',
    paste0('"phq_', 1:9, '","phq9","","radio","PHQ","0, Not at all | 1, Several days | 2, More than half | 3, Nearly every day","","","","","","","","","","","",""'),
    '"phq9_total","phq9","","calc","PHQ-9 total","[phq_1]+[phq_2]+[phq_3]+[phq_4]+[phq_5]+[phq_6]+[phq_7]+[phq_8]+[phq_9]","","","","","","","","","","","",""',
    paste0('"ius', 1:12, '","ius12","","radio","IUS","1, a | 2, b | 3, c | 4, d | 5, e","","","","","","","","","","","",""'),
    '"ius_prospective_subscale","ius12","","calc","P","[ius1]+[ius2]+[ius4]+[ius5]+[ius8]+[ius9]+[ius11]","","","","","","","","","","","",""',
    '"ius_inhibitory_subscale","ius12","","calc","I","[ius3]+[ius6]+[ius7]+[ius10]+[ius12]","","","","","","","","","","","",""',
    '"ius_total","ius12","","calc","T","[ius1]+[ius2]+[ius3]+[ius4]+[ius5]+[ius6]+[ius7]+[ius8]+[ius9]+[ius10]+[ius11]+[ius12]","","","","","","","","","","","",""',
    '"audit_1","audit","","radio","A1","0, Never | 1, Monthly | 2, Weekly | 3, Often | 4, Daily","","","","","","","","","","","",""',
    '"audit_2","audit","","radio","A2","0, a | 1, b | 2, c | 3, d | 4, e","","","","","","[audit_1] > 0","","","","","",""',
    '"audit_3","audit","","radio","A3","0, a | 1, b | 2, c | 3, d | 4, e","","","","","","[audit_1] > 0","","","","","",""',
    '"audit_slider","audit","","slider","A4","","","","","","","","","","","","",""',
    '"audit_notes","audit","","notes","Notes","","","","","","","","","","","","",""'
  )
  writeLines(dict, file.path(d, "dict.csv"))
  writeLines(c("event_name,arm_num,day_offset,offset_min,offset_max,unique_event_name,custom_event_label",
               "Enrollment,1,0,0,0,enrollment_arm_1,", "Baseline,1,0,0,0,baseline_arm_1,",
               "Week 4,1,28,3,7,week_4_arm_1,", "6 Month,1,0,0,0,6_month_arm_1,"),
             file.path(d, "events.csv"))
  writeLines(c("arm_num,unique_event_name,form", "1,enrollment_arm_1,demographics", "1,enrollment_arm_1,randomization",
               "1,baseline_arm_1,phq9", "1,baseline_arm_1,ius12", "1,baseline_arm_1,audit",
               "1,week_4_arm_1,phq9", "1,6_month_arm_1,phq9", "1,6_month_arm_1,ius12"),
             file.path(d, "map.csv"))
  d
}
read_fixture <- function(with_map = TRUE) {
  d <- fixture_dir()
  redcap_project_read(files = list(data_dictionary = file.path(d, "dict.csv"), events = file.path(d, "events.csv"),
                                   instrument_event_map = if (with_map) file.path(d, "map.csv") else NULL))
}

test_that("human dictionary headers normalise to API names; events and mapping normalise", {
  p <- read_fixture()
  expect_equal(p$source, "files")
  expect_true(all(c("field_name", "form_name", "field_type", "select_choices_or_calculations",
                    "text_validation_type_or_show_slider_number", "identifier", "branching_logic") %in% names(p$metadata)))
  expect_equal(p$metadata$field_name[1], "record_id")
  expect_equal(p$events$day_offset, c(0, 0, 28, 0))
  expect_equal(p$events$offset_max, c(0, 0, 7, 0))
  expect_equal(nrow(p$form_event_map), 8)
  bad <- tempfile(fileext = ".csv"); writeLines("a,b\n1,2", bad)
  expect_error(redcap_normalize_dictionary(readr::read_csv(bad, show_col_types = FALSE)), "not a REDCap data dictionary")
})

test_that("choices and calc formulas parse", {
  ch <- redcap_parse_choices("1, Never | 2, Some, with comma | 3, Often")
  expect_equal(ch$code, c("1", "2", "3")); expect_equal(ch$label[2], "Some, with comma")
  expect_equal(nrow(redcap_parse_choices(NA)), 0)
  expect_equal(redcap_calc_fields("[phq_1]+[phq_2]*2"), c("phq_1", "phq_2"))
  expect_equal(infer_offset_from_name("6_month"), 180)
  expect_equal(infer_offset_from_name("week_4"), 28)
  expect_equal(infer_offset_from_name("baseline"), 0)
  expect_true(is.na(infer_offset_from_name("posttx")))
})

test_that("instruments come from the dictionary with items, ranges, calc totals and subscales", {
  p <- read_fixture()
  inst <- redcap_derive_instruments(p$metadata, id_column = "record_id")
  expect_setequal(names(inst$instruments), c("phq9", "ius12", "audit"))
  phq <- inst$instruments$phq9
  expect_equal(phq$items_in_order, paste0("phq_", 1:9))
  expect_equal(phq$item_range, c(0, 3)); expect_equal(phq$total_range, c(0, 27))
  expect_equal(phq$minimum_valid_items, 8L); expect_equal(phq$redcap_total_calc, "phq9_total")
  ius <- inst$instruments$ius12
  expect_equal(ius$redcap_total_calc, "ius_total")
  expect_setequal(names(ius$subscales), c("prospective", "inhibitory"))
  expect_equal(ius$subscales$prospective$items, c("ius1", "ius2", "ius4", "ius5", "ius8", "ius9", "ius11"))
  expect_equal(ius$subscales$inhibitory$range, c(5, 25))
  audit <- inst$instruments$audit
  expect_equal(audit$items_in_order, c("audit_1", "audit_2", "audit_3"))   # slider has another range
  expect_null(audit$redcap_total_calc)
  expect_true(any(grepl("excluded, other range: audit_slider", inst$todo$note)))
  expect_true(any(inst$todo$key == "audit.redcap_total_calc" & inst$todo$status == "ask"))
  # demographics has only 2 rangeable items and is not an instrument
  expect_false("demographics" %in% names(inst$instruments))
})

test_that("the proposal derives events, timepoints, conditions, identifiers and skips", {
  p <- read_fixture()
  prop <- redcap_project_to_config(p, study_name = "fix")
  cfg <- prop$config
  expect_equal(cfg$redcap$id_column, "record_id")
  expect_equal(names(cfg$redcap$events), c("enrollment", "baseline", "week_4", "6_month"))
  expect_equal(cfg$redcap$events$week_4$raw, "week_4_arm_1")
  expect_false(cfg$redcap$events$enrollment$assessment)   # only demographics/randomization mapped
  expect_true(cfg$redcap$events$baseline$assessment)
  sched <- cfg$timepoints$schedule
  expect_equal(names(sched), c("baseline", "week_4", "6_month"))
  expect_equal(sched$week_4$offset_days, 28); expect_equal(sched$week_4$window_days, c(-3, 7))
  expect_equal(sched$`6_month`$offset_days, 180)            # inferred from the name
  expect_equal(sched$`6_month`$window_days, c(-7, 7))       # default window
  expect_equal(cfg$timepoints$anchor, "baseline")
  expect_equal(cfg$timepoints$anchor_date_column, "consent_date")
  expect_equal(cfg$redcap$randomization_field, "randomize")
  expect_equal(vapply(cfg$conditions, function(a) a$redcap_value, numeric(1)), c(1, 2))
  expect_equal(cfg$conditions[[2]]$code, "control")
  expect_equal(unlist(cfg$deid$direct_id_columns), "email")
  expect_equal(unlist(cfg$deid$date_columns_to_shift), "consent_date")
  expect_equal(length(cfg$structural_skips), 1)
  expect_equal(cfg$structural_skips[[1]]$downstream, c("audit_2", "audit_3"))
  # The dictionary says audit_2/3 are SHOWN when [audit_1] > 0, so the skip
  # rule is the inverse: the section was skipped when audit_1 <= 0. (For codes
  # 0-4 that is audit_1 == 0, the hand-written rule in the docs -- which is why
  # copying the operator across uninverted looked harmless on this fixture.)
  expect_equal(cfg$structural_skips[[1]]$trigger_op, "<=")
  expect_equal(cfg$structural_skips[[1]]$trigger_value, "0")
  expect_equal(unlist(cfg$redcap$forms_to_pull), c("demographics", "randomization", "phq9", "ius12", "audit"))
  # The todo says what was inferred and what to ask
  t <- prop$todo
  expect_true(any(t$key == "6_month.offset_days" & t$status == "inferred"))
  expect_true(any(t$key == "week_4.offset_days" & t$status == "derived"))
  expect_true(any(t$key == "schedule.*.modalities" & t$status == "ask"))
  # The proposal is a valid timepoint declaration and can drive the synthetic generator
  expect_true(assert_timepoints_declared(cfg))
  syn <- generate_synthetic_redcap(cfg, n = 4)
  expect_true(all(c("record_id", "randomize", "phq_1", "phq9_total", "ius_total") %in% names(syn)))
  expect_equal(dplyr::n_distinct(syn$redcap_event_name), 3)
})

test_that("without a mapping every event is an assessment and the todo says so", {
  prop <- redcap_project_to_config(read_fixture(with_map = FALSE), study_name = "fix")
  expect_true(all(vapply(prop$config$redcap$events, function(e) e$assessment, logical(1))))
  expect_true(any(prop$todo$key == "events.*.assessment" & prop$todo$status == "ask"))
  # enrollment and baseline both sit at offset 0: the second is left out of the
  # schedule with an ask, and the declaration stays valid
  expect_setequal(names(prop$config$timepoints$schedule), c("enrollment", "week_4", "6_month"))
  expect_true(any(grepl("same offset", prop$todo$note) & prop$todo$status == "ask"))
  expect_true(assert_timepoints_declared(prop$config))
  # Two adjacent defaults one day apart are narrowed rather than dropped
  p2 <- read_fixture(with_map = FALSE); p2$events$day_offset[2] <- 1
  prop2 <- redcap_project_to_config(p2, study_name = "fix")
  expect_true(any(grepl("overlapped", prop2$todo$note)))
  expect_true(assert_timepoints_declared(prop2$config))
})

test_that("the API path exports each content through the transport and matches the file path", {
  d <- fixture_dir()
  seen <- character(0)
  fake_post <- function(url, body) {
    seen <<- c(seen, body$content)
    expect_equal(body$format, "csv"); expect_equal(body$token, "secret")
    switch(body$content,
      project = "project_id,project_title,is_longitudinal\n12,\"Fixture Study\",1",
      arm = "arm_num,name\n1,Arm 1",
      event = paste(readLines(file.path(d, "events.csv")), collapse = "\n"),
      formEventMapping = paste(readLines(file.path(d, "map.csv")), collapse = "\n"),
      instrument = "instrument_name,instrument_label\nphq9,\"PHQ-9\"\nius12,\"IUS-12\"\naudit,AUDIT\ndemographics,Demo\nrandomization,Rand",
      metadata = {
        dd <- readr::read_csv(file.path(d, "dict.csv"), show_col_types = FALSE, col_types = readr::cols(.default = "c"))
        dd <- redcap_normalize_dictionary(dd)
        readr::format_csv(dd)
      })
  }
  p <- redcap_project_read(url = "https://redcap.example/api/", token = "secret", .post = fake_post)
  expect_equal(p$source, "api")
  expect_setequal(seen, c("project", "arm", "event", "formEventMapping", "instrument", "metadata"))
  prop <- redcap_project_to_config(p)
  expect_equal(prop$config$study$name, "fixture_study")
  expect_equal(prop$config$study$full_name, "Fixture Study")
  expect_equal(prop$config$instruments$phq9$name, "PHQ-9")
  file_prop <- redcap_project_to_config(read_fixture(), study_name = "fixture_study")
  expect_equal(prop$config$timepoints, file_prop$config$timepoints)
  expect_equal(prop$config$instruments$ius12$subscales, file_prop$config$instruments$ius12$subscales)
  # No token and no files: a message that names both remedies
  expect_error(redcap_project_read(config = list(redcap = list(api_token_service = "x", api_token_key = "nope"))),
               "keyring")
})

test_that("write_proposed_config writes the proposal and todo and leaves _config.yml alone", {
  prop <- redcap_project_to_config(read_fixture(), study_name = "fix")
  d <- tempfile("proj_"); dir.create(d); writeLines("study:\n  name: keep", file.path(d, "_config.yml"))
  expect_output(paths <- write_proposed_config(prop, dir = d), "Wrote")
  expect_true(file.exists(file.path(d, "_config.proposed.yml")))
  expect_true(file.exists(file.path(d, "metadata", "config_todo.csv")))
  expect_equal(readLines(file.path(d, "_config.yml")), c("study:", "  name: keep"))
  back <- yaml::read_yaml(file.path(d, "_config.proposed.yml"))
  expect_equal(back$instruments$phq9$items_in_order, paste0("phq_", 1:9))
  expect_true(assert_timepoints_declared(back))
  expect_output(redcap_config_report(prop), "To confirm with the study team")
})


test_that("yes/no-only and administrative forms are weak candidates, listed not proposed", {
  p <- read_fixture()
  md <- p$metadata
  extra <- tibble::tibble(field_name = c(paste0("fid_", 1:4), paste0("mh_", 1:3)),
                          form_name = c(rep("het_fidelity_checklist_session_1", 4), rep("mental_health_history", 3)),
                          section_header = NA, field_type = c(rep("radio", 4), rep("yesno", 3)), field_label = "x",
                          select_choices_or_calculations = c(rep("1, Yes | 2, No | 3, Partial", 4), rep(NA, 3)),
                          field_note = NA, text_validation_type_or_show_slider_number = NA, text_validation_min = NA,
                          text_validation_max = NA, identifier = NA, branching_logic = NA)
  for (col in setdiff(names(md), names(extra))) extra[[col]] <- NA_character_
  md2 <- dplyr::bind_rows(md, extra[, names(md)])
  inst <- redcap_derive_instruments(md2, id_column = "record_id")
  expect_false("het_fidelity_checklist_session_1" %in% names(inst$instruments))   # administrative name
  expect_false("mental_health_history" %in% names(inst$instruments))              # yes/no only, no calc
  expect_true(all(c("phq9", "ius12", "audit") %in% names(inst$instruments)))
  expect_true(any(inst$todo$key == "het_fidelity_checklist_session_1" & grepl("not proposed", inst$todo$note)))
  expect_true(any(inst$todo$key == "mental_health_history" & grepl("yes/no", inst$todo$note)))
})

test_that("scored_forms keeps a yes/no form the study declares scored", {
  md <- tibble::tibble(
    field_name = c("record_id", paste0("pc5_", 1:5), paste0("phq_", 1:3)),
    form_name = c("ptsdpc5", rep("ptsdpc5", 5), rep("phq", 3)),
    field_type = c("text", rep("yesno", 5), rep("radio", 3)),
    field_label = field_name,
    select_choices_or_calculations = c(NA, rep(NA, 5), rep("0, Not at all | 1, Several days | 2, More than half | 3, Nearly every day", 3)),
    text_validation_type_or_show_slider_number = NA_character_, text_validation_min = NA_character_, text_validation_max = NA_character_,
    identifier = NA_character_, branching_logic = NA_character_)
  base <- redcap_derive_instruments(md, id_column = "record_id")
  expect_false("ptsdpc5" %in% names(base$instruments))
  expect_true(any(base$todo$key == "ptsdpc5" & grepl("not proposed", base$todo$note)))
  kept <- redcap_derive_instruments(md, id_column = "record_id", scored_forms = "ptsdpc5")
  expect_true("ptsdpc5" %in% names(kept$instruments))
  expect_equal(kept$instruments$ptsdpc5$n_items, 5L); expect_equal(kept$instruments$ptsdpc5$item_range, c(0L, 1L))
  expect_true(any(kept$todo$key == "ptsdpc5" & kept$todo$status == "derived" & grepl("scored_forms", kept$todo$note)))
})
