# One-time install on Windows (PowerShell).  Needs internet once; offline afterwards.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
  Write-Error "uv not found. Install it from https://docs.astral.sh/uv/ then re-run."
}
uv sync
Write-Host ""
Write-Host "Installed.  Try:"
Write-Host "  uv run transcript-deid run examples --roster examples/roster.csv --out examples/deid --print"
Write-Host "  uv run transcript-deid review --out examples/deid --roster examples/roster.csv"
