# climate_living_env — Claude instructions

## Project purpose
R data pipeline that downloads weather and Swedish building data, defines extreme climate
events, fits a thermal RC model, and builds a daily exposure matrix keyed by building
insulation era. Final output links to the RELOC-AGE cohort for heat/cold health analyses.

## Directory layout
```
00_setup.R                  ← run once before anything else
01_smhi/
  fetch_smhi.R              ← download SMHI station data (no auth)
  define_events.R           ← classify heat waves, cold snaps, rain events
02_betsi/
  fetch_betsi.R             ← download Boverket BETSI v2 zip (no auth)
  process_betsi.R           ← building typology + RC thermal parameters
03_fraunhofer/
  fetch_fraunhofer.R        ← git-clone OpenSmartHomeData indoor/outdoor series
  fit_rc_model.R            ← fit first-order RC model τ per room
04_netatmo/
  fetch_netatmo.R           ← snapshot Netatmo public stations (needs API keys)
05_era5/
  fetch_era5.R              ← download ERA5 hourly reanalysis via Python cdsapi
  fetch_era5_worker.py      ← Python worker called per month by fetch_era5.R
06_integrate/
  build_exposure_matrix.R   ← join all sources; one row per date × insulation era
```

`here()` roots at this directory via the `.here` anchor file.

## Run order
```r
source("00_setup.R")                               # installs R packages, creates dirs
# also: pip3 install cdsapi ecmwf-api-client attrs (one-time, in terminal)
source(here("01_smhi/fetch_smhi.R"))               # ~10 min (many API calls)
source(here("01_smhi/define_events.R"))
source(here("02_betsi/fetch_betsi.R"))             # downloads betsi-v2.zip (~1 MB)
source(here("02_betsi/process_betsi.R"))
source(here("03_fraunhofer/fetch_fraunhofer.R"))   # git clone ~100 MB
source(here("03_fraunhofer/fit_rc_model.R"))
source(here("04_netatmo/fetch_netatmo.R"))         # needs .Renviron credentials
source(here("05_era5/fetch_era5.R"))               # needs ~/.cdsapirc; ~3–5 h total
source(here("06_integrate/build_exposure_matrix.R"))
```

## External credentials
| Service | Where to get | How to set |
|---------|-------------|------------|
| ERA5 / CDS | https://cds.climate.copernicus.eu/profile → Personal Access Token | Create `~/.cdsapirc` with `url:` and `key:` fields (see below) |
| ECMWF Web API | https://www.ecmwf.int (same account) | `~/.ecmwfapirc` with `url`, `key`, `email` — NOT used for ERA5 |
| Netatmo | https://dev.netatmo.com | Add 4 vars to `~/.Renviron` (see script header) |

CDS credentials file format (`~/.cdsapirc`):
```
url: https://cds.climate.copernicus.eu/api
key: YOUR-PERSONAL-ACCESS-TOKEN
```

Must also accept ERA5 licence at:
https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels?tab=download#manage-licences

SMHI and BETSI are fully open — no credentials needed.

## Key outputs
| File | Description |
|------|-------------|
| `01_smhi/output/smhi_*_daily.rds` | Daily temperature / humidity / precip per station |
| `01_smhi/output/daily_skane.rds` | Skåne median daily series with event flags |
| `01_smhi/output/extreme_events.rds` | Heat waves, cold snaps, heavy rain events |
| `02_betsi/output/betsi_buildings.rds` | Harmonised building-level data (826 buildings) |
| `02_betsi/output/betsi_thermal_params.rds` | RC τ and vulnerability by insulation era |
| `03_fraunhofer/output/fraunhofer_timeseries.rds` | Indoor/outdoor temperature series |
| `03_fraunhofer/output/rc_model_params.rds` | Fitted τ per room, mean/SD summary |
| `04_netatmo/output/netatmo_snapshot_YYYY-MM-DD.rds` | Current Skåne station snapshot |
| `05_era5/output/era5_skane_YYYY_MM.nc` | Monthly NetCDF files (one per month) |
| `05_era5/output/era5_skane_daily.rds` | Gridded daily weather 2010–2023 |
| `06_integrate/output/exposure_matrix.rds` | Final matrix: date × insulation era |

## Known fixes applied during setup

### Environment
- R 4.1.2 on WSL2 Ubuntu (libcurl 7.81.0)
- tidyverse 1.3.1: lubridate NOT auto-loaded — requires `library(lubridate)` explicitly
- purrr 1.2.1: `cross_df()` removed — replaced with `tidyr::expand_grid()`
- httr2 1.2.2 + libcurl 7.81.0 incompatible: all httr2 calls replaced with `curl::curl_fetch_memory()` or `curl::curl_download()`
- ecmwfr: CRAN version requires R ≥ 4.2; ERA5 now handled via Python `cdsapi` instead

### 00_setup.R
- Added `"glue"` to packages list (used by `fetch_smhi.R`)
- Removed `"arrow"` (duckdb dependency takes too long to compile from source)
- Removed `"ncdf4"` (requires `libnetcdf-dev` system library; terra handles NetCDF)
- Removed `"ecmwfr"` from core packages; installed 1.5.0 from CRAN archive for R 4.1 compat
- Wrapped `wf_check_login()` in `tryCatch` (not exported in ecmwfr 1.5.0)

### 01_smhi/fetch_smhi.R
- Added `library(lubridate)` and `library(curl)`
- Rewrote `smhi_get()` to use `curl::curl_fetch_memory()` instead of httr2
- Changed JSON parsing: `resp_body_json(resp)` → `fromJSON(resp$body, simplifyVector = FALSE)`
- Changed `ymd_hm()` → `ymd_hms()` (SMHI times are HH:MM:SS format)

### 02_betsi/fetch_betsi.R
- Added `library(curl)`; replaced httr2 with `curl::curl_download()`
- Boverket migrated from 6 separate xlsx files to `betsi-v2.zip` (as of 2024)
- Rewrote to download single zip and extract with `unzip()`

### 02_betsi/process_betsi.R
- Completely rewritten for new betsi-v2 CSV structure (was written for xlsx)
- Age classes now in `Upprakningstal.csv` (`ald` column): "1 -60", "2 61-75", etc.
- Building type from `Hustyp` column (S=single_family, F=multi_dwelling)
- Added graceful handling when `FB_OVRIGT.csv` (moisture data) is absent

### 03_fraunhofer/fetch_fraunhofer.R
- Replaced `cross_df(list(...))` → `tidyr::expand_grid(...)`

### 04_netatmo/fetch_netatmo.R
- Replaced `cross_df(list(...))` → `tidyr::expand_grid(...)`
- NOTE: httr2 calls in `get_token()` and `fetch_cell()` still present — will need
  the same `curl::curl_fetch_memory()` fix when Netatmo credentials are added

### 05_era5/fetch_era5.R + fetch_era5_worker.py
- Replaced ecmwfr R package with Python `cdsapi` (ECMWF Web API does not serve ERA5)
- Requests split monthly (year × month) to stay within CDS cost limits per request
- Python deps: `pip3 install cdsapi ecmwf-api-client attrs`

## Notes
- ERA5 downloads 168 monthly files (~429 KB each, ~72 MB total). Run with `nohup`.
  Monitor progress: `tail -f /tmp/era5_download.log`
- Fraunhofer RC model: all rooms converge to τ=72 h (upper bound). The outdoor
  temperature column in this dataset has limited variation — the τ values from
  BETSI thermal_params.rds are more reliable for the exposure model.
- SÄBO (nursing home) residents must be stratified separately before linking to
  RELOC-AGE (via NRCSSEPI); the exposure matrix flags this.
- `influenza_weekly.csv` is missing — download from Folkhälsomyndigheten and place
  in `01_smhi/output/` to add flu flags to define_events.R output.
