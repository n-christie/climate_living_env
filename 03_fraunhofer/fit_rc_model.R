# =============================================================================
# 03_fraunhofer/fit_rc_model.R
# Fits a first-order RC thermal model to Fraunhofer indoor/outdoor series.
#
# Model:  dT_in/dt = (T_out - T_in) / tau
# Discretised at 1-hour step:
#   T_in[t] = T_in[t-1] + (T_out[t-1] - T_in[t-1]) * dt/tau
#
# tau (hours) = how fast indoor temperature follows outdoor.
# Larger tau = better thermal buffering = slower response to heat waves.
#
# We fit tau per room using nls(), report mean ± SD across rooms,
# and save parameters for use in the exposure matrix.
#
# Output:
#   03_fraunhofer/output/rc_model_params.rds
#   03_fraunhofer/output/rc_model_validation.png
# =============================================================================

library(tidyverse)
library(lubridate)
library(here)

OUT    <- here("03_fraunhofer/output")
TS_PATH <- here(OUT, "fraunhofer_timeseries.rds")

if (!file.exists(TS_PATH)) {
  stop("Run fetch_fraunhofer.R first.")
}

ts <- readRDS(TS_PATH)

# Resample to hourly means
ts_hourly <- ts |>
  mutate(hour = floor_date(datetime, "1 hour")) |>
  group_by(hour) |>
  summarise(across(where(is.numeric), \(x) mean(x, na.rm = TRUE)),
            .groups = "drop") |>
  rename(datetime = hour)

# ── RC model: predict indoor T from outdoor T --------------------------------
rc_predict <- function(t_out, tau, t_in_0, dt = 1.0) {
  n    <- length(t_out)
  t_in <- numeric(n)
  t_in[1] <- t_in_0
  alpha <- dt / tau
  for (i in seq(2, n)) {
    if (is.na(t_out[i - 1])) {
      t_in[i] <- t_in[i - 1]
    } else {
      t_in[i] <- t_in[i - 1] + alpha * (t_out[i - 1] - t_in[i - 1])
    }
  }
  t_in
}

# ── Fit tau for one room ------------------------------------------------------
fit_room <- function(t_out, t_in, room_name) {
  mask <- !is.na(t_out) & !is.na(t_in)
  if (sum(mask) < 48) return(NULL)

  t_out_c <- t_out[mask]
  t_in_c  <- t_in[mask]

  # Objective: sum of squared residuals between RC prediction and observed
  ssr <- function(tau_val) {
    pred <- rc_predict(t_out_c, tau_val, t_in_c[1])
    sum((pred - t_in_c)^2, na.rm = TRUE)
  }

  # Grid search to find good starting value, then optimise
  tau_grid <- seq(1, 48, by = 1)
  ssr_grid <- map_dbl(tau_grid, ssr)
  tau_start <- tau_grid[which.min(ssr_grid)]

  opt <- tryCatch(
    optimise(ssr, interval = c(0.5, 72)),
    error = \(e) list(minimum = tau_start, objective = NA_real_)
  )
  tau_fit <- opt$minimum

  pred  <- rc_predict(t_out_c, tau_fit, t_in_c[1])
  resid <- pred - t_in_c
  rmse  <- sqrt(mean(resid^2, na.rm = TRUE))
  r2    <- 1 - sum(resid^2, na.rm = TRUE) /
               sum((t_in_c - mean(t_in_c, na.rm = TRUE))^2, na.rm = TRUE)

  tibble(
    room        = room_name,
    tau_hours   = round(tau_fit, 2),
    rmse_c      = round(rmse, 3),
    r_squared   = round(r2, 3),
    n_hours     = sum(mask)
  )
}

# ── Fit all rooms -------------------------------------------------------------
outdoor_col  <- "outdoor_temp_c"
if (!outdoor_col %in% names(ts_hourly)) {
  stop("No outdoor_temp_c column. Check fetch_fraunhofer.R output.")
}

indoor_cols <- str_subset(names(ts_hourly), "indoor_temp_c")
t_out_vec   <- ts_hourly[[outdoor_col]]

message("Fitting RC model for ", length(indoor_cols), " rooms...")

results <- map_df(indoor_cols, \(col) {
  room_name <- str_remove(col, "_indoor_temp_c")
  message("  ", room_name, "...")
  fit_room(t_out_vec, ts_hourly[[col]], room_name)
})

message("\nRC model results:")
print(results)

summary_params <- list(
  rooms           = results,
  mean_tau_hours  = round(mean(results$tau_hours), 2),
  median_tau_hours= round(median(results$tau_hours), 2),
  sd_tau_hours    = round(sd(results$tau_hours), 2),
  note = paste(
    "tau is the e-folding time (hours) for indoor temperature",
    "to respond to a step change in outdoor temperature.",
    "Larger tau = better thermal buffering.",
    "Scale by BETSI RC_TAU ratios to apply to building epochs."
  )
)

saveRDS(summary_params, here(OUT, "rc_model_params.rds"))
message("\nMean tau: ", summary_params$mean_tau_hours, " hours")

# ── Validation plot -----------------------------------------------------------
# Show first 30 days for each room with modelled vs observed
n_plot <- min(720, nrow(ts_hourly))
plot_data <- ts_hourly[1:n_plot, ]

plots <- map(indoor_cols, \(col) {
  room_name <- str_remove(col, "_indoor_temp_c")
  tau_room  <- results$tau_hours[results$room == room_name]
  if (length(tau_room) == 0) return(NULL)

  t_out_p <- plot_data[[outdoor_col]]
  t_in_p  <- plot_data[[col]]
  pred    <- rc_predict(t_out_p, tau_room, mean(t_in_p, na.rm = TRUE))

  tibble(
    datetime = plot_data$datetime,
    outdoor  = t_out_p,
    observed = t_in_p,
    modelled = pred,
    room     = room_name
  )
}) |>
  bind_rows()

p <- ggplot(plots, aes(x = datetime)) +
  geom_line(aes(y = outdoor,  colour = "Outdoor"),  linewidth = 0.4, alpha = 0.6) +
  geom_line(aes(y = observed, colour = "Observed"), linewidth = 0.5) +
  geom_line(aes(y = modelled, colour = "RC model"), linewidth = 0.5, linetype = "dashed") +
  facet_wrap(~room, ncol = 2) +
  scale_colour_manual(values = c(
    "Outdoor"  = "#378ADD",
    "Observed" = "#D85A30",
    "RC model" = "#1D9E75"
  )) +
  labs(
    title   = "RC thermal model validation (first 30 days)",
    x       = NULL,
    y       = "Temperature (°C)",
    colour  = NULL,
    caption = paste0("Mean τ = ", summary_params$mean_tau_hours, " hours")
  ) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom")

ggsave(here(OUT, "rc_model_validation.png"), p,
       width = 10, height = 7, dpi = 150)
message("Validation plot saved → rc_model_validation.png")

message("\nDone. Next: source(here('04_netatmo/fetch_netatmo.R'))")
