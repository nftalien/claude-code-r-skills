# Example MetricWire metadata

What `scripts/derive_ema_config.R` reads, in the shapes it expects. All
fictional, generated to the API's column names after `clean_names()`.

- `period_1_api_raw.csv`, `period_2_api_raw.csv`: one analysis export each,
  as `01_ingest` caches them under `data/raw/`. `period_2` was exported with
  Submissions only, so the derivation flags it (lesson C1: compliance would
  read 100%).
- `codebook_items.csv`: the parsed codebook, in the shape
  `build_ema_codebook()` writes (`quest_code`, `item_text`, `item_choice`,
  `question_type`, `response_min`, `response_max`, `survey_name`). The
  dashboard's codebook PDF can be passed directly instead; it is parsed with
  `parse_metricwire_codebook()`.
- `choices_coding.csv`: one row per item with its `choicesDataCoding`, the
  ground truth for each item's numeric scale. `quest_120` is coded 1-5 here
  while the data runs 0-4, so the derivation asks (lesson C2) rather than
  writing a range that would null every 0.

What the derivation reads from these: the sessions and whether each has
Missed rows; every question column, its codebook text and a proposed
canonical name; declared range (coding, then codebook) beside the observed
range; which survey names carry which items; free-text items; items whose
wording suggests a safety item; and which account field holds the
participant ID. Gates, the battery-to-condition map and safety thresholds
are always asked.
