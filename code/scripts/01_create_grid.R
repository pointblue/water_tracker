# Script to create raster grid with unique identifiers for each unit of analysis
#
#
#  

# Parameters
overwrite <- FALSE

# Load definitions and code
code_dir <- "V:/Project/wetland/FWSPartners/code/cvjv-restoration-modelling/code"
def_file <- file.path(code_dir, "definitions.R")
code_files <- file.path(code_dir, "functions", "00_shared_functions.R")
sapply(c(def_file, code_files), FUN = function(x) source(x))

# Packages
library(terra)
library(dplyr)

# Load reference raster
ref_rst <- rast(ref_file)

# Snap landcover
lc_snap_file <- file.path(lc_dir, "cropscape_combined_2014-2021.tif")
if (!file.exists(lc_snap_file) | overwrite == TRUE) {
  
  lc_rst <- rast(file.path(base_dir, "cropscape_tnc_2014-2021_utm10.tif"))
  
  if (!identical(ext(lc_rst), ext(ref_rst))) {
    message_ts("Extending...")
    lc_rst <- extend(lc_rst, ref_rst)
  }
  
  if (!identical(ext(lc_rst), ext(ref_rst))) {
    message_ts("Cropping...")
    lc_rst <- crop(lc_rst, ref_rst)
  }
  
  if (!identical(ext(lc_rst), ext(ref_rst))) {
    message_ts("Resampling...")
    lc_rst <- resample(lc_rst, ref_rst, method =)
  }
  
  message_ts("Exporting...")
  writeRaster(lc_rst, filename = lc_snap_file, overwrite = TRUE)
    
}

message_ts("Loading snapped landcover...")
lc_rst <- rast(lc_snap_file)

# Create constant raster if it does not exist
cons_file <- file.path(cov_dir, "data_type_constant_ebird_valley.tif")
if (!file.exists(cons_file) | overwrite == TRUE) {
  
  message_ts("Creating constant (eBird) raster...")
  cons_rst <- lc_rst
  values(cons_rst)[!is.na(values(cons_rst))] <- 1
  writeRaster(cons_rst, filename = cons_file, overwrite = TRUE)
  
} else {
  message_ts("Loading constant raster...")
  cons_rst <- rast(cons_file)
}

# Assign unique ids to each 90 acre area
uid_file <- file.path(grid_dir, "unique_ids.tif")
if (!file.exists(uid_file) | overwrite == TRUE) {
  
  message_ts("Creating grid...")
  
  # Aggregate to 90 acres (364,217 sqm), which is approximately 600m x 600m, or 20 cells
  message_ts("Aggregating...")
  agg_rst <- aggregate(cons_rst, fact = 20, fun = "max", na.rm = TRUE)
  
  message_ts("Assigning values...")
  values(agg_rst) <- 1:ncell(agg_rst)
  writeRaster(agg_rst, file.path(grid_dir, "unique_ids_coarse.tif"), overwrite = TRUE)
  
  message_ts("Disaggregating...")
  uid_rst <- disagg(agg_rst, fact = 20, method = "near", filename = uid_file, overwrite = TRUE)
  
} else {
  message_ts("Loading uid file...")
}
uid_rst <- rast(uid_file)

# Mask to valley
uid_masked_file <- file.path(grid_dir, "unique_ids_masked.tif")
if (!file.exists(uid_masked_file) | overwrite == TRUE) {
  
  message_ts("Cropping grid...")
  uid_rst <- crop(uid_rst, cons_rst)
  
  message_ts("Masking grid...")
  uid_rst <- mask(uid_rst, cons_rst, filename = uid_masked_file, overwrite = TRUE)
  
} else {
  message_ts("Loading masked uid file...")
}
uid_rst <- rast(uid_masked_file)

# Split landcover and get unique ids
# Defined in definitions.R
print(lc_defs)
lc_uid_files <- file.path(grid_dir, paste0("unique_ids_", names(lc_defs), ".rds"))
if (all(file.exists(lc_uid_files)) & overwrite != TRUE) {
  
  message_ts("UIDs already split by landcover. Loading from file...")

} else { 
  for (n in 1:length(lc_defs)) {
    
    lc_name <- names(lc_defs)[n]
    lc_codes <- lc_defs[[n]]
    lc_codes_str <- paste0(lc_codes, collapse = ", ")
    message_ts("Working on landcover layer for ", lc_name, " using code(s): ", lc_codes_str)
    
    lc_split_file <- file.path(lc_dir, paste0(lc_name, "_2014-2021.tif"))
    if (!file.exists(lc_split_file) | overwrite == TRUE) {
      
      message_ts("Building reclassification matrix...")
      rcl_df <- rbind(data.frame("Old" = lc_codes, "New" = rep(1)),
                      data.frame("Old" = unlist(lc_defs)[!(unlist(lc_defs) %in% lc_codes)], "New" = rep(0)))
      rcl_mat <- as.matrix(rcl_df)
      print(rcl_mat)
      
      message_ts("Reclassifying...")
      lc_split_rst <- classify(lc_rst, rcl_mat, filename = lc_split_file, overwrite = TRUE)
      
    } else {
      
      message_ts("Landcover layer already split. Loading...")
      lc_split_rst <- rast(lc_split_file)
      
    }
    
    message_ts("Getting unique ids...")
    uid_lc_rst <- mask(uid_rst, lc_split_rst, maskvalues = c(NA, 0))
    uid_lc_vals <- values(uid_lc_rst, mat = FALSE, na.rm = TRUE)
    uid_lc_df <- data.frame("UID" = uid_lc_vals, "Landcover" = lc_name) %>%
      group_by(UID, Landcover) %>%
      summarize(Count = n())
    
    message_ts("Found ", nrow(uid_lc_df), " matches.")
    saveRDS(uid_lc_df, file.path(grid_dir, paste0("unique_ids_", lc_name, ".rds")))
    
  }
  
}

# Combine
message_ts("Combining...")
uid_lc_files <- file.path(grid_dir, paste0("unique_ids_", names(lc_defs), ".rds"))
uid_df <- do.call(rbind, lapply(uid_lc_files, function(x) readRDS(x)))

# Calculate percentage and plurality
uid_sum_file <- file.path(grid_dir, "unique_ids_combined.csv")
if (file.exists(uid_sum_file) & overwrite != TRUE) {
  uid_sum_df <- read.csv(uid_sum_file)
} else {
  uid_sum_df <- uid_df %>%
    arrange(UID, Landcover) %>%
    group_by(UID) %>%
    mutate(Percentage = Count / 4, #400 30x30m cells in each block x 100 for percent
           Plurality = ifelse(Count == max(Count), TRUE, FALSE))
  write.csv(uid_sum_df, uid_sum_file, row.names = FALSE)
}

uid_suit_file <- file.path(grid_dir, "unique_ids_suitable.csv")
if (file.exists(uid_suit_file) & overwrite != TRUE) {
  uid_suit_df <- read.csv(uid_suit_file)
} else {
  uid_suit_df <- uid_sum_df %>%
    filter(Landcover != "Unsuitable" & Plurality == TRUE)
  write.csv(uid_suit_df, uid_suit_file, row.names = FALSE)
}

uid_grass_file <- file.path(grid_dir, "unique_ids_grass.csv")
if (file.exists(uid_grass_file) & overwrite != TRUE) {
  uid_grass_df <- read.csv(uid_grass_file)
} else {
  uid_grass_df <- uid_suit_df %>%
    filter(Landcover == "GrassPasture")
  write.csv(uid_grass_df, uid_grass_file, row.names = FALSE)
}

uid_ag_file <- file.path(grid_dir, "unique_ids_ag.csv")
if (file.exists(uid_ag_file) & overwrite != TRUE) {
  uid_ag_df <- read.csv(uid_ag_file)
} else {
  uid_ag_df <- uid_suit_df %>%
    filter(Landcover != "GrassPasture" & Landcover != "WetlandTreated" & Landcover != "WetlandNatural")
  write.csv(uid_ag_df, uid_ag_file, row.names = FALSE)
}

# Create suitable ag raster
ag_file <- file.path(grid_dir, "ag_footprint.tif")
if (file.exists(ag_file) & overwrite != TRUE) {
  
  message_ts("Ag raster already created and overwrite != TRUE; loading.")
  ag_rst <- rast(ag_file)
  
} else {
  
  message_ts("Creating ag raster")
  uids_ag <- unique(uid_ag_df$UID)
  
  # very slow
  #rcl_df <- data.frame("Is" = c(uids_ag), 
  #                     "Becomes" = c(rep(1, length(uids_ag))))
  #ag_rst <- classify(uid_rst, as.matrix(rcl_df), others = NA, filename = ag_file, overwrite = TRUE)
  
  # Much quicker
  ag_rst <- uid_rst
  ag_rst[values(ag_rst) %in% uids_ag] <- 1
  ag_rst[values(ag_rst) > 1] <- NA
  writeRaster(ag_rst, ag_file, overwrite = TRUE)
  message_ts("Complete")
  plot(ag_rst)
  
}

# Get xy positions
uid_cell_rst <- rast(file.path(grid_dir, "unique_ids_coarse.tif"))
uid_suit_df$Easting <- xFromCell(uid_cell_rst, uid_suit_df$UID)
uid_suit_df$Northing <- yFromCell(uid_cell_rst, uid_suit_df$UID)
write.csv(uid_suit_df, file.path(grid_dir, "unique_ids_suitable_xy.csv"), row.names = FALSE)

# Calculate wetland averages
message_ts("Calculating wetland values...")
wet_df <- read.csv(file.path(data_dir, "stats_basin_wetlands.csv"))
wet_df <- wet_df %>%
  filter(ClassName %in% c("Seasonal Wetland", "Semi-permanent Wetland")) %>%
  mutate(MosaicDateMid = as.Date(MosaicDateEnd) - round((as.Date(MosaicDateEnd) - as.Date(MosaicDateStart)) / 2, 0),
         Month = factor(format(MosaicDateMid, format = "%b"), levels = month.abb),
         Year = format(MosaicDateMid, format = "%Y")) %>%
  select(BasinName, ClassName, MosaicDateMid, Month, Year, PercentWater, PercentObserved)

mth_yr_df <- wet_df %>%
  select(!MosaicDateMid) %>%
  group_by(BasinName, ClassName, Month, Year) %>%
  summarize(MonthAvgWater = weighted.mean(PercentWater, PercentObserved, na.rm = TRUE) / 100,
         MonthAvgObs = weighted.mean(PercentObserved, PercentObserved, na.rm = TRUE))

mth_df <- mth_yr_df %>%
  ungroup() %>%
  select(BasinName, ClassName, Month, MonthAvgWater, MonthAvgObs) %>%
  group_by(BasinName, ClassName, Month) %>%
  summarize(AvgWater = weighted.mean(MonthAvgWater, MonthAvgObs, na.rm = TRUE))

write.csv(mth_df, file.path(data_dir, "stats_basin_wetlands_longterm.csv"), row.names = FALSE)

# Link basin and water
uid_bsn_file <- file.path(grid_dir, "uid_basin_lookup.rds")
if (!file.exists(uid_bsn_file)) {
  message_ts("Creating crosstab of uid and basin")
  bsn_rst <- rast(file.path(base_dir, "study_area/cvjv_valley_basins.tif"))
  uid_bsn_xtab <- crosstab(c(uid_rst, bsn_rst), long = TRUE)
  
  uid_bsn_df <- uid_bsn_xtab #2
  colnames(uid_bsn_df) <- c("UID", "BasinNum", "Freq")
  write.csv(uid_bsn_df, file.path(grid_dir, "uid_basin_full.csv"), row.names = FALSE)
  
  uid_bsn_df <- uid_bsn_df %>%
    group_by(UID) %>%
    slice_max(Freq) %>%
    left_join(data.frame(BasinNum = 1:9, BasinName = basins))
  saveRDS(uid_bsn_df, uid_bsn_file)
  
} else {
  uid_bsn_df <- readRDS(uid_bsn_file)
}

# Combine
uid_all_file <- file.path(grid_dir, "uid_full_lookup.rds")
uid_all_df <- uid_bsn_df %>%
  left_join(mth_df)
saveRDS(uid_all_df, uid_all_file)
  

