# Project aims: Indoor thermal exposure and health in Swedish residential buildings

## Scientific aim

To estimate the indoor temperature experienced by older adults living in Swedish residential
buildings during extreme weather events (heat waves and cold snaps), and to link these
estimates to health outcomes in the RELOC-AGE cohort.

The core question is: **given an outdoor temperature record, what was the likely indoor
temperature in a given building, and how does this vary by building characteristics?**

This matters because:
- Epidemiological studies consistently use outdoor temperature as the exposure measure
- Indoor temperatures can differ substantially from outdoor (buffering in winter, heat
  accumulation in summer)
- The magnitude of indoor-outdoor decoupling depends heavily on insulation era and
  building type — factors that vary systematically across the Swedish housing stock

## Approach

### 1. RC thermal model

A first-order resistor-capacitor (RC) model relates indoor temperature T_in to outdoor T_out:

```
dT_in/dt = (T_out - T_in) / τ
```

The time constant τ (hours) captures how quickly the building responds to outdoor changes:
- Small τ: poorly insulated building, indoor tracks outdoor closely
- Large τ: well-insulated building, indoor is buffered from outdoor extremes

τ is estimated empirically from the Fraunhofer indoor/outdoor time series, then scaled by
insulation-era factors derived from the BETSI building survey.

### 2. Building insulation epochs

The Swedish building stock is stratified by construction era, reflecting successive
building codes (BBR):

| Epoch | Years | Characteristics | Thermal vuln. score | RC τ (h) |
|-------|-------|-----------------|---------------------|-----------|
| pre_1961 | –1960 | Stone/brick, variable insulation | 0.82 | 5.5 |
| 1961_1975 | 1961–1975 | Miljonprogrammet; thin concrete, minimal insulation | 0.90 | 3.5 |
| 1976_1985 | 1976–1985 | Post-BBR75 reforms | 0.55 | 7.0 |
| 1986_1995 | 1986–1995 | Improved standards | 0.40 | 9.0 |
| 1996_2005 | 1996–2005 | Modern insulation | 0.30 | 12.0 |

The 1961–1975 miljonprogrammet era is the most thermally vulnerable: industrialised
concrete construction with minimal insulation gives the fastest indoor response to
outdoor temperature extremes.

### 3. Exposure matrix

The pipeline produces a daily exposure matrix covering Skåne 2010–2023, with one row
per date × insulation epoch, containing estimated indoor temperature alongside extreme
event flags for linkage to health outcome data.

## Study area

![Study area map: Skåne with SMHI stations and ERA5 grid](figures/fig_01_study_area.png)

*Figure 1. The 12 active SMHI temperature stations (circles, coloured by mean June–August
daily maximum temperature 2010–2023) and the ERA5 0.25° reanalysis grid (54 cells) covering
Skåne. Western stations (Malmö, Helsingborg) are consistently warmer in summer than inland
and northern sites.*

![Annual thermal-stress days in Skåne 2010–2023](figures/fig_02_heatwave.png)

*Figure 2. Annual count of heat-stress days (Tmax ≥ 25°C and Tmean ≥ 20°C) and cold-stress
days (Tmin ≤ −10°C), median across SMHI stations. The 2018 heatwave is the most extreme
event in the record; 2022 shows two shorter episodes. Cold winters (2010, 2012) are the main
cold-stress years.*

## Data sources and status

### SMHI station observations ✓ complete
- **What**: Daily temperature (mean/max/min), humidity, and precipitation from 12–39
  active stations in Skåne
- **Coverage**: 2010-01-01 to 2023-12-31
- **Output**: `01_smhi/output/smhi_*_daily.rds`
- **Events identified**: 15 heat waves, 4 cold snaps, 14 heavy rain events
  - 2018 heatwave: 15-day event Jul 21 – Aug 4 (longest on record in period)
  - 2022 heatwave: two episodes, Jul 19–21 and Aug 12–18
- **Notes**: SMHI open data, CC BY-SE 4.0. Uses corrected-archive endpoint.
  13 of 78 Skåne stations active for temperature.

### BETSI building survey ✓ complete
- **What**: National survey of Swedish residential buildings (~2009); building age,
  type, floor area, ventilation, moisture indicators
- **Coverage**: 826 single-family buildings across 5 insulation epochs
- **Output**: `02_betsi/output/betsi_buildings.rds`, `betsi_thermal_params.rds`
- **Notes**: Boverket open data. Source migrated from separate xlsx files to
  `betsi-v2.zip` in 2024. Multi-dwelling buildings present in raw data but filtered
  due to missing age-class mapping — to be investigated.

### Fraunhofer OpenSmartHomeData ✓ complete
- **What**: High-frequency indoor temperature per room + outdoor reference, single
  residential building in Germany
- **Coverage**: 2017-03-09 to 2017-06-06 (89 days)
- **Output**: `03_fraunhofer/output/fraunhofer_timeseries.rds`, `rc_model_params.rds`
- **Notes**: CC BY-SA 4.0. RC model fit: τ converges to upper bound (72 h) for all
  rooms — likely due to limited outdoor temperature variation in the spring study period.
  BETSI-derived τ values used in preference for the exposure model.

### ERA5 reanalysis ⏳ downloading
- **What**: Hourly gridded reanalysis, 0.25° × 0.25° over Skåne bbox
- **Variables**: 2 m temperature, 2 m dewpoint, 10 m u/v wind components
- **Coverage**: 2010–2023, downloading as 168 monthly files (~429 KB each)
- **Output**: `05_era5/output/era5_skane_YYYY_MM.nc`, `era5_skane_daily.rds`
- **Notes**: Copernicus CDS licence. Access via Python `cdsapi`; licence must be
  accepted at https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels

### Netatmo crowdsourced stations ⏭ pending credentials
- **What**: Current snapshot of public outdoor temperature/humidity sensors in Skåne
- **Use**: Spatial density mapping; validation of ERA5 and SMHI
- **Notes**: Netatmo public API provides current readings only (no historical).
  Requires free developer account at https://dev.netatmo.com

### Influenza data ✓ complete
- **What**: Weekly influenza incidence from Folkhälsomyndigheten
- **Source files**: `data/binflReg_*.xlsx` (regional, 2015 w40–2026 w11),
  `data/ainflivavLtyp_*.xlsx` (national by subtype, 2020+)
- **Output**: `01_smhi/output/influenza_weekly.csv` (year, week, incidence_per_100k for Skåne)
- **Notes**: Totalt influensa per 100k, Skåne region (Region Skåne). Max observed
  incidence 30.6/100k (week 52/2022). The epidemic threshold used in `define_events.R`
  (>50/100k) is not reached in the 2015–2026 period — no flu weeks are currently flagged.
  Consider adjusting threshold if regional-level flagging is needed for the analysis.

## Linkage to RELOC-AGE

The final exposure matrix will be linked to RELOC-AGE cohort members via:
- Residential address → building insulation epoch (from BETSI/property register)
- Date of health event → daily exposure values

SÄBO (nursing home) residents must be identified and stratified separately before linkage,
as their thermal environment differs from private residential buildings. The NRCSSEPI
register provides SÄBO residency dates.

## Known limitations

1. **RC model calibration**: The Fraunhofer building is a single German property and may
   not represent the Swedish building stock. The τ values from BETSI are literature-derived
   rather than empirically fitted to Swedish buildings.

2. **BETSI coverage**: The 2009 survey pre-dates recent renovation activity. Buildings
   renovated after 2009 may be misclassified into older insulation epochs.

3. **ERA5 spatial resolution**: At 0.25° (~25 km), ERA5 cannot capture urban heat island
   effects or local topographic variation. Netatmo data may help validate urban bias.

4. **SMHI station coverage**: 12 active temperature stations for a region ~10,000 km².
   ERA5 fills gaps but is a model product, not direct observation.
