# Tests for the dashboard codebook PDF layout parser. The fixture is the
# text pdftools returns for a real dashboard export (columns drift a little
# between pages, long variable codes wrap over two or three lines, the
# breakdown clips codes at the page edge, and LIKERT rows have no format
# cell), reduced to two surveys and a handful of questions.

pdf_fixture_lines <- function() c(
  "FARM Codebook",
  "Study Information",
  "Study Name                                FARM",
  "Public Enrollment Link                    http://my.metricwire.com/studies/info/68092a1444566d69bc13a59c",
  "Participants Invited                                      40",
  "Survey Information",
  "Survey Name / Type               Trigger Name / Type      Questions                        Responses",
  "Morning / MOBILE                 Number of Triggers: 2    5                                0",
  "Afternoon & Evening /            Number of Triggers: 1    3                                0",
  "MOBILE",
  "Survey Information for Morning",
  "Question Level Response Variables",
  "Question                    Variable Name             Format      Position   Question Type    Choices: Coded Value",
  "Right now, where are you?                AM_Loc_1744980522641    Character   18   SINGLE_CHOICE    - Home : 1",
  "                                                                                                   - Farm : 2",
  "In the last 2 hours, have you            quest_1728477997567_1   Character   19   MULTIPLE_CHOIC   - Cannabis : 1",
  "consumed any of the following?           744980522645                             E                - Alcohol : 2",
  "                                                                                                   - Other Stimulants (e.g.",
  "                                                                                                   Cocaine) : 3",
  "How would you rate the quality of        quest_1720033132962_1   Character   20   SLIDING_SCALE    -1",
  "your sleep last night?&nbsp;             744980522645                                              -2",
  "                                                                                                   -3",
  "Right now, I feel like what I'm doing is   quest_1720185943156_1   21   LIKERT        -0",
  "worthwhile                                 744981503048                               -1",
  "                                                                                      -2",
  "Sleep duration                           quest_1720033041807_1               22   FIELD_GROUP",
  "                                         744980522645",
  "Breakdown of Each Question",
  "Question & Settings                    Question Type                  Variable Name                    Global Variable Name",
  "1) Right now, where are you?           SINGLE_CHOICE                  AM_Loc_1744980522641             F:MB:AM_Loc",
  "     Display Conditions: None",
  "     Question Groups: None",
  "     Response Required: No",
  "Breakdown of Each Trigger",
  "Name                                               Type              Settings",
  "1) Morning Practice                                ONCE              Runs from 2025-04-18T00:00:00 UNTIL",
  "                                                                     2026-04-18T00:00:00.000Z",
  "2) Morning Trigger (Weekdays)                      schedule          false",
  "Question & Settings                    Question Type                  Variable Name                    Global Variable Name",
  "2) In the last 2 hours, have you consumed   MULTIPLE_CHOICE    quest_1728477997567_1744980522645    F:M",
  "any of the following?",
  "     Display Conditions: None",
  "     Question Groups: None",
  "     Response Required: No",
  "Question & Settings                    Question Type                  Variable Name                    Global Variable Name",
  "3) How would you rate the quality of your         SLIDING_SCALE    quest_1720033132962_1744980522645    F:M",
  "     Display Conditions: If In the last 2 hours, have you consumed any of the following? IS Alcohol",
  "     Question Groups: None",
  "     Response Required: Yes",
  "Question & Settings                    Question Type                  Variable Name                    Global Variable Name",
  "4) Right now, I feel like what I'm doing is       LIKERT           quest_1720185943156_1744981503048    F:M",
  "     Display Conditions: None",
  "     Question Groups: None",
  "     Response Required: No",
  "Question & Settings                    Question Type                  Variable Name                    Global Variable Name",
  "5) Sleep duration                                 FIELD_GROUP      quest_1720033041807_1744980522645    F:M",
  "     Display Conditions: None",
  "     Question Groups: None",
  "     Response Required: No",
  "Survey Information for Afternoon & Evening",
  "Question Level Response Variables",
  "Question                    Variable Name             Format      Position   Question Type    Choices: Coded Value",
  "Right now, where are you?                AM_Loc_1744980522641    Character   18         SINGLE_CHOICE    - Home",
  "                                         _1744984140546                                                  - Farm",
  "Right now, I feel like what I'm doing is   quest_1720185943156_1   19   LIKERT        -0:1",
  "worthwhile.                                744981503048_1744984                       -1:2",
  "                                           140553                                     -2:3",
  "How meaningful did you find the          quest_1744982144945               20   LIKERT           -1:1",
  "conversation?                                                                                    -2:2",
  "Breakdown of Each Question",
  "Question & Settings                                Question Type      Variable Name                        Glo",
  "1) Right now, where are you?                       SINGLE_CHOICE      AM_Loc_1744980522641_1744984140546",
  "  Display Conditions: None",
  "  Question Groups: None",
  "Breakdown of Each Trigger",
  "Name                                               Type              Settings",
  "1) Afternoon Trigger                               schedule          false",
  "Question & Settings                                Question Type      Variable Name                        Glo",
  "2) Right now, I feel like what I'm doing is worthwhile.      LIKERT                                                quest_17201",
  "  Display Conditions: None",
  "  Question Groups: None",
  "Question & Settings                                Question Type      Variable Name                        Glo",
  "3) How meaningful did you find the                LIKERT                                                quest_1744982144945",
  "  Display Conditions: If Right now, where are you? IS Farm",
  "  Question Groups: Social"
)

test_that("layout parser reads wrapped codes, LIKERT rows without a format, and drifting columns", {
  cb <- parse_metricwire_codebook_lines(pdf_fixture_lines())
  expect_equal(nrow(cb), 8)
  expect_setequal(cb$quest_code, c("AM_Loc_1744980522641", "quest_1728477997567_1744980522645", "quest_1720033132962_1744980522645",
                                   "quest_1720185943156_1744981503048", "quest_1720033041807_1744980522645",
                                   "AM_Loc_1744980522641_1744984140546", "quest_1720185943156_1744981503048_1744984140553", "quest_1744982144945"))
  m <- cb[cb$quest_code == "quest_1728477997567_1744980522645", ]
  expect_equal(m$question_type, "MULTIPLE_CHOICE"); expect_equal(m$n_options, 3L); expect_equal(c(m$response_min, m$response_max), c(1, 3))
  expect_match(m$response_options, "Other Stimulants \\(e.g. Cocaine\\) : 3")
  expect_equal(m$item_text, "In the last 2 hours, have you consumed any of the following?")
  s <- cb[cb$quest_code == "quest_1720033132962_1744980522645", ]
  expect_equal(s$item_text, "How would you rate the quality of your sleep last night?")   # &nbsp; gone, no digits leaked
  expect_equal(c(s$response_min, s$response_max), c(1, 3))
  w1 <- cb[cb$quest_code == "quest_1720185943156_1744981503048", ]; w2 <- cb[cb$quest_code == "quest_1720185943156_1744981503048_1744984140553", ]
  expect_equal(c(w1$response_min, w1$response_max), c(0, 2))      # -0 -1 -2: numeric labels are the codes
  expect_equal(c(w2$response_min, w2$response_max), c(1, 3))      # -0:1 -1:2 -2:3: coded 1-based in the second survey
  expect_equal(unique(cb$survey_name[grepl("140546|140553|1744982144945$", cb$quest_code)]), "Afternoon & Evening")
  expect_true(all(is.na(cb$format[cb$question_type %in% c("LIKERT", "FIELD_GROUP")])))
})

test_that("breakdown gives display conditions by rank even when the code is clipped; triggers and summary parse", {
  cb <- parse_metricwire_codebook_lines(pdf_fixture_lines())
  expect_equal(cb$display_condition[cb$quest_code == "quest_1720033132962_1744980522645"],
               "If In the last 2 hours, have you consumed any of the following? IS Alcohol")
  expect_equal(cb$response_required[cb$quest_code == "quest_1720033132962_1744980522645"], "Yes")
  expect_equal(cb$display_condition[cb$quest_code == "quest_1744982144945"], "If Right now, where are you? IS Farm")
  expect_equal(cb$question_group[cb$quest_code == "quest_1744982144945"], "Social")
  expect_equal(cb$display_condition[cb$quest_code == "quest_1720185943156_1744981503048_1744984140553"], "None")  # clipped code, matched by rank
  st <- attr(cb, "study"); expect_equal(st$study_id, "68092a1444566d69bc13a59c"); expect_equal(st$participants_invited, 40L)
  sv <- attr(cb, "surveys"); expect_equal(sv$survey_name, c("Morning", "Afternoon & Evening")); expect_equal(sv$type, c("MOBILE", "MOBILE")); expect_equal(sv$n_questions, c(5L, 3L))
  tr <- attr(cb, "triggers"); expect_equal(nrow(tr), 3); expect_equal(tr$type, c("ONCE", "schedule", "schedule"))
  expect_equal(tr$trigger_name[2], "Morning Trigger (Weekdays)")
})

test_that("mw_base_code and mw_resolve_gates", {
  expect_equal(mw_base_code(c("quest_1_2_3", "quest_17", "AM_Loc_1744980522641_1744984140546")), c("quest_1", "quest_17", "AM_Loc_1744980522641"))
  iu <- tibble::tibble(name = c("where", "meaningful", "other"),
                       item_text = c("Right now, where are you?", "How meaningful did you find the conversation?", "x"),
                       display_condition = c(NA, "If Right now, where are you? IS Farm", "If Something unknown IS 1"))
  g <- mw_resolve_gates(iu)
  expect_null(g[[1]]); expect_equal(g[[2]], list(item = "where", equals = "Farm", negate = FALSE)); expect_equal(g[[3]], "If Something unknown IS 1")
})

test_that("codebook-only proposal from a parsed CSV with canonical names: gates, per-survey coding conflict, time and select-all fields", {
  d <- tempfile("mwpdf_"); dir.create(d)
  cb <- tibble::tibble(
    survey_name = c("Morning", "Morning", "Morning", "Morning", "Afternoon", "Afternoon"),
    quest_code = c("AM_Loc_1_555", "quest_10_555", "quest_11_555", "quest_12_555", "quest_10_555_777", "quest_12_555_777"),
    item_text = c("Right now, where are you?", "Right now, I feel like what I'm doing is worthwhile", "Yesterday, what time did you go to sleep?",
                  "In the last 2 hours, have you consumed any of the following?", "Right now, I feel like what I'm doing is worthwhile", "In the last 2 hours, have you consumed any of the following?"),
    question_type = c("SINGLE_CHOICE", "LIKERT", "TIME", "MULTIPLE_CHOICE", "LIKERT", "MULTIPLE_CHOICE"),
    response_min = c(1, 0, NA, 1, 1, 1), response_max = c(3, 4, NA, 9, 5, 9),
    response_options = c("- Home : 1; - Farm : 2; - Other : 3", NA, NA, "- Cannabis : 1; - Alcohol : 2", NA, "- Cannabis : 1; - Alcohol : 2"),
    display_condition = c("None", "If Right now, where are you? IS Farm", "None", "None", "If Right now, where are you? IS Farm", "None"),
    canonical_name = c("location", "worthwhile", "bedtime", "substances", "worthwhile", "substances"))
  readr::write_csv(cb, file.path(d, "cb.csv"), na = "")
  writeLines("userId,AM_Loc_1_555,quest_10_555,quest_11_555,quest_12_555", file.path(d, "m.csv"))
  writeLines("userId,quest_10_555_777,quest_12_555_777", file.path(d, "a.csv"))
  p <- metricwire_project_read(config = list(metricwire = list(sessions = list(s1 = list(analysis_id = "a")))),
                               codebooks = list(s1 = file.path(d, "cb.csv")),
                               import_templates = list(Morning = file.path(d, "m.csv"), Afternoon = file.path(d, "a.csv")))
  prop <- metricwire_project_to_config(p, id_pattern = "^[0-9]{4}$")
  mw <- prop$config$metricwire; t <- prop$todo
  nm <- vapply(mw$ema_items, function(i) i$name, character(1))
  expect_setequal(nm, c("location", "worthwhile"))                       # time and select-all are not scored items
  w <- mw$ema_items[[which(nm == "worthwhile")]]
  expect_equal(w$quest_code, "quest_10"); expect_setequal(unlist(w$raw), c("quest_10_555", "quest_10_555_777"))  # one item, two survey columns
  expect_equal(w$range, c(0L, 4L))
  expect_equal(w$gate, list(item = "location", equals = "Farm", negate = FALSE))
  expect_true(any(t$key == "ema_items.worthwhile.range" & t$status == "ask" & grepl("Morning 0-4; Afternoon 1-5", t$note)))
  expect_false(any(grepl("coded differently", t$note[t$key == "ema_items.substances.range"])))   # identical coding is no conflict
  expect_equal(vapply(mw$time_fields, function(i) i$name, character(1)), "bedtime")
  expect_equal(vapply(mw$multi_select_fields, function(i) i$name, character(1)), "substances")
  expect_setequal(unlist(mw$prompt_blocks$s1$morning), c("location", "worthwhile"))
  expect_setequal(unlist(mw$prompt_blocks$s1$afternoon), "worthwhile")
  expect_true(any(t$key == "ema_items.worthwhile.gate" & t$status == "derived"))
  expect_false(any(t$key == "ema_items.*.gate"))
})

test_that("mw_column_to_code matches the export's lower-cased columns to the codebook's casing", {
  codes <- c("AM_Loc_1744980522641", "quest_1720030660782_1744980522641")
  cols <- c("am_loc_1744980522641", "am_loc_1744980522641_1744984140546",
            "quest_1720030660782_1744980522641", "quest_9999")
  out <- mw_column_to_code(cols, codes)
  expect_equal(out[1], "AM_Loc_1744980522641")            # janitor lower-cased it
  expect_equal(out[2], "AM_Loc_1744980522641")            # survey copy of the same question
  expect_equal(out[3], "quest_1720030660782_1744980522641")
  expect_true(is.na(out[4]))
})

test_that("a column whose values are all INFORMATION_QUESTION is an information screen, not an item", {
  d <- tempfile("mwinfo_"); dir.create(d)
  cb <- tibble::tibble(quest_code = c("quest_10", "quest_11"),
                       item_text = c("Right now, how upset are you?", NA),
                       question_type = c("LIKERT", NA), response_min = c(0, NA), response_max = c(4, NA),
                       canonical_name = c("upset", NA))
  readr::write_csv(cb, file.path(d, "cb.csv"), na = "")
  dat <- tibble::tibble(response_type = rep("submitted", 4), user_id = c("1001", "1002", "1003", "1004"),
                        quest_10 = c("0", "2", "4", "1"),
                        quest_11 = rep("INFORMATION_QUESTION", 4),   # field-group screen
                        quest_12 = c("3600", "7200", "10800", "0"))  # a real unnamed child
  readr::write_csv(dat, file.path(d, "data.csv"))
  p <- metricwire_project_read(config = list(metricwire = list(sessions = list(s1 = list(analysis_id = "a")))),
                               data = list(s1 = file.path(d, "data.csv")), codebooks = list(s1 = file.path(d, "cb.csv")))
  prop <- metricwire_project_to_config(p, id_pattern = "^[0-9]{4}$")
  nm <- vapply(prop$config$metricwire$ema_items, function(i) i$name, character(1))
  expect_true("upset" %in% nm)
  expect_false("quest_11" %in% nm)                       # the screen is dropped
  expect_true("quest_12" %in% nm)                        # the unnamed child is kept
  expect_true(any(prop$todo$key == "ema_items.information" & grepl("quest_11", prop$todo$note)))
})
