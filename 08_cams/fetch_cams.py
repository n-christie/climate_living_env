#!/usr/bin/env python3
"""
08_cams/fetch_cams.py
Downloads Copernicus CAMS European air quality reanalysis for Skåne.

Dataset: CAMS European Air Quality Reanalyses (EAC4 for global;
         cams-europe-air-quality-reanalyses for 0.1° European)
Variables: PM2.5, PM10, O3, NO2
Coverage: 2013-2022 (European reanalysis); ~0.1° x 0.1° resolution

Access: Copernicus Atmosphere Data Store (ADS)
Credentials: ~/.adsapirc  (separate from CDS, but same token since 2024 merge)

Usage:
    python3 08_cams/fetch_cams.py <year> <month> <output_path>
"""

import sys
import os

year        = sys.argv[1]
month       = sys.argv[2]
output_path = sys.argv[3]


def read_rc_file(path):
    """Parse a .cdsapirc / .adsapirc file into a dict."""
    result = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if ":" in line and not line.startswith("#"):
                k, _, v = line.partition(":")
                result[k.strip()] = v.strip()
    return result


# Resolve credentials — prefer ~/.adsapirc, fall back to ~/.cdsapirc
ads_rc = os.path.expanduser("~/.adsapirc")
cds_rc = os.path.expanduser("~/.cdsapirc")

rc_path = ads_rc if os.path.exists(ads_rc) else cds_rc
if not os.path.exists(rc_path):
    print("No credentials file found (~/.adsapirc or ~/.cdsapirc). Exiting.")
    sys.exit(1)

creds = read_rc_file(rc_path)
ads_url = creds.get("url", "https://ads.atmosphere.copernicus.eu/api/v2")
api_key = creds.get("key", "")

import cdsapi

# ── Try CAMS European regional reanalysis (0.1°) ─────────────────────────────
try:
    c = cdsapi.Client(url=ads_url, key=api_key, quiet=False)
    c.retrieve(
        "cams-europe-air-quality-reanalyses",
        {
            "variable": [
                "particulate_matter_2.5um",
                "particulate_matter_10um",
                "ozone",
                "nitrogen_dioxide",
            ],
            "model":           "ensemble",
            "level":           "0",          # surface level
            "type":            "validated_reanalysis",
            "year":            year,
            "month":           month,
            "format":          "netcdf",
            # Skåne bbox: N=56.65, W=12.4, S=55.15, E=14.65
            "area":            [56.65, 12.4, 55.15, 14.65],
        },
        output_path,
    )
    print(f"Downloaded: {output_path}")

except Exception as e:
    print(f"ADS European reanalysis failed: {e}")
    print("Trying CAMS global reanalysis (EAC4) as fallback...")

    # Fallback: EAC4 global at CDS — use CDS credentials
    try:
        cds_creds = read_rc_file(cds_rc) if os.path.exists(cds_rc) else creds
        cds_url = cds_creds.get("url", "https://cds.climate.copernicus.eu/api/v2")
        cds_key = cds_creds.get("key", api_key)

        c2 = cdsapi.Client(url=cds_url, key=cds_key, quiet=False)
        # Build a date range covering the full month (use 31 days — API clips to valid days)
        date_range = f"{year}-{month}-01/{year}-{month}-31"
        c2.retrieve(
            "cams-global-reanalysis-eac4",
            {
                "variable": [
                    "particulate_matter_2.5um",
                    "ozone",
                    "nitrogen_dioxide",
                ],
                "date":            date_range,
                "time":            ["00:00", "06:00", "12:00", "18:00"],
                "area":            [56.65, 12.4, 55.15, 14.65],
                "data_format":     "netcdf",
                "download_format": "unarchived",
            },
            output_path,
        )
        print(f"Downloaded (EAC4 global fallback): {output_path}")
    except Exception as e2:
        print(f"Both ADS and EAC4 failed: {e2}")
        sys.exit(1)
