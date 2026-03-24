# =============================================================================
# 01_smhi/fetch_smhi.R
# Downloads daily temperature, humidity, and precipitation from SMHI open data
# for all active stations in Skåne. No authentication required.
#
# API: https://opendata-download-metobs.smhi.se/api
# Licence: CC BY-SE 4.0
#
# Output:
#   01_smhi/output/smhi_stations_skane.csv
#   01_smhi/output/smhi_temperature_daily.rds
#   01_smhi/output/smhi_humidity_daily.rds
#   01_smhi/output/smhi_precip_daily.rds
# =============================================================================

library(tidyverse)
library(lubridate)
library(httr2)
library(jsonlite)
library(curl)
library(here)

BASE    <- "https://opendata-download-metobs.smhi.se/api/version/latest"
OUT     <- here("01_smhi/output")

# Skåne bounding box
LAT     <- c(55.2, 56.5)
LON     <- c(12.5, 14.5)

# SMHI parameter IDs
PARAMS  <- c(temperature = 1, humidity = 6, precip = 7)

STUDY_START <- as.Date("2010-01-01")
STUDY_END   <- as.Date("2023-12-31")

# ── Helper: safe GET with retry -----------------------------------------------
# Uses curl package directly: httr2 1.2.2 + libcurl 7.81.0 loses request method.
smhi_get <- function(url, retries = 3) {
  for (i in seq_len(retries)) {
    result <- tryCatch({
      h    <- new_handle(CONNECTTIMEOUT = 30L, TIMEOUT = 30L)
      raw  <- curl_fetch_memory(url, handle = h)
      list(status = raw$status_code, body = rawToChar(raw$content))
    }, error = function(e) NULL)
    if (!is.null(result) && result$status == 200) {
      Sys.sleep(0.25)
      return(result)
    }
    Sys.sleep(2^i)
  }
  NULL
}

# ── Get stations for a parameter, filtered to Skåne --------------------------
get_stations_skane <- function(param_id) {
  url  <- glue::glue("{BASE}/parameter/{param_id}.json")
  resp <- smhi_get(url)
  if (is.null(resp)) return(tibble())

  data <- fromJSON(resp$body, simplifyVector = FALSE)
  stations <- data$station

  map_df(stations, \(s) tibble(
    station_id   = s$id,
    station_name = s$name,
    lat          = s$latitude,
    lon          = s$longitude,
    active       = s$active %||% TRUE
  )) |>
    filter(
      active,
      between(lat, LAT[1], LAT[2]),
      between(lon, LON[1], LON[2])
    )
}

# ── Fetch corrected-archive CSV for one station/parameter --------------------
fetch_archive <- function(station_id, param_id) {
  url <- glue::glue(
    "{BASE}/parameter/{param_id}/station/{station_id}",
    "/period/corrected-archive/data.csv"
  )
  resp <- smhi_get(url)
  if (is.null(resp) || resp$status == 404) return(tibble())

  raw <- resp$body
  lines <- str_split(raw, "\n")[[1]]

  # SMHI CSVs have a Swedish metadata header; data rows start at "Datum"
  start <- which(str_starts(lines, "Datum"))[1]
  if (is.na(start)) return(tibble())

  df <- read_delim(
    I(paste(lines[start:length(lines)], collapse = "\n")),
    delim = ";", col_types = cols(.default = "c"), show_col_types = FALSE
  )

  # Build datetime
  if ("Tid (UTC)" %in% names(df)) {
    df <- df |> mutate(
      datetime = ymd_hms(paste(`Datum`, `Tid (UTC)`), quiet = TRUE)
    )
  } else {
    df <- df |> mutate(datetime = ymd(`Datum`, quiet = TRUE))
  }

  # Value column: first non-metadata column
  val_col <- setdiff(names(df),
    c("Datum", "Tid (UTC)", "datetime", "Kvalitet"))[1]
  if (is.na(val_col)) return(tibble())

  df |>
    mutate(
      value      = as.numeric(.data[[val_col]]),
      station_id = station_id
    ) |>
    select(datetime, value, station_id) |>
    drop_na(datetime) |>
    filter(between(as.Date(datetime), STUDY_START, STUDY_END))
}

# ── Fetch and aggregate one parameter ----------------------------------------
fetch_param <- function(param_name, param_id) {
  message("\n── ", param_name, " (param ", param_id, ") ─────────────────────")

  stations <- get_stations_skane(param_id)
  message("Stations in Skåne: ", nrow(stations))
  if (nrow(stations) == 0) return(invisible(NULL))

  hourly <- map_df(
    seq_len(nrow(stations)),
    \(i) {
      if (i %% 10 == 0) message("  Station ", i, "/", nrow(stations))
      df <- fetch_archive(stations$station_id[i], param_id)
      if (nrow(df) == 0) return(tibble())
      df |> mutate(
        station_name = stations$station_name[i],
        lat          = stations$lat[i],
        lon          = stations$lon[i]
      )
    }
  )

  if (nrow(hourly) == 0) {
    message("  No data retrieved.")
    return(invisible(NULL))
  }

  hourly <- hourly |> mutate(date = as.Date(datetime))

  daily <- if (param_name == "temperature") {
    hourly |>
      group_by(station_id, station_name, lat, lon, date) |>
      summarise(
        t_mean = mean(value, na.rm = TRUE),
        t_max  = max(value,  na.rm = TRUE),
        t_min  = min(value,  na.rm = TRUE),
        .groups = "drop"
      )
  } else if (param_name == "precip") {
    hourly |>
      group_by(station_id, station_name, lat, lon, date) |>
      summarise(precip_mm = sum(value, na.rm = TRUE), .groups = "drop")
  } else {
    hourly |>
      group_by(station_id, station_name, lat, lon, date) |>
      summarise(mean = mean(value, na.rm = TRUE), .groups = "drop")
  }

  path <- here(OUT, paste0("smhi_", param_name, "_daily.rds"))
  saveRDS(daily, path)
  message("Saved: ", nrow(daily), " rows → ", path)
  message("Stations with data: ", n_distinct(daily$station_id))
  message("Date range: ", min(daily$date), " – ", max(daily$date))
  invisible(daily)
}

# ── Main ---------------------------------------------------------------------
message("=" |> rep(55) |> paste(collapse = ""))
message("SMHI open data — Skåne 2010–2023")
message("No authentication required")
message("=" |> rep(55) |> paste(collapse = ""))

# Save station inventory
stations_ref <- get_stations_skane(PARAMS["temperature"])
write_csv(stations_ref, here(OUT, "smhi_stations_skane.csv"))
message("\nStation index: ", nrow(stations_ref), " stations → ",
        here(OUT, "smhi_stations_skane.csv"))

# Fetch all parameters
walk2(names(PARAMS), PARAMS, fetch_param)

message("\nDone. Next: source(here('01_smhi/define_events.R'))")
