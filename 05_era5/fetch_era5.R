# =============================================================================
# 05_era5/fetch_era5.R
# Downloads ERA5 hourly reanalysis for Skåne via ECMWF Web API (Python client).
#
# One-time setup:
#   1. Register at https://www.ecmwf.int/
#   2. Get your API key from your ECMWF profile page
#   3. Create ~/.ecmwfapirc containing:
#        { "url": "https://api.ecmwf.int/v1", "key": "...", "email": "..." }
#   4. Accept the ERA5 licence at https://apps.ecmwf.int/datasets/data/interim-full-daily
#
# Variables: 2 m temperature, dewpoint, 10 m u/v wind
# Resolution: 0.25° × 0.25° (~25 km), Skåne bbox
# Strategy: one request per year (~100–300 MB each). Requests queue server-side.
#
# Output:
#   05_era5/output/era5_skane_YYYY.nc   (one NetCDF per year)
#   05_era5/output/era5_skane_daily.rds (daily aggregates, all years)
# =============================================================================

library(tidyverse)
library(lubridate)
library(terra)
library(here)

OUT     <- here("05_era5/output")
WORKER  <- here("05_era5/fetch_era5_worker.py")
YEARS   <- 2010:2023

dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

# ── Check credentials exist ---------------------------------------------------
apirc <- path.expand("~/.ecmwfapirc")
if (!file.exists(apirc)) {
  stop(
    "~/.ecmwfapirc not found.\n",
    "Create it with: url, key, email fields from your ECMWF profile."
  )
}

# ── Download year by year via Python worker -----------------------------------
message("=" |> rep(55) |> paste(collapse = ""))
message("ERA5 download — Skåne ", min(YEARS), "–", max(YEARS))
message("Each year ~100–300 MB. Requests queue server-side.")
message("=" |> rep(55) |> paste(collapse = ""))

year_months <- tidyr::expand_grid(yr = YEARS, mo = sprintf("%02d", 1:12))

for (i in seq_len(nrow(year_months))) {
  yr <- year_months$yr[i]
  mo <- year_months$mo[i]
  nc_path <- file.path(OUT, paste0("era5_skane_", yr, "_", mo, ".nc"))
  if (file.exists(nc_path)) {
    message(yr, "-", mo, ": already downloaded (", round(file.size(nc_path) / 1e6, 1), " MB)")
    next
  }
  message(yr, "-", mo, ": submitting request to CDS...")
  ret <- system2("python3", args = c(shQuote(WORKER), yr, mo, shQuote(nc_path)),
                 stdout = TRUE, stderr = TRUE)
  cat(ret, sep = "\n")
  if (!file.exists(nc_path)) {
    message("  WARNING: ", yr, "-", mo, " download did not produce output file — skipping.")
  }
}

# ── Convert NetCDF → daily aggregates ----------------------------------------
nc_to_daily <- function(nc_path) {
  r <- tryCatch(rast(nc_path), error = \(e) {
    message("Cannot open ", basename(nc_path), ": ", e$message)
    return(NULL)
  })
  if (is.null(r)) return(NULL)

  # Spatial mean over all Skåne grid cells
  r_mean <- global(r, "mean", na.rm = TRUE) |>
    as_tibble(rownames = "layer") |>
    rename(value = mean)

  # ERA5 layer names: e.g. "t2m_2010-06-01 00:00:00"
  r_mean <- r_mean |>
    mutate(
      datetime = as_datetime(str_extract(layer, "\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}")),
      varname  = str_extract(layer, "^[a-z0-9_]+(?=_\\d)")
    ) |>
    filter(!is.na(datetime))

  r_mean |>
    mutate(
      date  = as.Date(datetime),
      value = case_when(
        varname %in% c("t2m", "d2m") ~ value - 273.15,   # K → °C
        TRUE                          ~ value
      ),
      varname = recode(varname,
        "t2m" = "temp_c",
        "d2m" = "dewpoint_c",
        "u10" = "wind_u",
        "v10" = "wind_v"
      )
    ) |>
    group_by(date, varname) |>
    summarise(
      mean = mean(value, na.rm = TRUE),
      max  = max(value,  na.rm = TRUE),
      min  = min(value,  na.rm = TRUE),
      .groups = "drop"
    )
}

message("\nConverting NetCDF → daily aggregates...")
nc_files <- list.files(OUT, pattern = "era5_skane_\\d{4}_\\d{2}\\.nc", full.names = TRUE)

if (length(nc_files) == 0) {
  message("No NetCDF files found — skipping aggregation.")
} else {
  daily_long <- map_df(nc_files, \(f) {
    message("  Processing ", basename(f))
    nc_to_daily(f)
  })

  daily <- daily_long |>
    pivot_wider(
      id_cols     = date,
      names_from  = varname,
      values_from = c(mean, max, min),
      names_glue  = "{varname}_{.value}"
    ) |>
    mutate(
      rh_mean = if ("temp_c_mean" %in% names(.data) &&
                    "dewpoint_c_mean" %in% names(.data)) {
        100 * exp(17.625 * dewpoint_c_mean / (243.04 + dewpoint_c_mean)) /
              exp(17.625 * temp_c_mean    / (243.04 + temp_c_mean))
      } else NA_real_,
      wind_speed_mean = if ("wind_u_mean" %in% names(.data) &&
                            "wind_v_mean" %in% names(.data)) {
        sqrt(wind_u_mean^2 + wind_v_mean^2)
      } else NA_real_
    ) |>
    arrange(date)

  saveRDS(daily, here(OUT, "era5_skane_daily.rds"))
  write_csv(daily, here(OUT, "era5_skane_daily.csv"))

  message("\nERA5 daily: ", nrow(daily), " days → era5_skane_daily.rds")
  message("Date range: ", min(daily$date), " – ", max(daily$date))
  message("Columns: ", paste(names(daily), collapse = ", "))
}

message("\nDone. Next: source(here('06_integrate/build_exposure_matrix.R'))")
