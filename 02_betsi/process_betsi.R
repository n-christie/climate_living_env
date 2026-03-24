# =============================================================================
# 02_betsi/process_betsi.R
# Reads BETSI v2 CSV files, creates building typology with thermal parameters.
#
# BETSI v2 data structure (as of 2024):
#   betsi_raw/betsi/Upprakningstal.csv  — building ID → age class + weights
#   betsi_raw/betsi/FA.csv             — building envelope survey data
#   betsi_raw/betsi/FF.csv             — ventilation data
#
# Age classes in Upprakningstal.csv (ald column):
#   "1 -60"   → pre-1961
#   "2 61-75"  → miljonprogrammet era
#   "3 76-85"  → post-BBR 75
#   "4 86-95"  → 1986-1995
#   "5 96-05"  → 1996-2005
#
# Key outputs:
#   betsi_buildings.rds       — harmonised building-level data
#   betsi_typology.rds        — building epoch × type summaries
#   betsi_thermal_params.rds  — RC model priors by insulation epoch
# =============================================================================

library(tidyverse)
library(here)

RAW <- here("02_betsi/output/betsi_raw/betsi")
OUT <- here("02_betsi/output")

# ── Insulation epoch lookup ---------------------------------------------------
# Mapped from BETSI v2 age classes to BBR-era labels used in the pipeline
EPOCH_LABELS <- c("pre_1961", "1961_1975", "1976_1985", "1986_1995", "1996_2005")

ALT_MAP <- c(
  "1 -60"  = "pre_1961",
  "2 61-75" = "1961_1975",
  "3 76-85" = "1976_1985",
  "4 86-95" = "1986_1995",
  "5 96-05" = "1996_2005"
)

# Thermal vulnerability index (higher = more exposed to heat/cold extremes)
# miljonprogrammet (1961-75) is worst: thin concrete, minimal insulation
THERMAL_VULN <- c(
  pre_1961   = 0.82,
  `1961_1975` = 0.90,
  `1976_1985` = 0.55,
  `1986_1995` = 0.40,
  `1996_2005` = 0.30
)

# RC time constant (hours) — larger τ = slower response to outdoor T
RC_TAU <- c(
  pre_1961   = 5.5,
  `1961_1975` = 3.5,
  `1976_1985` = 7.0,
  `1986_1995` = 9.0,
  `1996_2005` = 12.0
)

# ── Load Upprakningstal (age class + weights) ----------------------------------
load_upprakningstal <- function() {
  path <- file.path(RAW, "Upprakningstal.csv")
  if (!file.exists(path)) {
    message("  Not found: Upprakningstal.csv")
    return(NULL)
  }
  read_delim(path, delim = ";", locale = locale(encoding = "latin1"),
             col_types = cols(.default = "c"), show_col_types = FALSE) |>
    select(building_id = Byggnad, hustyp = Hustyp, ald,
           weight = kalib_vikt) |>
    mutate(
      insulation_era = factor(ALT_MAP[ald], levels = EPOCH_LABELS),
      building_type  = case_when(
        hustyp == "S" ~ "single_family",
        hustyp == "F" ~ "multi_dwelling",
        TRUE          ~ "other"
      ),
      weight = as.numeric(str_replace(weight, ",", "."))
    )
}

# ── Load FA (building characteristics) ----------------------------------------
load_fa <- function() {
  path <- file.path(RAW, "FA.csv")
  if (!file.exists(path)) {
    message("  Not found: FA.csv")
    return(NULL)
  }
  read_delim(path, delim = ";", locale = locale(encoding = "latin1"),
             col_types = cols(.default = "c"), show_col_types = FALSE) |>
    select(
      building_id   = Byggnad,
      hustyp        = Hustyp,
      floor_area_m2 = FA14BOA,
      n_floors      = FA16AntalPlanOvanMark
    ) |>
    mutate(
      floor_area_m2 = as.numeric(str_replace(floor_area_m2, ",", ".")),
      n_floors      = as.integer(n_floors)
    )
}

# ── Load FF (ventilation type) -------------------------------------------------
load_ff <- function() {
  path <- file.path(RAW, "FF.csv")
  if (!file.exists(path)) {
    message("  Not found: FF.csv (ventilation) — skipping")
    return(NULL)
  }
  df <- read_delim(path, delim = ";", locale = locale(encoding = "latin1"),
                   col_types = cols(.default = "c"), show_col_types = FALSE)
  # Find ventilation type column (FF1 or similar)
  vent_col <- names(df)[str_detect(names(df), "FF1|FF2|Ventilation|ventilation")][1]
  if (is.na(vent_col)) return(select(df, building_id = Byggnad))
  df |>
    select(building_id = Byggnad, ventilation_type = all_of(vent_col))
}

# ── Load FB moisture data ------------------------------------------------------
load_moisture <- function() {
  path <- file.path(RAW, "FB_OVRIGT.csv")
  if (!file.exists(path)) return(NULL)
  df <- read_delim(path, delim = ";", locale = locale(encoding = "latin1"),
                   col_types = cols(.default = "c"), show_col_types = FALSE)
  # FB columns with moisture/mold flags
  moist_cols <- names(df)[str_detect(names(df), "(?i)fukt|m.gel|P.v.xt")]
  if (length(moist_cols) == 0) return(select(df, building_id = Byggnad))
  df |>
    select(building_id = Byggnad, all_of(moist_cols[1:min(3, length(moist_cols))])) |>
    mutate(
      moisture_risk = as.integer(
        rowSums(across(all_of(moist_cols[1:min(3, length(moist_cols))]),
                       \(x) x %in% c("Ja", "ja", "1", "JaDet")),
                na.rm = TRUE) > 0
      )
    ) |>
    select(building_id, moisture_risk)
}

# ── Main ---------------------------------------------------------------------
message("=" |> rep(55) |> paste(collapse = ""))
message("BETSI v2 processing — building typology from CSVs")
message("=" |> rep(55) |> paste(collapse = ""))

meta    <- load_upprakningstal()
fa      <- load_fa()
ff      <- load_ff()
moist   <- load_moisture()

message("Upprakningstal: ", nrow(meta), " buildings")
message("FA:             ", nrow(fa),   " buildings")

buildings <- meta |>
  filter(building_type != "other") |>
  left_join(fa   |> select(-hustyp), by = "building_id") |>
  left_join(ff,    by = "building_id")

if (!is.null(moist)) {
  buildings <- left_join(buildings, moist, by = "building_id")
}

if (!"moisture_risk" %in% names(buildings)) buildings$moisture_risk <- 0L
buildings <- buildings |>
  mutate(moisture_risk = replace_na(moisture_risk, 0L)) |>
  filter(!is.na(insulation_era))

saveRDS(buildings, here(OUT, "betsi_buildings.rds"))
message("\nBuildings: ", nrow(buildings), " rows → betsi_buildings.rds")
message("Types: ", paste(table(buildings$building_type), collapse = " / "),
        " (multi/single)")
message("Epochs:\n")
print(table(buildings$insulation_era, buildings$building_type))

# ── Typology summary ----------------------------------------------------------
typology <- buildings |>
  group_by(building_type, insulation_era) |>
  summarise(
    n               = n(),
    moisture_pct    = mean(moisture_risk, na.rm = TRUE),
    mean_floors     = mean(n_floors, na.rm = TRUE),
    .groups = "drop"
  ) |>
  mutate(
    thermal_vuln_score = THERMAL_VULN[as.character(insulation_era)],
    rc_tau_hours       = RC_TAU[as.character(insulation_era)]
  )

saveRDS(typology, here(OUT, "betsi_typology.rds"))
write_csv(typology, here(OUT, "betsi_typology.csv"))
message("\nTypology:\n")
print(typology)

# ── RC model thermal parameters ----------------------------------------------
thermal_params <- tibble(
  insulation_era     = names(RC_TAU),
  rc_tau_hours       = unname(RC_TAU),
  thermal_vuln_score = unname(THERMAL_VULN[names(RC_TAU)])
) |>
  mutate(insulation_era = factor(insulation_era, levels = EPOCH_LABELS))

saveRDS(thermal_params, here(OUT, "betsi_thermal_params.rds"))
write_csv(thermal_params, here(OUT, "betsi_thermal_params.csv"))
message("\nRC thermal parameters:\n")
print(thermal_params)

message("\nDone. Next: source(here('03_fraunhofer/fetch_fraunhofer.R'))")
