# =============================================================================
# 08_cams/fetch_cams.R
# Downloads CAMS European air quality reanalysis for Skåne, 2013-2022.
# Calls Python worker (fetch_cams.py) via system2(), same pattern as ERA5.
#
# Output:
#   08_cams/output/cams_skane_YYYY_MM.nc   (monthly NetCDF, ~1 MB each)
#   08_cams/output/cams_skane_daily.rds    (daily PM2.5, O3, NO2 aggregated)
# =============================================================================

library(here)
library(dplyr)
library(lubridate)

OUT    <- here("08_cams/output")
WORKER <- here("08_cams/fetch_cams.py")

# CAMS European reanalysis covers 2013-2022
YEARS  <- 2013:2022

if (!file.exists(here("~/.adsapirc")) && !file.exists("~/.cdsapirc")) {
  stop("No ADS/CDS credentials found. CAMS uses the same CDS token.\n",
       "Your existing ~/.cdsapirc should work — the worker will try it.")
}

message("=== CAMS air quality download ===")
message("Variables: PM2.5, PM10, O3, NO2")
message("Coverage: 2013-2022 (CAMS European reanalysis ~0.1°)")

year_months <- tidyr::expand_grid(yr = YEARS, mo = sprintf("%02d", 1:12))

for (i in seq_len(nrow(year_months))) {
  yr <- year_months$yr[i]
  mo <- year_months$mo[i]
  nc_path <- file.path(OUT, sprintf("cams_skane_%d_%s.nc", yr, mo))

  if (file.exists(nc_path)) {
    message(yr, "-", mo, ": already downloaded")
    next
  }

  message(yr, "-", mo, ": submitting CAMS request...")
  ret <- system2("python3",
                 args   = c(shQuote(WORKER), yr, mo, shQuote(nc_path)),
                 stdout = TRUE, stderr = TRUE)
  cat(ret, sep = "\n")

  if (!file.exists(nc_path)) {
    message("  Warning: ", nc_path, " not created — continuing")
  }
}

# ── Aggregate NetCDF files to daily RDS ──────────────────────────────────────
nc_files <- list.files(OUT, pattern = "cams_skane_\\d{4}_\\d{2}\\.nc",
                       full.names = TRUE)

if (length(nc_files) == 0) {
  message("\nNo CAMS NetCDF files yet. Re-run after download completes.")
  quit(save = "no")
}

message("\nAggregating ", length(nc_files), " monthly files to daily RDS...")

library(terra)

process_nc <- function(nc_path) {
  r <- tryCatch(terra::rast(nc_path), error = function(e) NULL)
  if (is.null(r)) return(NULL)

  # Variables may be named differently depending on which dataset was retrieved
  var_names <- names(r)
  message("  Variables in ", basename(nc_path), ": ", paste(var_names, collapse = ", "))

  # Spatial mean over Skåne bbox, then daily mean from sub-daily layers
  r_mean <- terra::global(r, "mean", na.rm = TRUE)

  tibble(
    layer    = rownames(r_mean),
    mean_val = r_mean$mean
  ) |>
    mutate(
      # Parse date from layer name (format varies by dataset)
      date = as.Date(
        regmatches(layer, regexpr("\\d{4}-\\d{2}-\\d{2}", layer))
      )
    ) |>
    filter(!is.na(date))
}

daily_list <- lapply(nc_files, process_nc)
daily_list <- Filter(Negate(is.null), daily_list)

if (length(daily_list) > 0) {
  cams_daily <- bind_rows(daily_list) |>
    group_by(date) |>
    summarise(
      pm25_mean = mean(mean_val[grepl("pm2p5|particulate_matter_2", layer,
                                      ignore.case = TRUE)], na.rm = TRUE),
      o3_mean   = mean(mean_val[grepl("go3|ozone",  layer, ignore.case = TRUE)], na.rm = TRUE),
      no2_mean  = mean(mean_val[grepl("no2|nitrogen", layer, ignore.case = TRUE)], na.rm = TRUE),
      .groups = "drop"
    ) |>
    arrange(date)

  saveRDS(cams_daily, file.path(OUT, "cams_skane_daily.rds"))
  message("Saved cams_skane_daily.rds: ", nrow(cams_daily), " days")
  message("Date range: ", min(cams_daily$date), " – ", max(cams_daily$date))
} else {
  message("Could not process NetCDF files — check variable names")
}
