# The metricwire block is read from the analysis data, the codebook and the
# choicesDataCoding export, and every derived value carries a status.

mw_fixture <- function(dir = tempfile("mw_meta_"), n = 10, days = 6, seed = 3) {
  set.seed(seed); dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  ids <- 5001:(5000 + n)
  make_session <- function(with_missed) {
    grid <- expand.grid(id = ids, d = seq_len(days), p = 1:3, KEEP.OUT.ATTRS = FALSE)
    nr <- nrow(grid)
    submitted <- if (with_missed) stats::runif(nr) < 0.8 else rep(TRUE, nr)
    src <- ifelse(grid$p == 1, "Morning Survey", "Random Prompt")
    df <- data.frame(
      `Response Id` = sprintf("R%05d", seq_len(nr)),
      `Response Type` = ifelse(submitted, "Submission", "Missed"),
      `Source Name` = src,
      `User.FirstName` = ifelse(stats::runif(nr) < 0.9, as.character(grid$id), ""),
      `User.LastName` = ifelse(stats::runif(nr) < 0.1, as.character(grid$id), "Smith"),
      `User.Id` = sprintf("%024x", grid$id),
      `Survey Started Date` = format(as.Date("2025-02-01") + grid$d - 1, "%d/%m/%Y"),
      studyId = "657b7b3c1a3052fc06c77099",
      check.names = FALSE, stringsAsFactors = FALSE)
    aff <- function() ifelse(submitted, sample(0:4, nr, TRUE), NA)
    df$quest_101 <- aff(); df$quest_102 <- aff(); df$quest_103 <- aff()
    df$quest_110 <- ifelse(submitted, sample(0:1, nr, TRUE), NA)
    df$quest_111 <- ifelse(submitted & df$quest_110 == 1, sample(0:4, nr, TRUE), NA)
    df$quest_120 <- ifelse(submitted & src == "Morning Survey", sample(0:4, nr, TRUE), NA)   # coding says 1-5
    df$quest_130 <- ifelse(submitted & stats::runif(nr) < 0.3, paste("Day note", seq_len(nr)), NA)
    df$quest_140 <- ifelse(submitted, sample(0:4, nr, TRUE, prob = c(.8, .1, .05, .03, .02)), NA)
    df
  }
  readr::write_csv(make_session(TRUE), file.path(dir, "period_1_api_raw.csv"), na = "")
  readr::write_csv(make_session(FALSE), file.path(dir, "period_2_api_raw.csv"), na = "")
  cb <- tibble::tibble(
    quest_code = paste0("quest_", c(101, 102, 103, 110, 111, 120, 130, 140)),
    item_text = c("How much do you feel afraid right now?", "How much do you feel nervous right now?",
                  "How much do you feel upset right now?", "Since the last prompt, did a stressful event happen?",
                  "How stressful was it?", "I was able to resist temptation this morning",
                  "Anything else about your day?", "Right now, how much are you having thoughts of hurting yourself?"),
    item_stem = c(rep("How much do you feel ... right now?", 3), NA, NA, NA, NA, NA),
    item_choice = c("Afraid", "Nervous", "Upset", NA, NA, NA, NA, NA),
    question_type = c(rep("RANGE_SCALE", 3), "SINGLE_CHOICE", "RANGE_SCALE", "RANGE_SCALE", "TEXT", "RANGE_SCALE"),
    response_min = c(0, 0, 0, 0, 0, 1, NA, 0), response_max = c(4, 4, 4, 1, 4, 5, NA, 4),
    survey_name = c(rep("Random Prompt", 5), "Morning Survey", "Random Prompt", "Random Prompt"))
  readr::write_csv(cb, file.path(dir, "codebook_items.csv"), na = "")
  coding <- tibble::tibble(
    questionId = paste0("quest_", c(101, 102, 103, 110, 120)),
    choicesDataCoding = c(rep('{"Not at all":0,"A little":1,"Somewhat":2,"Very":3,"Extremely":4}', 3),
                          "No=0;Yes=1", '{"Not at all":1,"A little":2,"Somewhat":3,"Very":4,"Very much":5}'))
  readr::write_csv(coding, file.path(dir, "choices_coding.csv"))
  dir
}
mw_fixture_project <- function(dir = mw_fixture(), with_coding = TRUE) {
  metricwire_project_read(
    config = list(redcap = list(id_column = "record_id"),
                  metricwire = list(workspace_id = "ws1", sessions = list(
                    period_1 = list(analysis_id = "a1", analysis_name = "Period 1"),
                    period_2 = list(analysis_id = "a2", analysis_name = "Period 2")))),
    data = list(period_1 = file.path(dir, "period_1_api_raw.csv"), period_2 = file.path(dir, "period_2_api_raw.csv")),
    codebooks = list(period_1 = file.path(dir, "codebook_items.csv"), period_2 = file.path(dir, "codebook_items.csv")),
    coding = if (with_coding) list(period_1 = file.path(dir, "choices_coding.csv"), period_2 = file.path(dir, "choices_coding.csv")) else NULL)
}

test_that("names, question columns, coding strings and slugs parse", {
  expect_equal(mw_snake(c("User.FirstName", "Response Type", "quest_120", "studyId")),
               c("user_first_name", "response_type", "quest_120", "study_id"))
  df <- tibble::tibble(response_type = 1, user_first_name = 1, quest_101 = 1, quest_102 = 1)
  expect_equal(mw_question_columns(df), c("quest_101", "quest_102"))
  df2 <- tibble::tibble(response_type = 1, source_name = 1, afraid = 1, nervous = 1)
  expect_equal(mw_question_columns(df2), c("afraid", "nervous"))
  p <- mw_parse_coding('{"Not at all":0,"A little":1}')
  expect_equal(p$code, c(0, 1)); expect_equal(p$label, c("Not at all", "A little"))
  expect_equal(mw_parse_coding("No=0;Yes=1")$code, c(0, 1))
  expect_equal(mw_parse_coding("0=No | 1=Yes")$label, c("No", "Yes"))
  expect_equal(nrow(mw_parse_coding(NA)), 0)
  expect_equal(mw_item_slug("How much do you feel afraid right now?", "Afraid"), "afraid")
  expect_equal(mw_item_slug("Since the last prompt, did a stressful event happen?"), "stressful_event_happen")
  expect_equal(mw_match_columns(c("quest_101", "quest_120"), c("quest_101", "Resist temptation...120")),
               c("quest_101", "Resist temptation...120"))
})

test_that("readers: analysis data, codebook CSV, choicesDataCoding", {
  d <- mw_fixture()
  df <- metricwire_read_analysis_data(file.path(d, "period_1_api_raw.csv"))
  expect_true(all(c("response_type", "source_name", "user_first_name", "quest_101") %in% names(df)))
  expect_type(df$quest_101, "character")
  cb <- metricwire_read_codebook(file.path(d, "codebook_items.csv"))
  expect_equal(nrow(cb), 8); expect_equal(cb$response_max[6], 5)
  cod <- metricwire_read_choices_coding(file.path(d, "choices_coding.csv"))
  expect_equal(range(cod$code[cod$quest_code == "quest_120"]), c(1, 5))
  expect_equal(nrow(cod[cod$quest_code == "quest_110", ]), 2)
  bad <- tempfile(fileext = ".csv"); writeLines("a,b\n1,2", bad)
  expect_error(metricwire_read_choices_coding(bad), "choicesDataCoding")
})

test_that("project read gathers sessions, codebooks and coding; files path", {
  expect_output(p <- mw_fixture_project(), "period_1: .* rows from period_1_api_raw.csv")
  expect_equal(p$source, "files")
  expect_equal(p$sessions$key, c("period_1", "period_2"))
  expect_equal(p$sessions$analysis_id, c("a1", "a2"))
  expect_setequal(names(p$codebooks), c("period_1", "period_2"))
  expect_error(metricwire_project_read(config = NULL, data = NULL), "no sessions")
})

test_that("the proposal derives sessions, the Missed check, items, ranges, blocks, safety, free text and the ID field", {
  p <- mw_fixture_project()
  prop <- metricwire_project_to_config(p, config = list(redcap = list(id_column = "record_id"),
                                                        metricwire = list(workspace_id = "ws1", oauth_id_key = "osu")),
                                       id_pattern = "^[0-9]{4}$")
  mw <- prop$config$metricwire; t <- prop$todo
  expect_true(mw$enabled); expect_equal(mw$workspace_id, "ws1"); expect_equal(mw$redcap_link_field, "record_id")
  expect_equal(names(mw$sessions), c("period_1", "period_2"))
  expect_equal(mw$sessions$period_1$analysis_id, "a1")
  # C1: period_2 has no Missed rows
  expect_true(any(t$key == "sessions.period_2" & t$status == "ask" & grepl("NO Missed", t$note)))
  expect_true(any(t$key == "sessions.period_1.missed_rows" & t$status == "derived"))
  # Items: names from the codebook, free text out, safety candidate found
  nm <- vapply(mw$ema_items, function(i) i$name, character(1))
  expect_setequal(nm, c("afraid", "nervous", "upset", "stressful_event_happen", "stressful",
                        "able_resist_temptation_morning", "thoughts_hurting_yourself"))
  expect_equal(unlist(mw$free_text_fields), "anything_else_day")
  expect_equal(mw$safety_items[[1]]$name, "thoughts_hurting_yourself")
  expect_null(mw$safety_items[[1]]$safety_min)
  expect_true(any(t$key == "safety_items" & t$status == "ask"))
  # Ranges: coding wins (derived); codebook only (inferred); coding 1-5 vs observed 0-4 (ask, C2)
  afraid <- mw$ema_items[[which(nm == "afraid")]]
  expect_equal(afraid$range, c(0L, 4L)); expect_equal(afraid$quest_code, "quest_101")
  expect_true(any(t$key == "ema_items.afraid.range" & t$status == "derived"))
  expect_true(any(t$key == "ema_items.stressful.range" & t$status == "inferred"))
  expect_true(any(t$key == "ema_items.able_resist_temptation_morning.range" & t$status == "ask" & grepl("OBSERVED 0-4", t$note)))
  # Prompt blocks (C3): the morning item is carried by Morning Survey only
  expect_equal(unlist(afraid$prompts), c("Morning Survey", "Random Prompt"))
  resist <- mw$ema_items[[which(nm == "able_resist_temptation_morning")]]
  expect_equal(unlist(resist$prompts), "Morning Survey")
  expect_true("able_resist_temptation_morning" %in% unlist(mw$prompt_blocks$period_1$morning_survey))
  expect_false("able_resist_temptation_morning" %in% unlist(mw$prompt_blocks$period_1$random_prompt))
  # Gated item answered on ~half the prompts is still carried at the 0.5 threshold or flagged; either way gates are asked
  expect_true(any(t$key == "ema_items.*.gate" & t$status == "ask"))
  # ID field: first name matches 90%; last name matches ~10%
  expect_equal(mw$id_column, "user_first_name")
  expect_true(any(t$key == "id_column" & grepl("also matches in user_last_name", t$note)))
  expect_equal(mw$id_range, c(5001L, 5010L))
  expect_true(any(t$key == "battery_map" & t$status == "ask"))
  # Detail tables
  expect_equal(prop$sessions$n_missed[2], 0)
  expect_equal(nrow(prop$items), 8)
})

test_that("without coding, ranges come from the codebook and are marked inferred", {
  prop <- metricwire_project_to_config(mw_fixture_project(with_coding = FALSE), id_pattern = "^[0-9]{4}$")
  t <- prop$todo
  expect_true(any(t$key == "ema_items.afraid.range" & t$status == "inferred"))
  # codebook says 1-5 for the morning item, data is 0-4: still caught
  expect_true(any(t$key == "ema_items.able_resist_temptation_morning.range" & t$status == "ask"))
})

test_that("API path: sessions pulled through the transport and studies listed", {
  d <- mw_fixture()
  pulled <- character(0)
  fake_pull <- function(config, key) { pulled <<- c(pulled, key); readr::read_csv(file.path(d, paste0(key, "_api_raw.csv")), show_col_types = FALSE, col_types = readr::cols(.default = "c")) }
  fake_get <- function(url, token) { expect_match(url, "/studies/ws1$"); '[{"id":"s1","name":"Health and Home Safety"},{"id":"s2","name":"Health and Home Safety"}]' }
  cfg <- list(redcap = list(id_column = "record_id"),
              metricwire = list(base_url = "https://example.test", workspace_id = "ws1",
                                oauth_id_service = "svc", oauth_id_key = "k", oauth_secret_service = "svc", oauth_secret_key = "s",
                                sessions = list(period_1 = list(analysis_id = "a1", analysis_name = "P1"),
                                                period_2 = list(analysis_id = "a2", analysis_name = "P2"))))
  withr::local_envvar(METRICWIRE_CLIENT_ID = "id", METRICWIRE_CLIENT_SECRET = "secret")
  p <- metricwire_project_read(cfg, codebooks = list(period_1 = file.path(d, "codebook_items.csv")),
                               studies = NULL, .pull = fake_pull,
                               .get = function(url, token) fake_get(url, token))
  skip_if_not(is.data.frame(p$studies) || is.null(p$studies))
  expect_equal(p$source, "api")
  expect_equal(pulled, c("period_1", "period_2"))
  expect_equal(p$sessions$read_from, c("api", "api"))
})

test_that("merge_proposals combines a REDCap and a MetricWire proposal and writes cleanly", {
  a <- list(config = list(study = list(name = "x"), metricwire = list(enabled = FALSE)),
            todo = tibble::tibble(section = "study", key = "name", status = "ask", note = "n"), source = "files")
  b <- metricwire_project_to_config(mw_fixture_project(), id_pattern = "^[0-9]{4}$")
  m <- merge_proposals(a, b)
  expect_true(m$config$metricwire$enabled)
  expect_equal(m$config$study$name, "x")
  expect_equal(nrow(m$todo), 1 + nrow(b$todo))
  d <- tempfile("proj_"); dir.create(d)
  expect_output(write_proposed_config(m, dir = d), "Wrote")
  back <- yaml::read_yaml(file.path(d, "_config.proposed.yml"))
  expect_equal(back$metricwire$ema_items[[1]]$name, "afraid")
  expect_output(metricwire_config_report(b), "NO Missed rows")
})
