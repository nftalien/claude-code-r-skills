# Verification gates

What the person is shown at each stage, what right looks like, what wrong
looks like, and what to say. Read before reading any render, and in Mode D.

## Reading a render

1. Confirm it is new (render date in the header, or a checksum) and that it
   is the stage you expect.
2. `summarise_render_log()` on the console text: quote every `⚠️` and `⏭`
   line verbatim. A `⏭` is a skipped step; say whether skipping was expected.
3. Read every `•` ID audit line. `distinct` should match the roster (or the
   modality's expected count); `format-fail` should be zero; `missing`
   should be zero at ingest.
4. Go to the stage's row below. Name the numbers and the picture, say what
   they should look like, and say whether they do.
5. Then, and only then, tell the person what to do: approve, or what to fix.

Never write "looks good". Write what was checked and what it showed.

## Stage by stage

### 00_setup
**Shown**: package version, config echo, timepoint schedule table, secrets
guard result.
**Right**: fearlabr >= 0.2.0; the schedule matches the protocol's schedule of
assessments; no field looks like a token.
**Wrong**: a window overlap message (the config check fired); a timepoint the
person does not recognise; a version below 0.2.0.

### 00b_pipeline_status
**Shown**: DAG coloured by status, status table, coverage dashboard.
**Right**: the stages present are the ones the plan listed and no others; the
approved set is exactly what the person approved; the dashboard, once
populated, shows each modality only at the timepoints it is expected.
**Wrong**: a modality's stages missing (config flag off); a stage approved
that they did not approve (someone ran `force = TRUE`; ask).

### 01_ingest, 01e_ingest_eeg, 01s_ingest_sensor
**Shown**: file list, ID audit lines, row and participant counts, raw
distributions (01e), observed-day tiles (01s), session-to-timepoint table
(01e).
**Right**: the newest export was read; `format-fail: 0`; participants equal
the roster or the modality's known N; every EEG session maps; sensor date
ranges match the study calendar; value scales match the units claimed.
**Wrong**: `format-fail` > 0 (crosswalk or `id_transform`); an unmapped
session; EEG values banded around zero (volts exported as microvolts or the
reverse); a sensor stream whose last date is the same for everyone (export
truncated); `⚠️ n value(s) were not numeric` (a text sentinel in the export).

### 02_validate
As fearlabr-pipeline: required columns, duplicate keys, event
reconciliation, dictionary diff, linkage overlap.

### 02e_qc_eeg
**Shown**: the three thresholds printed; QC tile (participant × timepoint);
flagged table; feature table summary; feature distributions.
**Right**: flags are the sessions the lab already knows were bad; feature
means and spreads are on the scale the component literature reports (an ERN
of a few microvolts negative, not fifty); `assert_expected_n` did not fire.
**Wrong**: all orange (a threshold in the wrong units); all blue on real
data with known bad sessions (thresholds too loose, or `n_trials` absent so
the trial floor cannot fire; check the crosswalk); a feature column all NA
(cannot happen, the stage stops, but if the stop message names the feature
the condition or channel label in the config does not match the export).

### 02s_qc_sensor
**Shown**: the rule printed per stream; valid-day tile; per-participant
coverage table; timepoint coverage.
**Right**: the printed rule is the protocol's; orange runs are device gaps
the team knows about; `pct_under_7_valid` is small; every participant has an
anchor date.
**Wrong**: the anchors warning (03 has not run, or `anchor_date_column` is
wrong); nearly every day valid on a wrist device (rule too loose, or
`wear_minutes` mapped to the wrong column); days assigned to no timepoint
when they should be (windows too narrow for a continuous stream; consider
whether the study wants continuous coverage rather than windowed).

### 03_clean_redcap
As fearlabr-pipeline, plus the timepoint completeness table (participant ×
timepoint for REDCap) which must agree with the event counts.

### 05_clean_ema
As fearlabr-pipeline, plus the compliance heatmap. **Right**: missed prompts
present as light cells. **Wrong**: no light cells at all on real data
(missed rows were dropped upstream; compliance will read 100%).

### 07_link_redcap_ema, 07m_link_modalities
**Shown**: ID audit per source; ID format inventory; overlap summary;
only-in-each list; participant × timepoint index; coverage dashboard;
linked table column list.
**Right**: one ID length and shape across every source; only-in-each is a
list the person can account for name by name; `has_<modality>` columns match
the coverage files; the linked row count equals the index row count.
**Wrong**: two ID lengths in the format table (a padding or prefix drift; fix
`id_transform`, not the data); a modality with `only_here` equal to its N
(nothing joined; the key is wrong); `assert_expected_n` firing on the link
(a many-to-many key: a modality table with more than one row per participant
× timepoint reached the join without aggregation).

### 07c_id_audit
As fearlabr-pipeline. The UpSet intersections should reproduce the coverage
dashboard's story.

### 08_feasibility, 10_outcomes_models
As fearlabr-pipeline Mode E. Validation-gate blockquotes state expected
values; the render must land inside them or the deviation must be explained
in the notebook, not in the chat.

## Saying it

A gate message has four parts, in this order: what was checked (the lines
and numbers by name), what it showed, what is wrong if anything and the
smallest fix, and the ask ("approve with `builder_approve("02e_qc_eeg")`" or
"re-render 02e after the config change"). Quote log lines; do not paraphrase
them.

## Mode D: the render stopped

1. Mark the stage failed with the error text as the note.
2. The stop message names the function and, for the modules, the config key.
   Go to that key first.
3. Print one instance (a row of the export, the config block) before
   changing anything (fearlabr-pipeline `diagnostic-discipline.md`).
4. Fix in the smallest place: config, then the notebook, then the module
   with a regression test.
5. Say which stages to re-render. A config change resets from the first
   stage that reads the block.
