# Example EEG metadata

What `scripts/derive_modality_config.R` reads for EEG, in the shapes it
expects. All fictional.

- `flanker_features.csv`: the preprocessed feature export, long, one row per
  participant x session x channel x condition x measure, with `nave` trial
  counts. Column names are whatever the tool wrote; the derivation proposes
  the crosswalk by name.
- `sub-001_ses-01_task-flanker_eeg.vhdr` / `.vmrk`: a BrainVision header and
  marker file as Recorder writes them. The header gives sampling rate,
  channels, reference, unit, hardware filters and the amplifier; the marker
  file gives stimulus and response codes with their counts.
- `sub-001_ses-01_task-flanker_eeg.json`, `participants.tsv`,
  `sub-001_ses-01_task-flanker_events.tsv`: BIDS sidecars. The JSON adds
  power-line frequency, software filters, cap and manufacturer; events give
  trial_type counts.
- `flanker_bins.txt`: an ERPLAB bin descriptor; bin labels name conditions.

What the derivation proposes from these: `eeg.columns`, `id_transform` and
`id_pattern`, `session_map` against the declared timepoints, one feature
candidate per measure x condition, QC thresholds from the distributions
(marked default), and `eeg.recording` for the methods section. The
measurement window, which timepoints expect EEG, and which features the
plan names are asked.
