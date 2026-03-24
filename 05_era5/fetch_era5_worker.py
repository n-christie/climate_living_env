#!/usr/bin/env python3
# =============================================================================
# 05_era5/fetch_era5_worker.py
# Downloads one year of ERA5 hourly data for Skåne via Copernicus CDS API.
# Called by fetch_era5.R: python3 fetch_era5_worker.py <year> <output.nc>
#
# Credentials: ~/.cdsapirc  (url, key)
# =============================================================================

import sys
import cdsapi

if len(sys.argv) != 4:
    print("Usage: python3 fetch_era5_worker.py <year> <month> <output.nc>")
    sys.exit(1)

year        = sys.argv[1]
month       = sys.argv[2]   # zero-padded, e.g. "01"
output_path = sys.argv[3]

c = cdsapi.Client()

c.retrieve(
    "reanalysis-era5-single-levels",
    {
        "product_type": "reanalysis",
        "variable": [
            "2m_temperature",
            "2m_dewpoint_temperature",
            "10m_u_component_of_wind",
            "10m_v_component_of_wind",
        ],
        "year":  year,
        "month": month,
        "day":   [f"{d:02d}" for d in range(1, 32)],
        "time":  [f"{h:02d}:00" for h in range(24)],
        "area":  [56.5, 12.5, 55.2, 14.5],   # N, W, S, E  (Skåne bbox)
        "data_format":     "netcdf",
        "download_format": "unarchived",
    },
    output_path,
)

print(f"Downloaded: {output_path}")
