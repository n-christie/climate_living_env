# =============================================================================
# 10_epc/fetch_epc.R
# Downloads Swedish Energy Performance Certificates (energideklarationer)
# from Boverket's API for buildings in Skåne.
#
# API endpoint: https://api.boverket.se/energideklarationer
# Auth: Ocp-Apim-Subscription-Key header (Azure API Management)
# Registration: https://www.boverket.se/sv/om-boverket/publicerat-av-boverket/oppna-data/
#   — create a free account and subscribe to the energideklarationer API product
#
# Set key in ~/.Renviron:
#   BOVERKET_API_KEY=your_subscription_key_here
#
# Variables per certificate:
#   - energiklass (A-G energy class)
#   - energiprestanda (kWh/m²/year primary energy use)
#   - byggnadskategori (building type)
#   - byggnadsår / deklarationsår
#   - uppvarmningssatt (heating system)
#   - fastighetsbeteckning (property ID → links to REPR in RELOC-AGE)
#   - adress, postnummer, koordinater
#
# Output:
#   10_epc/output/epc_skane_raw.rds     — all certificates in Skåne
#   10_epc/output/epc_skane.rds         — cleaned, with insulation era + RC params
# =============================================================================

library(here)
library(dplyr)
library(tidyr)
library(purrr)
library(lubridate)
library(curl)
library(jsonlite)

OUT      <- here("10_epc/output")
BASE_URL <- "https://api.boverket.se/energideklarationer"

# ── API key check ─────────────────────────────────────────────────────────────
API_KEY <- Sys.getenv("BOVERKET_API_KEY")

if (nchar(API_KEY) == 0) {
  message("
  ── BOVERKET_API_KEY required ────────────────────────────────────────────────
  Register for a free key at:
    https://www.boverket.se/sv/om-boverket/publicerat-av-boverket/oppna-data/

  1. Create an account and subscribe to the 'Energideklarationer' API product
  2. Your subscription key will appear in your profile / subscriptions page
  3. Add to ~/.Renviron:
       BOVERKET_API_KEY=your_subscription_key_here

  Or set temporarily in R:
    Sys.setenv(BOVERKET_API_KEY = 'yourkey')
  ────────────────────────────────────────────────────────────────────────────
  ")
  stop("BOVERKET_API_KEY not set — see instructions above")
}

# Skåne municipality codes (SCB codes 1214–1293)
SKANE_MUNICIPALITIES <- c(
  "1214", "1230", "1231", "1233", "1256", "1257", "1260", "1261", "1262",
  "1263", "1264", "1265", "1266", "1267", "1270", "1272", "1273", "1275",
  "1276", "1277", "1278", "1280", "1281", "1282", "1283", "1284", "1285",
  "1286", "1287", "1290", "1291", "1292", "1293"
)

# ── Test API connectivity ─────────────────────────────────────────────────────
message("Testing Boverket EPC API...")
test_url <- paste0(BASE_URL, "?kommunKod=1280&pageSize=5")

new_handle_with_key <- function() {
  h <- curl::new_handle()
  curl::handle_setheaders(h,
    "Accept"                   = "application/json",
    "Ocp-Apim-Subscription-Key" = API_KEY
  )
  h
}

test_result <- tryCatch({
  resp <- curl::curl_fetch_memory(test_url, handle = new_handle_with_key())
  if (resp$status_code == 200) {
    fromJSON(rawToChar(resp$content))
  } else if (resp$status_code == 401) {
    stop("HTTP 401 — check BOVERKET_API_KEY is correct and the subscription is active")
  } else {
    message("  HTTP ", resp$status_code)
    NULL
  }
}, error = function(e) {
  message("  API error: ", conditionMessage(e))
  NULL
})

if (is.null(test_result)) {
  stop("Cannot reach Boverket API. Check key and network connectivity.")
}

message("API accessible.")
if (is.data.frame(test_result)) {
  message("Fields available: ", paste(names(test_result), collapse = ", "))
} else if ("value" %in% names(test_result)) {
  message("Fields available (OData): ", paste(names(as.data.frame(test_result$value[1, ])), collapse = ", "))
} else if (is.list(test_result)) {
  message("Top-level keys: ", paste(names(test_result), collapse = ", "))
}

# ── Fetch all certificates for Skåne municipalities ──────────────────────────
fetch_municipality <- function(kom_kod, page_size = 500) {
  all_records <- list()
  page <- 1

  repeat {
    url <- sprintf("%s?kommunKod=%s&pageSize=%d&pageNumber=%d",
                   BASE_URL, kom_kod, page_size, page)

    result <- tryCatch({
      resp <- curl::curl_fetch_memory(url, handle = new_handle_with_key())

      if (resp$status_code == 401) {
        stop("HTTP 401 — invalid or expired BOVERKET_API_KEY")
      }
      if (resp$status_code != 200) {
        message("    HTTP ", resp$status_code, " for municipality ", kom_kod, " page ", page)
        return(bind_rows(all_records))
      }

      parsed <- fromJSON(rawToChar(resp$content), flatten = TRUE)

      # Handle different response shapes (direct array vs paginated wrapper)
      if (is.data.frame(parsed)) {
        records <- parsed
      } else if ("value" %in% names(parsed)) {
        records <- as.data.frame(parsed$value)
      } else if ("data" %in% names(parsed)) {
        records <- as.data.frame(parsed$data)
      } else if ("results" %in% names(parsed)) {
        records <- as.data.frame(parsed$results)
      } else {
        records <- as.data.frame(parsed)
      }

      records
    }, error = function(e) {
      message("    Error page ", page, ": ", conditionMessage(e))
      NULL
    })

    if (is.null(result) || nrow(result) == 0) break
    all_records[[page]] <- result
    if (nrow(result) < page_size) break   # last page
    page <- page + 1
    Sys.sleep(0.2)   # be polite to the API
  }

  bind_rows(all_records)
}

# Check for existing raw file
raw_path <- file.path(OUT, "epc_skane_raw.rds")

if (!file.exists(raw_path)) {
  message("\nFetching EPCs for ", length(SKANE_MUNICIPALITIES),
          " Skåne municipalities...")

  epc_list <- map(SKANE_MUNICIPALITIES, function(k) {
    message("  Municipality ", k, "...")
    result <- fetch_municipality(k)
    message("    ", nrow(result), " certificates")
    result
  })

  epc_raw <- bind_rows(epc_list)
  message("\nTotal certificates: ", nrow(epc_raw))
  saveRDS(epc_raw, raw_path)
} else {
  message("Loading existing EPC data...")
  epc_raw <- readRDS(raw_path)
  message("  ", nrow(epc_raw), " certificates loaded")
}

# ── Clean and derive insulation era + thermal parameters ──────────────────────
if (nrow(epc_raw) > 0) {
  message("\nColumns: ", paste(names(epc_raw), collapse = ", "))

  # Standardise column names (API may return Swedish or English names)
  epc <- epc_raw |>
    rename_with(tolower) |>
    rename(
      energy_class       = any_of(c("energiklass", "energiclass", "energyclass")),
      energy_kwh_m2      = any_of(c("energiprestanda", "energiperformance",
                                    "primaryenergynumber")),
      building_type      = any_of(c("byggnadskategori", "buildingcategory")),
      build_year         = any_of(c("byggnadsår", "constructionyear", "buildingyear")),
      decl_year          = any_of(c("deklarationsår", "declarationyear")),
      heating_system     = any_of(c("uppvarmningssatt", "heatingsystem")),
      property_id        = any_of(c("fastighetsbeteckning", "propertydesignation")),
      lat                = any_of(c("latitud", "latitude", "lat")),
      lon                = any_of(c("longitud", "longitude", "lon"))
    ) |>
    mutate(
      build_year    = as.integer(build_year),
      decl_year     = as.integer(decl_year),
      energy_kwh_m2 = as.numeric(energy_kwh_m2),
      # Map to insulation era (consistent with BETSI epochs)
      insulation_era = case_when(
        build_year < 1961              ~ "pre_1961",
        build_year %in% 1961:1975      ~ "1961_1975",
        build_year %in% 1976:1985      ~ "1976_1985",
        build_year %in% 1986:1995      ~ "1986_1995",
        build_year %in% 1996:2005      ~ "1996_2005",
        build_year > 2005              ~ "post_2005",
        TRUE                           ~ NA_character_
      )
    )

  # Summary by energy class and era
  message("\nEnergy class distribution:")
  print(count(epc, energy_class, sort = TRUE) |> head(10))

  message("\nBuildings per insulation era:")
  print(count(epc, insulation_era, sort = TRUE))

  message("\nMean energy use (kWh/m²/year) by era:")
  epc |>
    filter(!is.na(insulation_era), !is.na(energy_kwh_m2)) |>
    group_by(insulation_era) |>
    summarise(
      n           = n(),
      mean_kwh_m2 = mean(energy_kwh_m2, na.rm = TRUE),
      sd_kwh_m2   = sd(energy_kwh_m2,   na.rm = TRUE)
    ) |>
    arrange(insulation_era) |>
    print()

  saveRDS(epc, file.path(OUT, "epc_skane.rds"))
  message("\nSaved epc_skane.rds")
  message("\nNext: use energy_kwh_m2 per era to calibrate RC model tau values,")
  message("replacing the BETSI-derived estimates with empirical EPC data.")
}
