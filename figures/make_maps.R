# =============================================================================
# figures/make_maps.R
# Produces figures for project_aims.md:
#   fig_01_study_area.png  — Skåne with SMHI stations and ERA5 grid
#   fig_02_heatwave.png    — Heat wave and cold snap event days per year
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

# ── 0.  Colours  --------------------------------------------------------------
col_skane   <- "#dceef7"
col_sweden  <- "#edf0eb"
col_nbr     <- "#ede8e0"
col_era5    <- "#5b9bd5"
col_sea     <- "#cce4f0"

# ── 1.  Spatial data  ---------------------------------------------------------

geojson_tmp <- file.path(tempdir(), "swedish_regions.geojson")
if (!file.exists(geojson_tmp))
  download.file(
    "https://raw.githubusercontent.com/okfse/sweden-geojson/master/swedish_regions.geojson",
    geojson_tmp, quiet = TRUE
  )
regions_sf <- read_sf(geojson_tmp) |> st_make_valid()
skane_sf   <- regions_sf |> filter(name == "Skåne")
sweden_sf  <- regions_sf |> filter(name != "Skåne")

world_map <- maps::map("world", regions = c("Denmark", "Germany"),
                       plot = FALSE, fill = TRUE)
nbr_sf <- st_as_sf(world_map) |> st_make_valid()

# ERA5 0.25° grid tiles — represented as sf rectangles for clean rendering
era5_pts <- expand.grid(
  lon = seq(12.50, 14.50, by = 0.25),
  lat = seq(55.25, 56.50, by = 0.25)
)
half <- 0.125
era5_cells <- era5_pts |>
  rowwise() |>
  mutate(geometry = list(st_polygon(list(matrix(
    c(lon - half, lat - half,
      lon + half, lat - half,
      lon + half, lat + half,
      lon - half, lat + half,
      lon - half, lat - half),
    ncol = 2, byrow = TRUE
  ))))) |>
  ungroup() |>
  st_as_sf(crs = 4326)

# ── 2.  Station data  ---------------------------------------------------------
station_daily <- readRDS(here("01_smhi/output/smhi_temperature_daily.rds")) |>
  mutate(date = as.Date(date))

stations_base <- station_daily |>
  distinct(station_id, station_name, lat, lon)

# Spatial join: flag stations inside Skåne polygon
sta_sf <- st_as_sf(stations_base, coords = c("lon", "lat"), crs = 4326)
in_skane <- as.logical(st_within(sta_sf, skane_sf, sparse = FALSE))
stations_base$in_skane <- in_skane

# Mean summer (JJA) Tmax per station
station_summer <- station_daily |>
  filter(month(date) %in% 6:8) |>
  group_by(station_id, station_name, lat, lon) |>
  summarise(mean_tmax_jja = mean(t_max, na.rm = TRUE), .groups = "drop")

stations <- left_join(stations_base, station_summer,
                      by = c("station_id", "station_name", "lat", "lon")) |>
  # Override: Falsterbo is on the Falsterbo peninsula (Vellinge municipality, Skåne)
  # but the simplified GeoJSON polygon does not capture this narrow peninsula
  mutate(in_skane = if_else(grepl("Falsterbo", station_name), TRUE, in_skane)) |>
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

# Label nudges to avoid overlap
label_nudge <- tribble(
  ~label,              ~nudge_x, ~nudge_y,
  "Falsterbo",          -0.23,   -0.07,
  "Malmö",              -0.20,   -0.07,
  "Sturup",              0.03,   -0.09,
  "Hörby A",             0.14,    0.03,
  "Skillinge",          -0.22,   -0.07,
  "Helsingborg",        -0.24,    0.03,
  "Ängelholm",          -0.27,    0.04,
  "Hästveda",            0.14,    0.03,
  "Osby",                0.12,    0.00,
  "Kristianstad",        0.15,    0.00
)
stations <- left_join(stations, label_nudge, by = "label") |>
  mutate(nudge_x = replace_na(nudge_x, 0.1),
         nudge_y = replace_na(nudge_y, 0.0))

sta_inside  <- filter(stations, in_skane)
# sta_outside (Hallands Väderö) dropped from main panel — noted in caption

# ── 3.  Figure 1: Study-area map  --------------------------------------------

map_xlim <- c(12.38, 14.62)
map_ylim <- c(55.14, 56.65)

# Scale bar: 50 km. At ~55.9°N, 1° lon ≈ 62 km → 50 km ≈ 0.81°
sb_x0 <- 12.44; sb_x1 <- 12.44 + 0.81
sb_y  <- 55.185; sb_tick <- 0.018

fig1 <- ggplot() +
  # Neighbouring countries
  geom_sf(data = nbr_sf,   fill = col_nbr,   colour = "gray60", linewidth = 0.25) +
  # Swedish regions
  geom_sf(data = sweden_sf, fill = col_sweden, colour = "gray65", linewidth = 0.18) +
  # Skåne
  geom_sf(data = skane_sf,  fill = col_skane, colour = "gray25", linewidth = 0.55) +
  # ERA5 grid cells — faint dashed grey, background reference only
  geom_sf(data = era5_cells,
          fill = NA, colour = "grey72",
          linewidth = 0.15, linetype = "dashed") +
  # Stations INSIDE Skåne — filled circles, coloured by mean summer Tmax
  geom_point(data = sta_inside,
             aes(x = lon, y = lat, fill = mean_tmax_jja),
             shape = 21, size = 4.2, colour = "white", stroke = 0.8,
             na.rm = TRUE) +
  # Colour scale: widened to 16–24°C so 1–2°C coastal gradient reads as modest
  scale_fill_gradient(low = "#f5c842", high = "#b03a2e",
                      name = "Mean Jun–Aug\nTmax (°C)",
                      limits = c(16, 24),
                      breaks = seq(16, 24, by = 2),
                      na.value = "grey60",
                      guide  = guide_colourbar(barheight = 4.5, barwidth = 0.8)) +
  # Station labels — inside Skåne only
  geom_text(data = sta_inside,
            aes(x = lon + nudge_x, y = lat + nudge_y, label = label),
            size = 2.6, colour = "gray15") +
  # Geographic labels
  annotate("text", x = 14.00, y = 55.21, label = "Baltic Sea",
           colour = "gray45", size = 2.8, fontface = "italic") +
  annotate("text", x = 12.57, y = 55.60, label = "Øresund",
           colour = "gray45", size = 2.4, fontface = "italic", angle = 75) +
  annotate("text", x = 14.42, y = 56.54, label = "Skåne",
           colour = "gray20", size = 3.8, fontface = "bold") +
  # Scale bar
  annotate("segment", x = sb_x0, xend = sb_x1, y = sb_y,  yend = sb_y,
           colour = "gray20", linewidth = 0.8) +
  annotate("segment", x = sb_x0, xend = sb_x0, y = sb_y - sb_tick, yend = sb_y + sb_tick,
           colour = "gray20", linewidth = 0.8) +
  annotate("segment", x = sb_x1, xend = sb_x1, y = sb_y - sb_tick, yend = sb_y + sb_tick,
           colour = "gray20", linewidth = 0.8) +
  annotate("text", x = (sb_x0 + sb_x1) / 2, y = sb_y - 0.028,
           label = "50 km", colour = "gray20", size = 2.3, hjust = 0.5) +
  coord_sf(xlim = map_xlim, ylim = map_ylim, expand = FALSE) +
  labs(
    title = "SMHI station temperatures, Skåne — mean Jun–Aug Tmax (2010–2023)",
    x = NULL, y = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.background   = element_rect(fill = col_sea, colour = NA),
    panel.grid.major   = element_line(colour = alpha("white", 0.7), linewidth = 0.3),
    panel.grid.minor   = element_blank(),
    legend.position    = c(0.905, 0.30),
    legend.background  = element_rect(fill = alpha("white", 0.88), colour = NA),
    legend.key.size    = unit(0.5, "cm"),
    legend.title       = element_text(size = 8),
    legend.text        = element_text(size = 7.5),
    plot.title         = element_text(face = "bold", size = 11),
    plot.subtitle      = element_blank()
  )

# ── 4.  Figure 2: Heat wave and cold snap event days per year  ----------------

events <- readRDS(here("01_smhi/output/extreme_events.rds"))

expand_event_days <- function(ev, type_filter) {
  ev |>
    filter(event_type == type_filter) |>
    rowwise() |>
    mutate(d = list(seq(start, end, by = "day"))) |>
    unnest(d) |>
    mutate(year = year(d))
}

heat_by_yr <- expand_event_days(events, "heat_wave") |>
  count(year, name = "days") |>
  mutate(type = "heat_wave")

cold_by_yr <- expand_event_days(events, "cold_snap") |>
  count(year, name = "days") |>
  mutate(type = "cold_snap")

all_years <- tibble(year = 2010:2023)
annual <- bind_rows(
  left_join(all_years, heat_by_yr, by = "year") |> replace_na(list(days = 0, type = "heat_wave")),
  left_join(all_years, cold_by_yr, by = "year") |> replace_na(list(days = 0, type = "cold_snap"))
) |>
  mutate(type = factor(type,
    levels = c("heat_wave", "cold_snap"),
    labels = c(
      "Heat wave days\n(≥ 3 consecutive: Tmax ≥ 25°C and Tmean ≥ 20°C)",
      "Cold snap days\n(≥ 3 consecutive: Tmin ≤ −10°C)"
    )
  ))

heat_col <- "#b03a2e"
cold_col <- "#2471a3"

fig2 <- ggplot(annual, aes(x = year, y = days, fill = type)) +
  geom_col(position = "dodge", width = 0.72, alpha = 0.88) +
  geom_vline(xintercept = c(2018, 2022) - 0.005,
             colour = heat_col, linetype = "dashed",
             linewidth = 0.5, alpha = 0.55) +
  annotate("text", x = 2018 + 0.25, y = Inf,
           label = "2018 heatwave", vjust = 1.6, hjust = 0,
           size = 2.7, colour = heat_col) +
  annotate("text", x = 2022 + 0.25, y = Inf,
           label = "2022 heatwave", vjust = 1.6, hjust = 0,
           size = 2.7, colour = heat_col) +
  scale_fill_manual(values = c(heat_col, cold_col)) +
  scale_x_continuous(breaks = 2010:2023, expand = expansion(add = 0.5)) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.12))) +
  labs(
    title    = "Thermal-stress event days — Skåne 2010–2023",
    subtitle = "Days falling within qualifying heat wave or cold snap events; median across SMHI stations",
    x = NULL, y = "Days per year", fill = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(
    panel.grid.minor   = element_blank(),
    panel.grid.major.x = element_blank(),
    axis.text.x        = element_text(angle = 45, hjust = 1, size = 8.5),
    legend.position    = "bottom",
    legend.text        = element_text(size = 8.5),
    plot.title         = element_text(face = "bold", size = 12),
    plot.subtitle      = element_text(size = 8.5, colour = "gray40")
  )

# ── 5.  Save  -----------------------------------------------------------------
ggsave(file.path(OUT, "fig_01_study_area.png"),
       fig1, width = 8.5, height = 6.4, dpi = 180)
ggsave(file.path(OUT, "fig_02_heatwave.png"),
       fig2, width = 8.5, height = 4.5, dpi = 180)

message("Saved:\n  figures/fig_01_study_area.png\n  figures/fig_02_heatwave.png")
