# =============================================================================
# 07_firms/fetch_firms.R
# Downloads NASA FIRMS VIIRS fire detections for Sweden, 2012–2023.
#
# Requires a free FIRMS MAP_KEY — register at:
#   https://firms.modaps.eosdis.nasa.gov/api/
#   (instant; just supply your email address)
#
# Set MAP_KEY in ~/.Renviron:
#   FIRMS_MAP_KEY=your32characterkeyhere
#
# API endpoint used: country/csv (standard processing, SP — full historical years)
#   https://firms.modaps.eosdis.nasa.gov/api/country/csv/{KEY}/VIIRS_SNPP_SP/{COUNTRY}/{YEAR}
#
# Output:
#   07_firms/output/firms_sweden_YYYY.csv   — raw annual VIIRS detections
#   07_firms/output/firms_skane.rds         — filtered to Skåne bbox
#   07_firms/output/firms_events.rds        — daily fire flag + FRP for exposure model
# =============================================================================

library(here)
library(dplyr)
library(lubridate)
library(readr)
library(curl)

OUT   <- here("07_firms/output")
YEARS <- 2012:2023   # VIIRS S-NPP available from Jan 2012

# Skåne bounding box
BBOX <- list(lat_min = 55.15, lat_max = 56.65, lon_min = 12.4, lon_max = 14.65)

# ── MAP_KEY check ─────────────────────────────────────────────────────────────
MAP_KEY <- Sys.getenv("FIRMS_MAP_KEY")

if (nchar(MAP_KEY) == 0) {
  message("
  ── FIRMS MAP_KEY required ──────────────────────────────────────────────────
  Register for a free key at: https://firms.modaps.eosdis.nasa.gov/api/
  (supply your email; key is issued instantly)

  Then add to ~/.Renviron:
    FIRMS_MAP_KEY=your32characterkeyhere

  Or set temporarily in R:
    Sys.setenv(FIRMS_MAP_KEY = 'yourkey')
  ────────────────────────────────────────────────────────────────────────────
  ")
  stop("FIRMS_MAP_KEY not set — see instructions above")
}

# Validate key format (32 hex characters)
if (!grepl("^[0-9a-f]{32}$", MAP_KEY)) {
  warning("MAP_KEY doesn't look like a standard 32-char hex key — proceeding anyway")
}

# ── Download annual VIIRS files for Sweden ────────────────────────────────────
# Country endpoint (SP = Standard Processing, full historical years):
# https://firms.modaps.eosdis.nasa.gov/api/country/csv/{KEY}/VIIRS_SNPP_SP/SWE/{YEAR}

firms_base <- "https://firms.modaps.eosdis.nasa.gov/api/country/csv"

download_firms_year <- function(year) {
  csv_path <- file.path(OUT, paste0("firms_sweden_", year, ".csv"))
  if (file.exists(csv_path) && file.size(csv_path) > 500) {
    message(year, ": already downloaded (", file.size(csv_path) %/% 1024, " KB)")
    return(invisible(csv_path))
  }

  url <- paste0(firms_base, "/", MAP_KEY, "/VIIRS_SNPP_SP/SWE/", year)
  message(year, ": downloading...")

  result <- tryCatch(
    curl::curl_download(url, csv_path, quiet = TRUE),
    error = function(e) { message("  Error: ", conditionMessage(e)); NULL }
  )

  if (is.null(result)) return(NULL)
  sz <- file.size(csv_path)
  if (sz < 100) {
    # Likely an error message in the file
    msg <- readLines(csv_path, warn = FALSE)
    message("  Response: ", paste(msg, collapse = " "))
    file.remove(csv_path)
    return(NULL)
  }
  message("  OK — ", sz %/% 1024, " KB")
  invisible(csv_path)
}

for (yr in YEARS) download_firms_year(yr)

# ── Load and filter to Skåne bbox ────────────────────────────────────────────
csv_files <- list.files(OUT, pattern = "firms_sweden_\\d{4}\\.csv", full.names = TRUE)

if (length(csv_files) == 0) {
  stop("No FIRMS CSV files found. Check MAP_KEY and download errors above.")
}

message("\nLoading ", length(csv_files), " annual files...")

firms_raw <- lapply(csv_files, function(f) {
  tryCatch(
    read_csv(f, show_col_types = FALSE),
    error = function(e) { message("  Skip ", basename(f), ": ", e$message); NULL }
  )
}) |>
  Filter(Negate(is.null), x = _) |>
  bind_rows() |>
  select(any_of(c("latitude", "longitude", "acq_date", "acq_time",
                   "confidence", "bright_ti4", "bright_ti5", "frp", "daynight")))

firms_skane <- firms_raw |>
  filter(
    latitude  >= BBOX$lat_min, latitude  <= BBOX$lat_max,
    longitude >= BBOX$lon_min, longitude <= BBOX$lon_max
  ) |>
  mutate(
    date      = as.Date(acq_date),
    conf_high = confidence %in% c("n", "h")
  )

message("Fires in/near Skåne: ", nrow(firms_skane))
message("Date range: ", min(firms_skane$date), " – ", max(firms_skane$date))
saveRDS(firms_skane, file.path(OUT, "firms_skane.rds"))

# ── Daily fire-activity flag ──────────────────────────────────────────────────
firms_daily <- firms_skane |>
  filter(conf_high) |>
  group_by(date) |>
  summarise(
    n_fires       = n(),
    mean_frp      = mean(frp, na.rm = TRUE),
    fire_lat_mean = mean(latitude),
    fire_lon_mean = mean(longitude),
    fire_flag     = TRUE,
    .groups       = "drop"
  )

all_dates   <- tibble(date = seq(as.Date("2012-01-01"), as.Date("2023-12-31"), by = "day"))
firms_daily <- left_join(all_dates, firms_daily, by = "date") |>
  mutate(fire_flag = replace_na(fire_flag, FALSE),
         n_fires   = replace_na(n_fires, 0L))

saveRDS(firms_daily, file.path(OUT, "firms_events.rds"))

message("\nFire days per year:")
firms_daily |>
  filter(fire_flag) |>
  count(year = year(date)) |>
  print()

message("\nDone — firms_events.rds ready for linkage to exposure_matrix by date.")
