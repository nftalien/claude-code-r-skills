# Example sensor metadata

What `scripts/derive_modality_config.R` reads for sensors. All fictional.

- `0001_actigraph_daily.csv`, `0002_actigraph_daily.csv`: ActiGraph daily
  summaries with the standard ten-line preamble (serial, epoch period, start
  and download dates). One file per participant; the two share a column set
  and become one stream.
- `0003_geneactiv_epoch.csv`: a GENEActiv-style export whose header block
  runs to "Recorded Data" (serial, measurement frequency, time zone offset,
  subject code), then an epoch table.
- `fitbit_sleep.csv`: a plain sleep summary, one row per participant-night.
- `aware_accelerometer.csv`: a phone-app table keyed by device id with
  millisecond epoch timestamps in UTC.

What the derivation proposes: one stream per export shape with its glob,
grain (day or epoch, with the epoch length from the preamble or the
timestamp gaps), id/date/timestamp columns, metrics by name, aggregation
defaults for epoch streams, a valid-day rule with the fraction of days it
keeps, the id transform, and the device block from the preamble. The time
zone is asked unless the config already states it.
