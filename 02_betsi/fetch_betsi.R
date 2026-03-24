# =============================================================================
# 02_betsi/fetch_betsi.R
# Downloads BETSI open data from Boverket.
# Licence: Open data — attribute "Boverket och BETSI"
# Source: https://www.boverket.se/sv/om-boverket/publicerat-av-boverket/
#                oppna-data/betsi-oppna-data/
#
# Output: 02_betsi/output/betsi_raw/   (xlsx files)
# =============================================================================

library(tidyverse)
library(httr2)
library(curl)
library(here)

OUT_RAW <- here("02_betsi/output/betsi_raw")
dir.create(OUT_RAW, recursive = TRUE, showWarnings = FALSE)

BETSI_PAGE <- "https://www.boverket.se/sv/om-boverket/oppna-data/betsi-oppna-data/databasen-fran-betsi/"

# Boverket consolidated all BETSI files into betsi-v2.zip (as of 2024+)
BETSI_ZIP_URL <- paste0(
  "https://www.boverket.se/contentassets/",
  "bfeba7eb66e24db8aa01ee42b5eafe29/betsi-v2.zip"
)

message("=" |> rep(55) |> paste(collapse = ""))
message("BETSI open data download (betsi-v2.zip)")
message("=" |> rep(55) |> paste(collapse = ""))

zip_dest <- file.path(OUT_RAW, "betsi-v2.zip")

if (file.exists(zip_dest)) {
  message("Already downloaded: ", zip_dest)
} else {
  message("Downloading betsi-v2.zip... ", appendLF = FALSE)
  ok <- tryCatch({
    curl_download(BETSI_ZIP_URL, zip_dest, quiet = TRUE)
    TRUE
  }, error = function(e) { message("ERROR: ", e$message); FALSE })

  if (ok) {
    message("OK (", round(file.size(zip_dest) / 1024), " KB)")
  } else {
    message("FAILED — download manually from:\n  ", BETSI_PAGE)
    stop("Could not download BETSI data.")
  }
}

# Extract zip
message("Extracting betsi-v2.zip → ", OUT_RAW)
unzip(zip_dest, exdir = OUT_RAW, overwrite = FALSE)

csv_files <- list.files(file.path(OUT_RAW, "betsi"), pattern = "\\.csv$", full.names = TRUE)
message(length(csv_files), " CSV files extracted: ",
        paste(basename(csv_files), collapse = ", "))

message("\nDone. Next: source(here('02_betsi/process_betsi.R'))")
