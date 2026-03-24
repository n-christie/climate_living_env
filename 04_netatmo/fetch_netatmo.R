# =============================================================================
# 04_netatmo/fetch_netatmo.R
# Fetches public outdoor station data from Netatmo API for Skåne.
# Requires free registration at https://dev.netatmo.com
#
# Add to ~/.Renviron (use usethis::edit_r_environ()):
#   NETATMO_CLIENT_ID=your_id
#   NETATMO_CLIENT_SECRET=your_secret
#   NETATMO_USERNAME=your_email
#   NETATMO_PASSWORD=your_password
#
# Note: Netatmo public API returns CURRENT readings only (no historical).
# Use this for: spatial coverage mapping, station inventory, and current
# validation. Historical gridded data comes from ERA5 (script 05).
#
# Output:
#   04_netatmo/output/netatmo_snapshot_YYYY-MM-DD.rds
#   04_netatmo/output/netatmo_station_inventory.rds
# =============================================================================

library(tidyverse)
library(httr2)
library(lubridate)
library(here)

OUT <- here("04_netatmo/output")
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

TOKEN_URL <- "https://api.netatmo.com/oauth2/token"
DATA_URL  <- "https://api.netatmo.com/api/getpublicdata"

BBOX <- list(lat_ne = 56.5, lon_ne = 14.5, lat_sw = 55.2, lon_sw = 12.5)

# ── Authenticate --------------------------------------------------------------
get_token <- function() {
  vars <- c("NETATMO_CLIENT_ID", "NETATMO_CLIENT_SECRET",
            "NETATMO_USERNAME",  "NETATMO_PASSWORD")
  vals <- Sys.getenv(vars)
  missing_v <- vars[vals == ""]
  if (length(missing_v) > 0) {
    stop("Missing Netatmo credentials in ~/.Renviron:\n  ",
         paste(missing_v, collapse = "\n  "),
         "\nRun usethis::edit_r_environ() to add them.")
  }

  resp <- request(TOKEN_URL) |>
    req_body_form(
      grant_type    = "password",
      client_id     = vals["NETATMO_CLIENT_ID"],
      client_secret = vals["NETATMO_CLIENT_SECRET"],
      username      = vals["NETATMO_USERNAME"],
      password      = vals["NETATMO_PASSWORD"],
      scope         = "read_station"
    ) |>
    req_perform()

  token <- resp_body_json(resp)$access_token
  message("Netatmo authentication: OK")
  token
}

# ── Subdivide bounding box to get all stations --------------------------------
make_cells <- function(step = 0.4) {
  lats <- seq(BBOX$lat_sw, BBOX$lat_ne, by = step)
  lons <- seq(BBOX$lon_sw, BBOX$lon_ne, by = step)
  tidyr::expand_grid(lat_sw = lats, lon_sw = lons) |>
    mutate(
      lat_ne = pmin(lat_sw + step, BBOX$lat_ne),
      lon_ne = pmin(lon_sw + step, BBOX$lon_ne)
    )
}

# ── Fetch one cell ------------------------------------------------------------
fetch_cell <- function(token, cell) {
  resp <- tryCatch(
    request(DATA_URL) |>
      req_url_query(
        access_token  = token,
        lat_ne        = cell$lat_ne,
        lon_ne        = cell$lon_ne,
        lat_sw        = cell$lat_sw,
        lon_sw        = cell$lon_sw,
        required_data = "temperature,humidity",
        filter        = "true"
      ) |>
      req_perform(),
    error = \(e) { message("  Cell fetch error: ", e$message); NULL }
  )
  if (is.null(resp)) return(tibble())

  stations <- resp_body_json(resp)$body
  if (length(stations) == 0) return(tibble())

  map_df(stations, \(s) {
    measures <- s$measures %||% list()
    temp <- hum <- NA_real_
    for (m in measures) {
      types <- m$type %||% character(0)
      res   <- m$res  %||% list()
      if (length(res) > 0) {
        vals <- res[[1]]
        for (j in seq_along(types)) {
          if (types[j] == "temperature") temp <- vals[[j]]
          if (types[j] == "humidity")    hum  <- vals[[j]]
        }
      }
    }
    tibble(
      station_id    = s$`_id` %||% NA_character_,
      lat           = s$lat   %||% NA_real_,
      lon           = s$lon   %||% NA_real_,
      altitude_m    = (s$place %||% list())$altitude %||% NA_real_,
      city          = (s$place %||% list())$city     %||% NA_character_,
      temperature_c = temp,
      humidity_pct  = hum,
      fetched_utc   = format(Sys.time(), "%Y-%m-%d %H:%M:%S", tz = "UTC")
    )
  })
}

# ── Quality control -----------------------------------------------------------
qc_stations <- function(df) {
  n0 <- nrow(df)
  df <- df |>
    filter(
      between(temperature_c, -30, 45),
      between(humidity_pct,  1,   100)
    ) |>
    distinct(station_id, .keep_all = TRUE)
  message("QC: ", n0, " → ", nrow(df), " stations")
  df
}

# ── Main ---------------------------------------------------------------------
message("=" |> rep(55) |> paste(collapse = ""))
message("Netatmo public stations — Skåne snapshot")
message("=" |> rep(55) |> paste(collapse = ""))

token <- get_token()
cells <- make_cells(step = 0.4)
message("Fetching ", nrow(cells), " sub-regions...")

all_stations <- map_df(
  seq_len(nrow(cells)),
  \(i) {
    res <- fetch_cell(token, cells[i, ])
    Sys.sleep(0.5)
    res
  }
) |>
  qc_stations()

today <- format(Sys.Date(), "%Y-%m-%d")
snap_path <- here(OUT, paste0("netatmo_snapshot_", today, ".rds"))
saveRDS(all_stations, snap_path)
message("Snapshot: ", nrow(all_stations), " stations → ", snap_path)

# Update cumulative station inventory (locations only)
inv_path <- here(OUT, "netatmo_station_inventory.rds")
inv_new  <- all_stations |> select(station_id, lat, lon, altitude_m, city)
if (file.exists(inv_path)) {
  inv <- bind_rows(readRDS(inv_path), inv_new) |>
    distinct(station_id, .keep_all = TRUE)
} else {
  inv <- inv_new
}
saveRDS(inv, inv_path)
message("Station inventory: ", nrow(inv), " unique stations")
message("T range: ", round(min(all_stations$temperature_c, na.rm=TRUE), 1),
        " – ", round(max(all_stations$temperature_c, na.rm=TRUE), 1), "°C")

message("\nNote: Netatmo gives current readings only.")
message("For historical data, run: source(here('05_era5/fetch_era5.R'))")
message("\nDone. Next: source(here('05_era5/fetch_era5.R'))")
