# =============================================================================
# 01_smhi/define_events.R
# Identifies extreme weather events from SMHI daily data.
# Focus: 2018 and 2022 Swedish heatwaves (the index events in both proposals),
# plus cold snaps and heavy rain for completeness.
#
# Also flags influenza peak weeks from Folkhälsomyndigheten open data
# (needed as co-exposure for the multi-hazard Formas analyses).
#
# Definitions:
#   Heat wave  : ≥3 consecutive days, Tmax ≥ 25°C AND Tmean ≥ 20°C
#   Cold snap  : ≥3 consecutive days, Tmin ≤ −10°C
#   Rain event : daily precip ≥ 20 mm
#   Influenza  : ISO week with reported incidence above seasonal threshold
#
# Output:
#   01_smhi/output/daily_skane.rds          (daily median across stations)
#   01_smhi/output/extreme_events.rds       (event-level table)
#   01_smhi/output/event_summary.txt
# =============================================================================

library(tidyverse)
library(lubridate)
library(zoo)
library(here)

OUT <- here("01_smhi/output")

# ── Thresholds ----------------------------------------------------------------
HEAT_TMAX  <- 25.0   # °C
HEAT_TMEAN <- 20.0   # °C
HEAT_DAYS  <- 3L
COLD_TMIN  <- -10.0  # °C
COLD_DAYS  <- 3L
RAIN_MM    <- 20.0   # mm/day

# ── Load and aggregate to Skåne daily median ---------------------------------
load_daily <- function(param, col_rename = NULL) {
  path <- here(OUT, paste0("smhi_", param, "_daily.rds"))
  if (!file.exists(path)) {
    message("  Missing: ", path, " — run fetch_smhi.R first")
    return(NULL)
  }
  df <- readRDS(path) |> mutate(date = as.Date(date))

  # Median across stations per day (robust to missing stations)
  val_col <- setdiff(names(df), c("station_id", "station_name", "lat", "lon", "date"))

  agg <- df |>
    group_by(date) |>
    summarise(across(all_of(val_col), \(x) median(x, na.rm = TRUE)),
              .groups = "drop")

  if (!is.null(col_rename)) agg <- rename(agg, !!!col_rename)
  agg
}

temp  <- load_daily("temperature")
prcp  <- load_daily("precip",      col_rename = c(precip_mm = "precip_mm"))
humid <- load_daily("humidity",    col_rename = c(rh_mean   = "mean"))

# Join all sources
daily <- temp |>
  left_join(prcp,  by = "date") |>
  left_join(humid, by = "date") |>
  arrange(date)

message("Daily data: ", nrow(daily), " days (",
        min(daily$date), " – ", max(daily$date), ")")

# ── Helper: extract contiguous events of ≥ min_run days ----------------------
extract_events <- function(flag_vec, dates, min_run, label) {
  rle_result <- rle(flag_vec)
  ends   <- cumsum(rle_result$lengths)
  starts <- c(1, ends[-length(ends)] + 1)

  map_df(seq_along(rle_result$values), \(i) {
    if (!rle_result$values[i]) return(NULL)
    dur <- rle_result$lengths[i]
    if (dur < min_run) return(NULL)
    tibble(
      event_type    = label,
      start         = dates[starts[i]],
      end           = dates[ends[i]],
      duration_days = dur
    )
  })
}

# ── Define events -------------------------------------------------------------
daily <- daily |>
  mutate(
    heat_flag  = !is.na(t_max) & !is.na(t_mean) &
                   t_max >= HEAT_TMAX & t_mean >= HEAT_TMEAN,
    cold_flag  = !is.na(t_min) & t_min <= COLD_TMIN,
    rain_flag  = !is.na(precip_mm) & precip_mm >= RAIN_MM
  )

events_list <- list(
  extract_events(daily$heat_flag, daily$date, HEAT_DAYS, "heat_wave"),
  extract_events(daily$cold_flag, daily$date, COLD_DAYS, "cold_snap"),
  extract_events(daily$rain_flag, daily$date, 1L,        "rain_event")
)

events <- bind_rows(events_list) |> arrange(start)

# ── Highlight the two index heatwaves from the proposals ---------------------
# 2018: late June–August (the record-breaking Swedish heatwave)
# 2022: late June–early August
index_heatwaves <- events |>
  filter(
    event_type == "heat_wave",
    year(start) %in% c(2018, 2022)
  ) |>
  mutate(
    index_event = case_when(
      year(start) == 2018 ~ "2018 heatwave",
      year(start) == 2022 ~ "2022 heatwave",
      TRUE ~ NA_character_
    )
  )

message("\nIndex heatwaves:")
print(index_heatwaves)

# ── Optional: Folkhälsomyndigheten influenza flag ----------------------------
# Influenza incidence is available as open data via:
# https://www.folkhalsomyndigheten.se/folkhalsorapportering-statistik/
#   statistik-a-o/sjukdomsstatistik/influensa/
# Weekly data — download manually as CSV and place at:
#   01_smhi/output/influenza_weekly.csv
# Expected columns: year, week, incidence_per_100k

flu_path <- here(OUT, "influenza_weekly.csv")
if (file.exists(flu_path)) {
  flu <- read_csv(flu_path, show_col_types = FALSE) |>
    mutate(
      date_monday = ymd(paste0(year, "-W", sprintf("%02d", week), "-1"),
                        quiet = TRUE),
      flu_epidemic = incidence_per_100k > 50   # standard epidemic threshold
    ) |>
    select(date_monday, flu_epidemic)

  # Join to daily: flag any day within an epidemic week
  daily <- daily |>
    mutate(week_monday = floor_date(date, "week", week_start = 1)) |>
    left_join(flu, by = c("week_monday" = "date_monday")) |>
    mutate(flu_flag = replace_na(flu_epidemic, FALSE)) |>
    select(-week_monday, -flu_epidemic)

  flu_days <- sum(daily$flu_flag)
  message("\nInfluenza epidemic days flagged: ", flu_days)
} else {
  daily <- daily |> mutate(flu_flag = FALSE)
  message("\nInfluenza data not found at ", flu_path,
          "\nDownload from Folkhälsomyndigheten and re-run to add flu flags.")
}

# ── Convert flags to integer for modelling -----------------------------------
daily <- daily |>
  mutate(across(ends_with("_flag"), as.integer))

# ── Save ---------------------------------------------------------------------
saveRDS(daily,  here(OUT, "daily_skane.rds"))
saveRDS(events, here(OUT, "extreme_events.rds"))
write_csv(events, here(OUT, "extreme_events.csv"))

# ── Summary ------------------------------------------------------------------
summary_lines <- c(
  "Extreme weather event summary — Skåne 2010–2023",
  paste0("Period: ", min(daily$date), " – ", max(daily$date)),
  paste0("Total days: ", nrow(daily)),
  "",
  paste0("Heat wave days (Tmax≥", HEAT_TMAX, "°C, Tmean≥", HEAT_TMEAN, "°C): ",
         sum(daily$heat_flag, na.rm = TRUE)),
  paste0("Cold snap days (Tmin≤", COLD_TMIN, "°C):  ",
         sum(daily$cold_flag, na.rm = TRUE)),
  paste0("Heavy rain days (≥", RAIN_MM, "mm):        ",
         sum(daily$rain_flag, na.rm = TRUE)),
  "",
  "Events identified:",
  capture.output(
    events |> count(event_type, name = "n_events") |> print()
  ),
  "",
  "2018 and 2022 index heatwaves:",
  capture.output(print(index_heatwaves))
)

writeLines(summary_lines, here(OUT, "event_summary.txt"))
message(paste(summary_lines, collapse = "\n"))

message("\nDone. Next: source(here('02_betsi/fetch_betsi.R'))")
