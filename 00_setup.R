# =============================================================================
# weather_health_data/00_setup.R
# Run this once before anything else.
# Installs packages, creates folder structure, checks credentials.
# =============================================================================

# ── Core packages (required for all scripts except 05_era5) ------------------
packages <- c(
  # Core
  "tidyverse",      # dplyr, ggplot2, readr, purrr, lubridate, tidyr, stringr
  "here",           # project-relative paths

  # HTTP / API
  "httr2",          # modern HTTP client (replaces httr)
  "jsonlite",       # JSON parsing
  "glue",           # string interpolation (used by fetch_smhi.R)

  # NetCDF (ERA5 output format) — terra already installed
  "terra",          # fast raster/NetCDF handling

  # Excel (BETSI files)
  "readxl",

  # Spatial
  "sf",             # simple features — for coordinate operations

  # Time series / modelling
  "zoo",            # rolling windows for event detection
  "nlme"            # nonlinear least squares for RC model fitting
  # "arrow"         # parquet read/write (optional — .rds works too)
  # "ncdf4"         # lower-level NetCDF — needs libnetcdf-dev: sudo apt install libnetcdf-dev
)

new_packages <- packages[!packages %in% installed.packages()[, "Package"]]
if (length(new_packages)) {
  message("Installing: ", paste(new_packages, collapse = ", "))
  install.packages(new_packages, dependencies = TRUE)
}
invisible(lapply(packages, library, character.only = TRUE))

# ── ERA5 package (ecmwfr) — needs version 1.5.0 for R 4.1.x ------------------
# Current CRAN ecmwfr requires R >= 4.2; install 1.5.0 from archive instead.
# Must install its dependencies (keyring, getPass) first.
if (!"ecmwfr" %in% installed.packages()[, "Package"]) {
  message("Installing ecmwfr dependencies then ecmwfr 1.5.0 (R 4.1 compatible)...")
  for (dep in c("keyring", "getPass")) {
    if (!dep %in% installed.packages()[, "Package"])
      install.packages(dep, dependencies = TRUE)
  }
  install.packages(
    "https://cran.r-project.org/src/contrib/Archive/ecmwfr/ecmwfr_1.5.0.tar.gz",
    repos = NULL, type = "source"
  )
}

# ── Directory structure -------------------------------------------------------
dirs <- c(
  "01_smhi/output",
  "02_betsi/output/betsi_raw",
  "03_fraunhofer/output",
  "04_netatmo/output",
  "05_era5/output",
  "06_integrate/output"
)
purrr::walk(dirs, \(d) dir.create(here(d), recursive = TRUE, showWarnings = FALSE))
message("Directories created.")

# ── ERA5 credential check -----------------------------------------------------
# One-time setup:
#   1. Register at https://cds.climate.copernicus.eu/
#   2. Get your Personal Access Token from your profile page
#   3. Run: ecmwfr::wf_set_key(key = "YOUR-TOKEN-HERE")
#   4. Accept ERA5 licence at the dataset page

tryCatch({
  if (!ecmwfr::wf_check_login(silent = TRUE)) {
    message(
      "\nERA5 credentials not set. Run once:\n",
      '  ecmwfr::wf_set_key(key = "YOUR-CDS-TOKEN")\n',
      "Get your token at: https://cds.climate.copernicus.eu/profile\n",
      "Then accept the ERA5 licence at:\n",
      "  https://cds.climate.copernicus.eu/datasets/reanalysis-era5-single-levels\n"
    )
  } else {
    message("ERA5 credentials: OK")
  }
}, error = \(e) message("ERA5 (ecmwfr) not available: ", e$message))

# ── Netatmo credential check --------------------------------------------------
# One-time setup:
#   1. Register at https://dev.netatmo.com
#   2. Create an app to get CLIENT_ID and CLIENT_SECRET
#   3. Add to your ~/.Renviron (restart R after):
#      NETATMO_CLIENT_ID=your_id
#      NETATMO_CLIENT_SECRET=your_secret
#      NETATMO_USERNAME=your_email
#      NETATMO_PASSWORD=your_password
#   Or use usethis::edit_r_environ()

netatmo_vars <- c("NETATMO_CLIENT_ID", "NETATMO_CLIENT_SECRET",
                  "NETATMO_USERNAME",  "NETATMO_PASSWORD")
missing_vars <- netatmo_vars[Sys.getenv(netatmo_vars) == ""]
if (length(missing_vars) > 0) {
  message(
    "\nNetatmo credentials missing from ~/.Renviron:\n",
    paste(" ", missing_vars, collapse = "\n"), "\n",
    "Run usethis::edit_r_environ() to add them.\n"
  )
} else {
  message("Netatmo credentials: OK")
}

message("\nSetup complete. Run scripts in order:\n",
        "  source(here('01_smhi/fetch_smhi.R'))\n",
        "  source(here('01_smhi/define_events.R'))\n",
        "  source(here('02_betsi/fetch_betsi.R'))\n",
        "  source(here('02_betsi/process_betsi.R'))\n",
        "  source(here('03_fraunhofer/fetch_fraunhofer.R'))\n",
        "  source(here('03_fraunhofer/fit_rc_model.R'))\n",
        "  source(here('04_netatmo/fetch_netatmo.R'))\n",
        "  source(here('05_era5/fetch_era5.R'))\n",
        "  source(here('06_integrate/build_exposure_matrix.R'))\n")
