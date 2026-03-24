# =============================================================================
# 03_fraunhofer/fetch_fraunhofer.R
# Clones OpenSmartHomeData (CC BY-SA 4.0) and parses per-room time series.
# Source: https://github.com/TechnicalBuildingSystems/OpenSmartHomeData
#
# Output: 03_fraunhofer/output/fraunhofer_timeseries.rds
# =============================================================================

library(tidyverse)
library(lubridate)
library(here)

REPO_URL  <- "https://github.com/TechnicalBuildingSystems/OpenSmartHomeData.git"
CLONE_DIR <- here("03_fraunhofer/OpenSmartHomeData")
OUT       <- here("03_fraunhofer/output")
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

# Clone or pull
if (!dir.exists(CLONE_DIR)) {
  message("Cloning repo...")
  system(paste("git clone", REPO_URL, CLONE_DIR))
} else {
  message("Repo exists — pulling latest...")
  system(paste("git -C", CLONE_DIR, "pull"))
}

ROOMS <- c("Bathroom", "Kitchen", "Room1", "Room2", "Room3", "Toilet")
MEASURES <- c(
  "Temperature"          = "indoor_temp_c",
  "ThermostatTemperature"= "thermostat_temp_c",
  "SetpointHistory"      = "setpoint_c",
  "OutdoorTemperature"   = "outdoor_temp_c"
)

load_series <- function(room, mtype, col_name) {
  pattern <- paste0(room, "_", mtype, ".csv")
  files   <- list.files(CLONE_DIR, pattern = pattern,
                        recursive = TRUE, full.names = TRUE)
  if (length(files) == 0) return(NULL)

  tryCatch({
    read_delim(files[1], delim = "\t", col_names = c("unix_ts", "value"),
               col_types = "dc", show_col_types = FALSE) |>
      mutate(
        datetime = as_datetime(unix_ts, tz = "Europe/Berlin") |>
                   with_tz("Europe/Berlin") |>
                   force_tz("UTC"),
        room     = room,
        measure  = col_name,
        value    = as.numeric(value)
      ) |>
      select(datetime, room, measure, value) |>
      drop_na(value)
  }, error = \(e) {
    message("  Could not load ", pattern, ": ", e$message)
    NULL
  })
}

message("Parsing room time series...")
ts_long <- tidyr::expand_grid(room = ROOMS, mtype = names(MEASURES)) |>
  pmap_df(\(room, mtype) load_series(room, mtype, MEASURES[mtype]))

message("Long format: ", nrow(ts_long), " rows")

# Pivot wide: one column per room × measure
ts_wide <- ts_long |>
  pivot_wider(
    id_cols     = datetime,
    names_from  = c(room, measure),
    values_from = value,
    values_fn   = mean,
    names_sep   = "_"
  ) |>
  arrange(datetime)

# Outdoor temperature: average across all room outdoor readings
outdoor_cols <- str_subset(names(ts_wide), "outdoor_temp")
if (length(outdoor_cols) > 0) {
  ts_wide <- ts_wide |>
    mutate(outdoor_temp_c = rowMeans(pick(all_of(outdoor_cols)), na.rm = TRUE))
}

saveRDS(ts_wide, here(OUT, "fraunhofer_timeseries.rds"))
message("Saved: ", nrow(ts_wide), " rows × ", ncol(ts_wide), " cols")
message("Date range: ", min(ts_wide$datetime), " – ", max(ts_wide$datetime))
message("\nDone. Next: source(here('03_fraunhofer/fit_rc_model.R'))")
