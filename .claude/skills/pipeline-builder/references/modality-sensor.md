# Passive sensor / actigraphy modality contract

## Scope

Streams that arrive as tables over time from a device or a phone: wrist
actigraphy daily summaries (ActiGraph, GENEActiv, Fitbit, Garmin, Oura
exports), phone accelerometry or step epochs, sleep summaries, GPS-derived
mobility summaries, heart-rate epochs. The module produces one table per
stream at **participant-day** grain, marks each day valid or not by a rule the
study declares, reports coverage, and assigns days to the declared timepoints
through each participant's anchor date.

Not in scope: raw accelerometer signal processing (use the device vendor's
or GGIR's day-level output), GPS trace processing (import the derived
mobility metrics), within-day analysis (aggregate to day here; a
within-day stage would be a new grain and a new stage).

## Grain

- **day**: the export already has one row per participant-day. The date
  column is parsed with `Ymd`, `dmY`, `mdY` orders; a row whose date fails to
  parse is dropped with a `⚠️` count. Duplicate participant-days across two
  files are averaged and counted (`n_source_rows > 1`) with a `⚠️` line.
- **epoch**: many rows per day with a timestamp. Timestamps are parsed in
  `sensors.tz` and turned into a **local** calendar date by formatting in
  that zone. Never `as.Date()` on a POSIXct: it ignores the tzone and moved a
  fifth of one study's evening events to the next day. Epochs are then
  aggregated per metric by `aggregate` (`sum` for counts and minutes, `mean`
  for rates, `max`/`min` if needed).

## Config

See `assets/config-modality-blocks.yml`. One entry per stream under
`sensors.streams`; canonical metric names are the ones the rule and 07m use.

The **valid-day rule** is the analytic decision and lives in config as a
string over the canonical metrics: `"wear_minutes >= 600"`,
`"wear_minutes >= 600 & steps > 0"`, `"sleep_minutes > 0 & efficiency >= 50"`.
02s prints it verbatim. NA evaluates to not valid. Pick it from the protocol
or the lab's prior paper; if neither states one, propose the field's common
value and mark `# TODO confirm`.

## Timepoints for a continuous stream

Days are assigned to a timepoint when they fall inside that timepoint's
window relative to the participant's anchor date. For a stream worn
continuously, most days will fall outside every window and carry
`timepoint = NA`; that is correct, and coverage at a timepoint means "at least
one valid day inside the window". If the study wants continuous coverage
(valid days per week over the whole study), that is a per-study `R/` helper
on the `_day_valid` table, not a change to the windows.

## Stages

**01s_ingest_sensor**: per stream, files → `ingest_sensor_stream()` →
`<stem>_sensor_<stream>_day_latest.rds` under `data/raw/`; observed-day
tile; date ranges.

**02s_qc_sensor**: anchors from the participant-level file
(`timepoints.anchor_date_column`); per stream `sensor_valid_days()` with the
rule printed, `sensor_coverage()` → `<stem>_sensor_<stream>_coverage.csv`,
valid-day tile, `link_sensor_to_timepoints()` →
`<stem>_sensor_<stream>_day_valid_latest.rds` under `data/derived/`;
timepoint coverage across streams → `<stem>_coverage_sensors.csv`.

**07m_link_modalities** aggregates each stream's valid days inside each
timepoint window (mean of each metric, count of valid days) and joins them as
`<stream>_<metric>` and `<stream>_n_valid_days`.

## Failure modes

| Symptom | Cause | Where |
|---|---|---|
| `lacks column(s)` | vendor renamed a column in a newer export | `columns`, `metrics` |
| `format-fail` > 0 | device ID is not the study ID (a serial number, an email) | a roster crosswalk in `R/`, then `id_transform` |
| many `unparseable date` rows | Excel serial dates, or a timestamp in a day-grain stream | `grain`, or convert at export |
| `n_source_rows > 1` on many days | overlapping exports (a re-export that includes old days) | keep one export per period under the glob |
| nearly every day valid | wrong wear column, or the rule is too loose | `metrics.wear_minutes`, `valid_day_rule` |
| no day in any timepoint | anchors missing or windows narrow | `anchor_date_column`; run 03 first |
| a stream skipped with `⏭` | glob matched nothing | `file_glob`, file location |

## Extending the module

A within-day stage (hourly bins for an EMA-adjacent analysis) is a new grain
(`hour`) with its own aggregation and a new file stem; it belongs after 02s
and joins to EMA prompts on participant and local hour. A device-ID roster
(`sensors.streams.<k>.roster: metadata/device_roster.csv`) mapping device
serials to study IDs is the first extension a real study is likely to need
and is a small addition to `ingest_sensor_stream()` before the ID transform,
with a test that a serial not in the roster is reported, not dropped.
