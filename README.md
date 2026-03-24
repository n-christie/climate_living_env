# climate_living_env

Data pipeline for estimating indoor thermal exposure in Swedish residential buildings during
extreme weather events (2010–2023), for linkage to the RELOC-AGE health cohort.

## Overview

Extreme outdoor temperatures cause preventable morbidity and mortality, particularly among
older adults. The health risk depends not on outdoor temperature alone but on the indoor
temperature actually experienced — which is shaped by building age, insulation, and ventilation.
This pipeline assembles the data needed to estimate that indoor exposure.

See [project_aims.md](project_aims.md) for the full scientific rationale and data sources.

## Requirements

- R ≥ 4.1.2
- Python ≥ 3.10 with `cdsapi`, `ecmwf-api-client`, `attrs`
- git (for cloning Fraunhofer dataset)

Install R packages by running `00_setup.R` once. Install Python packages:
```bash
pip3 install cdsapi ecmwf-api-client attrs
```

## External credentials

| Service | Required for | Setup |
|---------|-------------|-------|
| Copernicus CDS | ERA5 reanalysis download | Create `~/.cdsapirc` — see [project_aims.md](project_aims.md) |
| Netatmo API | Crowdsourced station snapshot | Add credentials to `~/.Renviron` — see `04_netatmo/fetch_netatmo.R` |

SMHI station data and BETSI building data require no credentials.

## Run order

```r
source("00_setup.R")
source(here("01_smhi/fetch_smhi.R"))
source(here("01_smhi/define_events.R"))
source(here("02_betsi/fetch_betsi.R"))
source(here("02_betsi/process_betsi.R"))
source(here("03_fraunhofer/fetch_fraunhofer.R"))
source(here("03_fraunhofer/fit_rc_model.R"))
source(here("04_netatmo/fetch_netatmo.R"))      # optional — needs Netatmo credentials
source(here("05_era5/fetch_era5.R"))             # needs ~/.cdsapirc; runs for several hours
source(here("06_integrate/build_exposure_matrix.R"))
```

## Data sources

| Source | Type | Coverage | Licence |
|--------|------|----------|---------|
| SMHI Open Data | Weather station observations | Skåne, 2010–2023 | CC BY-SE 4.0 |
| BETSI (Boverket) | Building survey (age, type, area) | Sweden, ~2009 | Open data |
| OpenSmartHomeData (Fraunhofer) | Indoor/outdoor temperature series | Single building, 2017 | CC BY-SA 4.0 |
| ERA5 (Copernicus/ECMWF) | Gridded hourly reanalysis | Skåne 0.25°, 2010–2023 | Copernicus licence |
| Netatmo public API | Crowdsourced outdoor temperature | Skåne (current snapshot) | Netatmo ToS |

## Output

The final output is `06_integrate/output/exposure_matrix.rds` — a daily matrix with one row
per date × building insulation era, containing:
- Outdoor temperature (ERA5 or SMHI fallback)
- Estimated indoor temperature (from RC thermal model)
- Heat wave / cold snap / rain event flags
- Building thermal vulnerability scores

This is designed for direct linkage to the RELOC-AGE cohort via date and residential
building characteristics.

## Licence

Code: MIT. Data outputs are subject to the licences of their respective source datasets.
