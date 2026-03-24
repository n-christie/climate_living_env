# =============================================================================
# 06_integrate/build_exposure_matrix.R
# Joins all sources into an exposure matrix ready to link to Register RELOC-AGE.
#
# Structure: one row per (date × insulation_era)
# This links to your cohort via: date of event + building typology of residence
#
# The 2018 and 2022 index heatwaves from both proposals are flagged explicitly.
# SÄBO residents should be identified via NRCSSEPI and handled separately
# before linking — see note in output file.
#
# Output:
#   06_integrate/output/exposure_matrix.rds
#   06_integrate/output/exposure_matrix.csv   (for sharing/inspection)
#   06_integrate/output/data_summary.txt
# =============================================================================

library(tidyverse)
library(lubridate)
library(here)

OUT <- here("06_integrate/output")
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

HEATING_SETPOINT   <- 21.0   # °C Swedish standard indoor comfort
COOLING_THRESHOLD  <- 26.0   # °C indoor heat discomfort threshold for older adults

# ── Load outdoor weather (prefer ERA5, fall back to SMHI) --------------------
load_weather <- function() {
  era5_path <- here("05_era5/output/era5_skane_daily.rds")
  smhi_path <- here("01_smhi/output/smhi_temperature_daily.rds")
  flags_path <- here("01_smhi/output/daily_skane.rds")

  if (file.exists(era5_path)) {
    message("Weather source: ERA5 (gridded, preferred)")
    w <- readRDS(era5_path) |> mutate(date = as.Date(date))
    source <- "ERA5"
  } else if (file.exists(smhi_path)) {
    message("Weather source: SMHI stations (ERA5 not available)")
    smhi <- readRDS(smhi_path) |> mutate(date = as.Date(date))
    w <- smhi |>
      group_by(date) |>
      summarise(t_mean = median(t_mean, na.rm = TRUE),
                t_max  = median(t_max,  na.rm = TRUE),
                t_min  = median(t_min,  na.rm = TRUE),
                .groups = "drop")
    source <- "SMHI"
  } else {
    stop("No weather data found. Run fetch_smhi.R or fetch_era5.R first.")
  }

  # Merge event flags from define_events.R
  if (file.exists(flags_path)) {
    flags <- readRDS(flags_path) |>
      mutate(date = as.Date(date)) |>
      select(date, ends_with("_flag"))
    w <- left_join(w, flags, by = "date")
  }

  list(data = w, source = source)
}

# ── RC model: apply to a temperature series ----------------------------------
rc_predict <- function(t_out, tau, t_in_0 = HEATING_SETPOINT, dt = 1.0) {
  n    <- length(t_out)
  t_in <- numeric(n)
  t_in[1] <- t_in_0
  alpha <- min(dt / tau, 1.0)
  for (i in seq(2, n)) {
    t_ext <- if (!is.na(t_out[i - 1])) t_out[i - 1] else t_in[i - 1]
    # Heating prevents indoor T dropping below setpoint
    t_target <- max(t_ext, HEATING_SETPOINT)
    t_in[i]  <- t_in[i - 1] + alpha * (t_target - t_in[i - 1])
  }
  t_in
}

# ── Load building thermal parameters -----------------------------------------
betsi_path <- here("02_betsi/output/betsi_thermal_params.rds")
rc_path    <- here("03_fraunhofer/output/rc_model_params.rds")

if (file.exists(betsi_path)) {
  thermal_params <- readRDS(betsi_path)
} else {
  # Fallback defaults if BETSI not yet processed
  thermal_params <- tibble(
    insulation_era     = c("pre_1940","1941_1960","1961_1975","1976_2005","2006_plus"),
    rc_tau_hours       = c(6.0, 5.0, 3.5, 8.0, 14.0),
    thermal_vuln_score = c(0.85, 0.80, 0.90, 0.50, 0.25)
  )
}

base_tau <- if (file.exists(rc_path)) {
  readRDS(rc_path)$mean_tau_hours
} else {
  6.0
}
message("Base RC tau (from Fraunhofer): ", base_tau, " hours")

# ── Main ---------------------------------------------------------------------
message("=" |> rep(55) |> paste(collapse = ""))
message("Building exposure matrix — all sources integrated")
message("=" |> rep(55) |> paste(collapse = ""))

weather_result <- load_weather()
weather <- weather_result$data
message("Weather: ", nrow(weather), " days (", weather_result$source, ")")

# Build exposure: cross-join dates × building epochs
message("Building ", nrow(weather), " days × ",
        nrow(thermal_params), " epochs...")

matrix <- cross_join(
  weather,
  thermal_params |> mutate(insulation_era = as.character(insulation_era))
) |>
  arrange(insulation_era, date) |>

  # Apply RC model per epoch (daily timestep)
  group_by(insulation_era) |>
  mutate(
    indoor_t_mean = rc_predict(t_mean, unique(rc_tau_hours), dt = 24.0),
    indoor_t_max  = indoor_t_mean +
                    (t_max - t_mean) * (1 - exp(-24 / unique(rc_tau_hours))),

    # Heat stress: indoor max above older-adult discomfort threshold
    heat_stress_deg = pmax(indoor_t_max - COOLING_THRESHOLD, 0),

    # Cold stress: indoor mean below heating setpoint (poor insulation/heating failure)
    cold_stress_deg = pmax(HEATING_SETPOINT - indoor_t_mean, 0)
  ) |>
  ungroup() |>

  # Flag the two index heatwaves from the proposals
  mutate(
    index_heatwave_2018 = if ("heat_flag" %in% names(.data))
      as.integer(heat_flag == 1 & year(date) == 2018) else 0L,
    index_heatwave_2022 = if ("heat_flag" %in% names(.data))
      as.integer(heat_flag == 1 & year(date) == 2022) else 0L
  )

# ── Save ---------------------------------------------------------------------
saveRDS(matrix, here(OUT, "exposure_matrix.rds"))
write_csv(matrix, here(OUT, "exposure_matrix.csv"))

message("Exposure matrix: ", nrow(matrix), " rows × ", ncol(matrix), " cols")
message("→ ", here(OUT, "exposure_matrix.rds"))

# ── Summary report ------------------------------------------------------------
summary_lines <- c(
  "Exposure matrix summary",
  "=" |> rep(40) |> paste(collapse = ""),
  paste0("Weather source:   ", weather_result$source),
  paste0("Date range:       ", min(matrix$date), " – ", max(matrix$date)),
  paste0("Building epochs:  ", n_distinct(matrix$insulation_era)),
  paste0("Total rows:       ", format(nrow(matrix), big.mark = ",")),
  "",
  "Indoor temperature estimates (mean over full period):",
  capture.output(
    matrix |>
      group_by(insulation_era) |>
      summarise(
        indoor_t_mean    = round(mean(indoor_t_mean, na.rm = TRUE), 1),
        heat_stress_days = sum(heat_stress_deg > 0, na.rm = TRUE),
        cold_stress_days = sum(cold_stress_deg > 0, na.rm = TRUE),
        .groups = "drop"
      ) |>
      print()
  ),
  "",
  "Index heatwave days (2018 + 2022 combined):",
  paste0("  Miljonprogrammet (1961-1975): ",
    sum(matrix$heat_stress_deg[matrix$insulation_era == "1961_1975"] > 0,
        na.rm = TRUE), " heat-stress days"),
  "",
  "IMPORTANT: SÄBO residents (NRCSSEPI) should be identified and",
  "handled as a separate exposure stratum before linking to RELOC-AGE.",
  "Their indoor thermal environment differs fundamentally from",
  "community-dwelling older adults."
)

writeLines(summary_lines, here(OUT, "data_summary.txt"))
message(paste(summary_lines, collapse = "\n"))

message("\n", "=" |> rep(55) |> paste(collapse = ""))
message("Pipeline complete.")
message("Output: ", here(OUT, "exposure_matrix.rds"))
message("\nTo link to RELOC-AGE:")
message("  1. Join by date + insulation_era (from building register)")
message("  2. Exclude SÄBO placements (NRCSSEPI) or model separately")
message("  3. Use heat_stress_deg as primary thermal exposure variable")
message("  4. index_heatwave_2018 / _2022 for event-specific analyses")
