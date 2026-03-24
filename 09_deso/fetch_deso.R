# =============================================================================
# 09_deso/fetch_deso.R
# Downloads SCB DeSO neighbourhood statistics for Skåne via the PxWeb API.
#
# DeSO = Demografiska statistikområden (~5,984 areas, ~800 residents each).
# Used as the neighbourhood-level moderator in RELOC-AGE analyses (O2).
#
# Tables used:
#   BE/BE0101/BE0101Y/FolkmDesoLandKon  — foreign-born share by DeSO
#   BE/BE0101/BE0101Y/FolkmDesoAldKon   — age structure by DeSO
#   HE/HE0110/HE0110I/Tab4InkDesoRegso  — low-income / poverty rate by DeSO
#   HE/HE0110/HE0110I/Tab2InkDesoRegso  — net income by DeSO
#
# DeSO geometries:
#   Downloaded as GeoJSON from SCB's statistical geography service.
#
# Output:
#   09_deso/output/deso_stats_raw.rds   — raw API responses
#   09_deso/output/deso_skane.rds       — sf polygons for Skåne DeSOs
#   09_deso/output/deso_index.rds       — composite deprivation index
# =============================================================================

library(here)
library(dplyr)
library(tidyr)
library(purrr)
library(sf)
library(curl)
library(jsonlite)

OUT     <- here("09_deso/output")
SCB_API <- "https://api.scb.se/OV0104/v1/doris/en/ssd"

# Skåne DeSO codes start with "1214" – "1293" (municipality prefixes)
# In the SCB API, DeSO codes look like "1280C1010" (municipality + sequence)
SKANE_MUNI_PREFIXES <- as.character(c(
  1214, 1230, 1231, 1233, 1256, 1257, 1260, 1261, 1262,
  1263, 1264, 1265, 1266, 1267, 1270, 1272, 1273, 1275,
  1276, 1277, 1278, 1280, 1281, 1282, 1283, 1284, 1285,
  1286, 1287, 1290, 1291, 1292, 1293
))

# ── Helper: POST query to SCB PxWeb API ──────────────────────────────────────
scb_query <- function(table_path, query_json) {
  url  <- paste0(SCB_API, "/", table_path)
  body <- chartr("'", '"', query_json)   # ensure double quotes

  handle <- curl::new_handle(
    post           = TRUE,
    postfieldsize  = nchar(body),
    postfields     = body,
    httpheader     = c("Content-Type" = "application/json")
  )

  resp <- tryCatch({
    r <- curl::curl_fetch_memory(url, handle = handle)
    if (r$status_code != 200) {
      message("  HTTP ", r$status_code, " for ", table_path)
      return(NULL)
    }
    fromJSON(rawToChar(r$content), flatten = TRUE)
  }, error = function(e) {
    message("  Error: ", conditionMessage(e))
    NULL
  })
  resp
}

# ── Helper: flatten SCB JSON response to data frame ──────────────────────────
scb_to_df <- function(resp) {
  if (is.null(resp)) return(NULL)
  cols   <- resp$columns
  values <- resp$data
  if (is.null(values) || length(values) == 0) return(NULL)

  df <- as.data.frame(do.call(rbind, lapply(values, function(row) {
    c(row$key, row$values)
  })), stringsAsFactors = FALSE)

  col_names <- c(cols$code[cols$type == "d"], cols$code[cols$type == "c"])
  if (ncol(df) == length(col_names)) names(df) <- col_names
  df
}

# ── 1. Get all Skåne DeSO codes ───────────────────────────────────────────────
message("Fetching list of Skåne DeSO codes...")

# Query population table to get the region dimension (DeSO codes)
meta_url  <- paste0(SCB_API, "/BE/BE0101/BE0101Y/FolkmDesoAldKon")
meta_resp <- tryCatch({
  r <- curl::curl_fetch_memory(meta_url)
  fromJSON(rawToChar(r$content))
}, error = function(e) NULL)

if (!is.null(meta_resp)) {
  region_var  <- meta_resp$variables[meta_resp$variables$code == "Region", ]
  all_codes   <- region_var$values[[1]]
  all_labels  <- region_var$valueTexts[[1]]

  skane_idx   <- which(substr(all_codes, 1, 4) %in% SKANE_MUNI_PREFIXES)
  skane_codes <- all_codes[skane_idx]
  skane_labels <- all_labels[skane_idx]

  message("  Skåne DeSO areas found: ", length(skane_codes))
} else {
  stop("Could not fetch DeSO metadata from SCB API")
}

# ── 2. Foreign-born share by DeSO (2018) ─────────────────────────────────────
message("Fetching foreign-born share by DeSO...")
foreign_born <- scb_query(
  "BE/BE0101/BE0101Y/FolkmDesoLandKon",
  paste0('{
    "query": [
      {"code": "Region",       "selection": {"filter": "item", "values": ',
         toJSON(skane_codes), '}},
      {"code": "Fodelseregion","selection": {"filter": "item", "values": ["utl"]}},
      {"code": "Kon",          "selection": {"filter": "item", "values": ["1","2"]}},
      {"code": "ContentsCode", "selection": {"filter": "item", "values": ["BE0101N1"]}},
      {"code": "Tid",          "selection": {"filter": "item", "values": ["2018"]}}
    ],
    "response": {"format": "json"}
  }')
)

fb_df <- scb_to_df(foreign_born)
message("  Rows: ", if (!is.null(fb_df)) nrow(fb_df) else "failed")

# ── 3. Age 65+ share by DeSO (2018) ──────────────────────────────────────────
message("Fetching age 65+ population by DeSO...")
age_query <- scb_query(
  "BE/BE0101/BE0101Y/FolkmDesoAldKon",
  paste0('{
    "query": [
      {"code": "Region",       "selection": {"filter": "item", "values": ',
         toJSON(skane_codes), '}},
      {"code": "Alder",        "selection": {"filter": "vs:DeSoÅlder5", "values": [
        "65-69","70-74","75-79","80-84","85-89","90+"]}},
      {"code": "Kon",          "selection": {"filter": "item", "values": ["1","2"]}},
      {"code": "ContentsCode", "selection": {"filter": "item", "values": ["BE0101N1"]}},
      {"code": "Tid",          "selection": {"filter": "item", "values": ["2018"]}}
    ],
    "response": {"format": "json"}
  }')
)

age_df <- scb_to_df(age_query)
message("  Rows: ", if (!is.null(age_df)) nrow(age_df) else "failed")

# ── 4. Low income / poverty rate by DeSO ─────────────────────────────────────
message("Fetching income/poverty data by DeSO...")
income_query <- scb_query(
  "HE/HE0110/HE0110I/Tab4InkDesoRegso",
  paste0('{
    "query": [
      {"code": "Region",       "selection": {"filter": "item", "values": ',
         toJSON(skane_codes), '}},
      {"code": "ContentsCode", "selection": {"filter": "item",
        "values": ["HE0110I3","HE0110I4"]}},
      {"code": "Tid",          "selection": {"filter": "item", "values": ["2018"]}}
    ],
    "response": {"format": "json"}
  }')
)

income_df <- scb_to_df(income_query)
message("  Rows: ", if (!is.null(income_df)) nrow(income_df) else "failed")

# ── 5. Save raw outputs ───────────────────────────────────────────────────────
stats_raw <- list(
  deso_codes   = data.frame(deso = skane_codes, label = skane_labels),
  foreign_born = fb_df,
  age_65plus   = age_df,
  income       = income_df
)
saveRDS(stats_raw, file.path(OUT, "deso_stats_raw.rds"))
message("\nSaved deso_stats_raw.rds")

# ── 6. DeSO geometry — try SCB WFS service ───────────────────────────────────
message("\nDownloading DeSO polygon boundaries...")

# SCB provides DeSO boundaries via WFS (OGC Web Feature Service)
# Filter to Skåne county (lan=12)
wfs_url <- paste0(
  "https://geodata.scb.se/geoserver/stat/ows?",
  "service=WFS&version=2.0.0&request=GetFeature",
  "&typeName=stat:DeSO&outputFormat=application/json",
  "&CQL_FILTER=lan%3D'12'"   # Skåne county code
)

geom_path <- file.path(OUT, "deso_skane_raw.geojson")
geom_result <- tryCatch(
  curl::curl_download(wfs_url, geom_path, quiet = FALSE),
  error = function(e) {
    message("  WFS download failed: ", conditionMessage(e))
    NULL
  }
)

if (!is.null(geom_result) && file.exists(geom_path) && file.size(geom_path) > 1000) {
  deso_sf <- sf::read_sf(geom_path) |> sf::st_make_valid()
  message("  DeSO polygons loaded: ", nrow(deso_sf), " areas")
  saveRDS(deso_sf, file.path(OUT, "deso_skane.rds"))
} else {
  message("  WFS failed. DeSO boundaries not saved.")
  message("  Manual alternative: download from")
  message("  https://www.scb.se/en/finding-statistics/regional-statistics-and-maps/")
  message("  regional-divisions/deso---demographic-statistical-areas/")
}

message("\nDone. Next: join deso_codes to RELOC-AGE individual coordinates via st_join()")
message("then merge deprivation index as O2 resilience moderator.")
