# =============================================================================
# figures/make_maps.R
# Produces figures for project_aims.md:
#   fig_01_study_area.png  — Skåne with SMHI stations and ERA5 grid
#   fig_02_heatwave.png    — Mean summer Tmax per station + heatwave events
# =============================================================================

library(here)
library(sf)
library(ggplot2)
library(dplyr)
library(tidyr)
library(lubridate)
library(patchwork)
library(scales)

OUT <- here("figures")

# ── 0.  Colour palette  -------------------------------------------------------
col_skane    <- "#d6e8f5"
col_sweden   <- "#eef2ec"
col_denmark  <- "#f5ece6"
col_era5     <- "#4a90d9"
col_station  <- "#c0392b"
col_heat     <- "#e74c3c"
col_cold     <- "#2980b9"

# ── 1.  Spatial data  ---------------------------------------------------------

## Swedish region boundaries (okfse GeoJSON, 21 regions)
geojson_url <- "https://raw.githubusercontent.com/okfse/sweden-geojson/master/swedish_regions.geojson"
geojson_tmp <- file.path(tempdir(), "swedish_regions.geojson")
if (!file.exists(geojson_tmp)) download.file(geojson_url, geojson_tmp, quiet = TRUE)
regions_sf  <- read_sf(geojson_tmp) |> st_make_valid()
skane_sf    <- regions_sf |> filter(name == "Skåne")
sweden_sf   <- regions_sf |> filter(name != "Skåne")

## Denmark and Germany from the maps package (for geographic context)
world_map <- maps::map("world",
                       regions = c("Denmark", "Germany"),
                       plot = FALSE, fill = TRUE)
nbr_sf <- st_as_sf(world_map) |> st_make_valid()

## ERA5 0.25° grid centroids over the Skåne bounding box
era5_grid <- expand.grid(
  lon = seq(12.50, 14.50, by = 0.25),
  lat = seq(55.25, 56.50, by = 0.25)
)

# ── 2.  Station data  ---------------------------------------------------------
station_daily <- readRDS(here("01_smhi/output/smhi_temperature_daily.rds")) |>
  mutate(date = as.Date(date))

stations <- station_daily |>
  distinct(station_id, station_name, lat, lon) |>
  # Shorten long names for label placement
  mutate(label = case_when(
    grepl("Sturup",      station_name) ~ "Sturup",
    grepl("Ängelholm",   station_name) ~ "Ängelholm",
    grepl("Helsingborg", station_name) ~ "Helsingborg",
    grepl("Hallands",    station_name) ~ "Hallands Väderö",
    grepl("Falsterbo",   station_name) ~ "Falsterbo",
    grepl("Skillinge",   station_name) ~ "Skillinge",
    grepl("Malmö A",     station_name) ~ "Malmö",
    TRUE ~ station_name
  ))

## Mean summer (JJA) Tmax per station across full record
station_summer <- station_daily |>
  filter(month(date) %in% 6:8) |>
  group_by(station_id, station_name, lat, lon) |>
  summarise(mean_tmax_jja = mean(t_max, na.rm = TRUE),
            heat_days     = sum(t_max >= 25, na.rm = TRUE),
            .groups = "drop")

stations <- left_join(stations, station_summer, by = c("station_id","station_name","lat","lon"))

# ── 3.  Event timeline data  --------------------------------------------------
events   <- readRDS(here("01_smhi/output/extreme_events.rds"))
daily_sk <- readRDS(here("01_smhi/output/daily_skane.rds")) |>
  mutate(date = as.Date(date), year = year(date))

annual_heat <- daily_sk |>
  mutate(heat_day = t_max >= 25 & t_mean >= 20) |>
  group_by(year) |>
  summarise(heat_days  = sum(heat_day,  na.rm = TRUE),
            cold_days  = sum(t_min <= -10, na.rm = TRUE),
            .groups    = "drop") |>
  pivot_longer(c(heat_days, cold_days), names_to = "type", values_to = "days") |>
  mutate(type = recode(type, heat_days = "Heat-stress days (Tmax ≥ 25°C, Tmean ≥ 20°C)",
                              cold_days = "Cold-stress days (Tmin ≤ −10°C)"))

# ── 4.  Figure 1: Study-area map  ---------------------------------------------

map_xlim <- c(12.40, 14.60)
map_ylim <- c(55.15, 56.60)

## Nudge labels so they don't overlap stations
label_nudge <- tribble(
  ~label,              ~nudge_x,  ~nudge_y,
  "Falsterbo",          -0.20,    -0.07,
  "Malmö",              -0.22,    -0.06,
  "Sturup",             -0.00,    -0.10,
  "Lund",               -0.22,     0.00,
  "Hörby",               0.12,     0.04,
  "Skillinge",           0.15,     0.00,
  "Helsingborg",        -0.22,     0.00,
  "Ängelholm",          -0.26,     0.05,
  "Hallands Väderö",    -0.32,     0.05,
  "Hästveda",            0.14,     0.04,
  "Osby",                0.12,     0.00,
  "Kristianstad",        0.15,     0.00
)
stations_plot <- left_join(stations, label_nudge, by = "label") |>
  mutate(nudge_x = replace_na(nudge_x, 0.1),
         nudge_y = replace_na(nudge_y, 0.0))

fig1 <- ggplot() +
  # Neighbouring countries
  geom_sf(data = nbr_sf, fill = col_denmark, colour = "gray60", linewidth = 0.25) +
  # Swedish regions (background)
  geom_sf(data = sweden_sf, fill = col_sweden, colour = "gray65", linewidth = 0.2) +
  # Skåne highlighted
  geom_sf(data = skane_sf, fill = col_skane, colour = "gray30", linewidth = 0.5) +
  # ERA5 grid cells (tiles)
  geom_tile(data = era5_grid,
            aes(x = lon, y = lat),
            fill = NA, colour = col_era5, alpha = 0.6,
            width = 0.25, height = 0.25, linewidth = 0.35) +
  # ERA5 grid centroids
  geom_point(data = era5_grid,
             aes(x = lon, y = lat),
             shape = 3, colour = col_era5, size = 1.2, alpha = 0.7) +
  # Stations coloured by mean summer Tmax
  geom_point(data = stations_plot,
             aes(x = lon, y = lat, fill = mean_tmax_jja),
             shape = 21, size = 4, colour = "white", stroke = 0.8) +
  scale_fill_gradient(low = "#f7dc6f", high = "#c0392b",
                      name = "Mean summer\nTmax (°C)",
                      breaks = pretty_breaks(4)) +
  # Station labels
  geom_text(data = stations_plot,
            aes(x = lon + nudge_x, y = lat + nudge_y, label = label),
            size = 2.5, colour = "gray15", fontface = "plain") +
  # Map extent
  coord_sf(xlim = map_xlim, ylim = map_ylim, expand = FALSE) +
  # Annotations
  annotate("text", x = 13.8, y = 55.22, label = "Baltic Sea",
           colour = "gray50", size = 2.8, fontface = "italic") +
  annotate("text", x = 12.55, y = 55.60, label = "Øresund",
           colour = "gray50", size = 2.5, fontface = "italic", angle = 75) +
  annotate("text", x = 14.40, y = 56.52, label = "Skåne",
           colour = "gray20", size = 3.5, fontface = "bold") +
  # Legend annotation for ERA5
  annotate("point", x = 12.62, y = 55.22, shape = 3,
           colour = col_era5, size = 2) +
  annotate("text",  x = 12.75, y = 55.22,
           label = "ERA5 0.25° grid", colour = col_era5, size = 2.5, hjust = 0) +
  labs(title    = "Study area: Skåne, southern Sweden",
       subtitle = "SMHI temperature stations and ERA5 reanalysis grid (2010–2023)",
       x = NULL, y = NULL) +
  theme_minimal(base_size = 11) +
  theme(
    panel.background  = element_rect(fill = "#d0e8f5", colour = NA),
    panel.grid.major  = element_line(colour = "white", linewidth = 0.3),
    legend.position   = c(0.88, 0.25),
    legend.background = element_rect(fill = alpha("white", 0.85), colour = NA),
    legend.key.size   = unit(0.5, "cm"),
    legend.title      = element_text(size = 8),
    legend.text       = element_text(size = 7),
    plot.title        = element_text(face = "bold", size = 12),
    plot.subtitle     = element_text(size = 9, colour = "gray40")
  )

# ── 5.  Figure 2: Annual heat- and cold-stress days  -------------------------

heat_colour <- "#c0392b"
cold_colour <- "#2980b9"

fig2 <- ggplot(annual_heat, aes(x = year, y = days, fill = type)) +
  geom_col(position = "dodge", width = 0.7, alpha = 0.85) +
  # Mark index heatwave years
  geom_vline(xintercept = c(2018, 2022) - 0.01,
             colour = heat_colour, linetype = "dashed", linewidth = 0.5, alpha = 0.6) +
  annotate("text", x = 2018.3, y = Inf, label = "2018 heatwave",
           vjust = 1.5, hjust = 0, size = 2.8, colour = heat_colour) +
  annotate("text", x = 2022.3, y = Inf, label = "2022 heatwave",
           vjust = 1.5, hjust = 0, size = 2.8, colour = heat_colour) +
  scale_fill_manual(values = c(
    "Heat-stress days (Tmax ≥ 25°C, Tmean ≥ 20°C)" = heat_colour,
    "Cold-stress days (Tmin ≤ −10°C)"               = cold_colour
  )) +
  scale_x_continuous(breaks = 2010:2023) +
  labs(
    title    = "Annual thermal-stress days — Skåne 2010–2023",
    subtitle = "Median across SMHI stations; heat-stress thresholds as used in exposure model",
    x = NULL, y = "Days per year",
    fill = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.grid.minor  = element_blank(),
    panel.grid.major.x = element_blank(),
    axis.text.x       = element_text(angle = 45, hjust = 1, size = 8),
    legend.position   = "bottom",
    legend.text       = element_text(size = 8),
    plot.title        = element_text(face = "bold", size = 12),
    plot.subtitle     = element_text(size = 9, colour = "gray40")
  )

# ── 6.  Save  -----------------------------------------------------------------
ggsave(file.path(OUT, "fig_01_study_area.png"),  fig1, width = 7, height = 6,   dpi = 180)
ggsave(file.path(OUT, "fig_02_heatwave.png"),    fig2, width = 8, height = 4.5, dpi = 180)

message("Saved:\n  figures/fig_01_study_area.png\n  figures/fig_02_heatwave.png")
