# Example REDCap metadata exports

The three files `scripts/derive_config.R` reads when a study has no API
token. Download the real ones from the project:

- `data_dictionary.csv`: Project Setup > Data Dictionary > Download the
  current Data Dictionary.
- `events.csv`: Project Setup > Define My Events > Download events (CSV).
- `instrument_event_map.csv` (optional but recommended): Project Setup >
  Designate Instruments for My Events > Download instrument-event mappings.
  Without it every event is treated as an assessment event.

Drop them in the study's `metadata/` folder. These example files describe a
fictional project with an enrollment event, three assessment waves (one
with its REDCap offset left at zero, so the derivation infers 180 days from
the name `6_month` and asks for confirmation), a PHQ-9 with a total calc,
an IUS-12 with two subscale calcs and a total, and a 3-item AUDIT with
branching logic and no calc field.
