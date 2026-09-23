# Lessons from FARM-TOK (September 2026)

What building the FARM-TOK pipeline stage by stage taught about this skill.
Read before starting a new study, and again before generating 08, 10 or 11.
Every item below cost at least one render on the lab machine; the rule that
follows each one is what now prevents it. Where the rule is already enforced
by a script (`preflight_stage.R`, the dry-run harness) it says so; where it
is a habit, it says that too.

## What the finished pipeline looks like

FARM-TOK ended at 14 stages, 00 to 11, all approved, on fearlabr 0.2.0:

| Stage | Adds |
|---|---|
| 00, 00b | setup, status DAG |
| 01 to 03, 03b | REDCap ingest, id reconcile, clean and score, per-protocol set |
| 04, 05 | EMA prepare and score |
| 06, 07 | assessment panel, link panel to EMA |
| 07m, 07c | continuous-EMA timepoint coverage; id audit across every modality |
| 08 | feasibility against pre-registered benchmarks, progression rule |
| 10 | outcomes models (primary, secondaries, moderators, missingness), one render per subgroup |
| 11 | secondary and exploratory analyses (EMA change, within-person coupling, baseline correlates) |

Two things were added on top of the fearlabr stage set and are worth
carrying to the next study as they are:

- **An analysis registry.** `metadata/analysis_plan.yml` lists every
  analysis with an id, a status (planned, exploratory, not applicable), its
  outcome and the files it should produce. Helpers in `R/<study>_analysis_
  registry.R` open an entry, record what was produced, and close the render
  with a coverage table: complete, partial, "ran, no output (see note)", or
  MISSING. A `DAP.md` records the analytic decisions with dates. The results
  section is written from those tables in registry order.
- **Subgroup renders through Quarto params.** Stages 10 and 11 take
  `params: subgroup`; `render_stage.R <id> female` renders the same notebook
  on the subgroup, writes tables and figures under `tables/female/` and
  `figures/female/`, and suffixes every registry id with `.female`. The
  same analysis, no duplicated code, one umbrella registry entry per
  subgroup.

## Mistakes to catch on the front end

Grouped by where they are caught. "Front end" means before the person
renders: at the interview, in the config, in preflight, or in the dry run.

### At the interview and in the config

1. **Id repairs applied for the check but not for the data.** Stage 02
   listed `1023_error -> 1023` as a repair and reported it applied; 03 and 04
   rebuilt ids from the raw exports and never saw it. 07c caught it two weeks
   later as a stray id in the EMA modality. Rule: `apply_id_repairs()` runs
   in every stage that constructs ids from raw (03 for REDCap, 04 for
   MetricWire), directly after the raw read. 02 only reports. Caught by the
   07c gate (an unaccounted id fails the stage); the interview now asks.
2. **A repair target listed as a test id.** `1023_error` was also in
   `exclusions.test_ids`, so once the repair applied it would have dropped a
   real participant. Rule: the interview reads the repairs file beside `test_ids`
   (builder-interview 1); 04 stops on any clash.
3. **Stratifiers that live on another event.** The randomisation
   stratifiers (`cp_status`, `sud_status`) sit on the `randomize` event, not
   baseline, so the outcome frame had them all NA and brms removed every row
   ("All observations in the data were removed"). Rule: when the interview
   records a stratifier, record the event it is on; stage 10 reads it from
   the raw export by that event and gates at setup on all-missing.
4. **Baseline-only instruments offered as outcomes.** Several instruments
   (demographics, PC-PTSD-5) exist at baseline only. Listing one as an
   outcome produces a model with no post-baseline rows and a confusing
   error. Rule: the registry marks an outcome by the waves its instrument
   is designated on; a baseline-only instrument can be a covariate or a
   moderator, never an outcome. `farmtok_baseline_covariates()` is built
   from that list.
5. **Consent-form copies the dictionary does not know.** The live project
   had `consent_form_version_2_be6f7c`, a REDCap copy of the consent form,
   which the exported data dictionary predated. Six consent dates were
   missing for that reason. Rule: the data dictionary, instrument
   designations and events export are pulled on the same day, after the
   last form edit; the interview asks for the export date and stops on a
   form present in the designations but absent from the dictionary
   (builder-interview 0).
6. **YAML reads a bare `Yes` or `No` as a boolean.** Option labels written
   as `label: Yes` parsed as `TRUE` and every binary EMA item failed its
   range check. Rule: `yaml::write_yaml()` quotes these, hand
   edits do not, so the check is on the reading side: `preflight_stage.R`
   step 2b and `fearlabr::assert_config_labels()` (run by
   `proof_modalities.R`) stop on any label or option value that arrived as
   a boolean, with its path.
7. **A reserved output name reused as a field name.** FARM-TOK's REDCap had
   its own `condition` field (a fidelity checklist item); fearlabr writes
   the arm as `condition`. `clean_redcap()` produced `condition.x` and
   `condition.y`. Rule: `clean_redcap()` moves such a field aside
   as `<name>_redcap_raw` (tested), and `redcap_project_to_config()` now
   names every collision in the todo as an `ask` row and records the rename
   under `redcap.reserved_field_collisions`, so it is a decision at the
   interview and not a surprise at 06.
8. **REDCap branching logic is a "shown when", not a "skipped when".** All
   65 structural skip rules were inverted on the first pass, filling 0 for
   people who were asked (including C-SSRS follow-ups). Rule: `redcap_project_to_config()` inverts the
   operator when it derives a rule from branching logic (tested in
   `test-structural-skips.R`); the person still checks one rule against a
   record that was asked before accepting the set, because a hand-added
   rule has no derivation to invert it.

### At preflight and in the dry run

9. **Print then stop.** A gate that printed a summary table and then
   `stop()`ped left the person reading a partial render with the error at
   the bottom. Rule: gates before prints; `preflight_stage.R` flags a
   `stop()` that follows a `print()`/`kable()` in the same chunk.
10. **Header read as a row.** A date parser tried d/m/Y first and fell back
    only if nothing parsed; it read a column header as a row and approved
    1773 of 4633 rows by mistake. The person approved the stage. Rule:
    parsers tally which date order parses the most rows over the whole
    vector, report the tally, and stop on partial parse. Approval was
    withdrawn and the stage rebuilt. The wider rule: read the rows in the
    render, not the header, before saying a count is right.
11. **The dry run swallowed errors.** The first harness rendered with
    `error = TRUE`, so a broken chunk showed as an error box and the render
    "succeeded". Rule: `dryrun.R` renders with `knitr error = FALSE`; a
    chunk error fails the dry run.
12. **Top-level `if ... \n else` in a notebook chunk.** Parses in a function,
    fails at top level. Rule: braces on every `if` in a chunk; preflight
    parses every chunk with `parse()`.
13. **Helpers defined in `R/` looked undefined to preflight.** Stage 10 calls
    twenty helpers sourced from `R/`; preflight only knew the notebook.
    Rule: preflight counts `R/` function definitions and their formals as
    definitions, and checks calls against them.
14. **Model stages cannot dry-run on the real engine.** brms takes minutes
    per fit and the cloud session has no participant data. Rule: `dryrun/R/`
    carries test doubles for the model helpers (same signatures, return
    shaped tibbles). Re-copying `R/*.R` into the dry-run tree overwrites
    them; copy everything except the doubles.
15. **`across(all_of(named_vector))` renames the outputs.** A named vector
    passed through `all_of()` inside `across()` uses the names as the new
    column names; a second rename on top of that silently produced the
    wrong columns. Rule: rename once, and check `names()` in the dry run.
16. **An empty result left no registry row.** An analysis that ran and
    produced nothing was indistinguishable from one that never ran. Rule:
    `_plan_record()` writes an NA row with a note when outputs are empty;
    the coverage table shows "ran, no output (see note)".
17. **Subgroup paths prefixed twice.** `farmtok_sample_path()` prepended
    `female/` on every call. Rule: path helpers are idempotent; the dry run
    renders the subgroup as well as the whole sample.
18. **The subgroup banner printed the full-sample n.** `n_itt` was computed
    before the subgroup filter. Rule: every count in a banner is computed
    from the frame that follows the last filter.

### At render time on the lab machine

19. **Rendering into a OneDrive or SharePoint folder.** The sync client held
    `notebooks/.quarto` open and Quarto failed with `os error 32`. Rule: the
    repo lives at a short local path (`C:\r\<study>`), never in a synced
    folder. Written into the README.
20. **Quarto `--output` with `embed-resources` on Windows.** Fails while
    bundling. Rule: `render_stage.R` renders to Quarto's default name and
    renames after; subgroup renders get `<id>_<subgroup>.html`.
21. **Renders going to a different folder.** A raw `quarto render` call
    from the chat sent 07m to `notebooks/output/`. Rule: the person only
    ever runs `Rscript scripts/render_stage.R <id> [subgroup]`; renders
    live in `output/renders/`; `.gitignore` carries `*.html` and
    `notebooks/output/` so a stray render cannot be committed.
22. **`install.packages()` without a mirror in `Rscript`.** No default
    CRAN mirror outside RStudio. Rule: `install_deps.R` sets `repos =`.
23. **`%||%` and `builder_approve()` missing in `Rscript -e`.** Neither is
    on the search path in a fresh Rscript. Rule: one-liners the person is
    asked to run call `fearlabr::` explicitly, or the person uses the
    scripts (`render_stage.R`, `rerun_stages.R`) which load everything.
24. **rstan on Windows without Rtools.** The CRAN rstan binary built for
    R 4.5.3 will not load on R 4.5.2 (`rstan.dll ... procedure could not be
    found`), and without Rtools nothing compiles. Rule: `analysis.engine`
    in the config chooses `frequentist` (lme4 + emmeans) or `bayes`
    (brms); stage 10 checks the sampler loads at setup and says which
    engine ran in its banner. Confirm R version and Rtools at intake
    (`Sys.which("make")` non-empty means Rtools is on the path).
25. **emmeans column names.** `contrast()` on an `emtrends` object names
    the column `estimate`, not `<var>.trend`. Rule: helpers pick the
    column by `intersect()` over the names they can expect; interaction
    notes are wrapped in `suppressMessages()`.
26. **Transparent PNG backgrounds and alphabetical panels.** Figures saved
    without `bg = "white"` were unreadable on dark viewers; waves sorted
    alphabetically (`1month_followup` before `baseline`). Rule: `ggsave(...,
    bg = "white")`; every wave, panel and analysis id is a factor with
    levels in schedule order; registry ids get a readable label in tables.
27. **Wrong-mirror script names.** A script named `export_exit_text_
    RESTRICTED.R` matched the `*_RESTRICTED*` ignore rule and never
    reached the repo. Rule: the RESTRICTED suffix belongs to outputs only;
    scripts that write them carry a plain name.
28. **`mark_stage()` called with the wrong signature.** It takes
    `(manifest, id, status, ...)`; an early one-liner dropped the manifest.
    Rule: `builder_approve("<id>")` from the console, or `rerun_stages.R`.

## Using this for the next pipeline

The build order that worked, with the round trips it took, so the next
study can plan its sessions:

1. **Intake before the interview.** Everything in
   `study-intake-checklist.md` in hand first. FARM-TOK spent three renders
   on things a same-day REDCap export and a toolchain check would have
   settled.
2. **Config derived, then walked.** `derive_config.R` and
   `derive_ema_config.R` propose; the todo walk confirms scoring, reverse
   coding, skip rules, stratifiers and their events, test ids and repairs.
   The decision log in `PROJECT_SPEC.md` records each answer with its date.
3. **Proof on synthetic, then 00 to 03 in one sitting.** These stages are
   the same for every REDCap study; expect one fix each for study-specific
   field names.
4. **04 and 05 need the first real EMA pull.** Battery names, field-group
   children, date order and item ranges are not knowable from the codebook.
5. **06, 07, 07m, 07c close the data side.** 07c is where every earlier id
   shortcut surfaces; budget a fix-and-rerun of 03 and 04 after it.
6. **08 needs the benchmarks decided.** Feasibility targets, progression
   rule, fidelity coding and exit-interview items come from the protocol;
   ask for them before generating.
7. **10 and 11 need the registry.** Write `analysis_plan.yml` and `DAP.md`
   with the person first; every entry there becomes one loop iteration in
   the notebook. Subgroups and moderators are config keys, so adding one is
   a config edit and a re-render, not new code.
8. **Rerun chains with `rerun_stages.R`.** When an upstream fix invalidates
   the chain, one command renders and approves in order and renders each
   subgroup after 10 and 11.

Reuse as they are: `scripts/render_stage.R`, `scripts/rerun_stages.R`,
`scripts/install_deps.R`, the registry helpers (rename the `farmtok_`
prefix), the model helpers with the `analysis.engine` switch, the dry-run
harness and its test doubles, and the `.gitignore`.

Expect to change: instrument scoring blocks, the timepoint schedule, the
EMA item map, the benchmark set in `feasibility`, the analysis registry,
and every `<study>_` prefix.
