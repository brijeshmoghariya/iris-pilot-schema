-- Indexes for the two pilot verticals.
--
-- The UNIQUE constraints in 002/003 already create btree indexes on
-- (country_code, id) and (country_code, source_id, source_feature_id),
-- so those lookups are covered and not repeated here.

-- Spatial indexes (GiST) on every core geometry.
-- BESS:     parcel <-> substation distance (ST_DWithin, nearest-neighbour <->)
-- Peatland: parcel x peatland / screening_layer overlap (ST_Intersects)
CREATE INDEX parcel_geom_gix          ON iris_core.parcel          USING gist (geom);
CREATE INDEX substation_geom_gix      ON iris_core.substation      USING gist (geom);
CREATE INDEX peatland_geom_gix        ON iris_core.peatland        USING gist (geom);
CREATE INDEX screening_layer_geom_gix ON iris_core.screening_layer USING gist (geom);

-- The pilot works one region at a time, so most queries filter on country + region.
CREATE INDEX parcel_region_idx          ON iris_core.parcel          (country_code, region_code);
CREATE INDEX substation_region_idx      ON iris_core.substation      (country_code, region_code);
CREATE INDEX peatland_region_idx        ON iris_core.peatland        (country_code, region_code);
CREATE INDEX screening_layer_region_idx ON iris_core.screening_layer (country_code, region_code, layer_type);

-- Foreign keys are not indexed automatically in Postgres.
CREATE INDEX parcel_run_idx          ON iris_core.parcel          (country_code, source_run_id);
CREATE INDEX substation_run_idx      ON iris_core.substation      (country_code, source_run_id);
CREATE INDEX peatland_run_idx        ON iris_core.peatland        (country_code, source_run_id);
CREATE INDEX screening_layer_run_idx ON iris_core.screening_layer (country_code, source_run_id);

CREATE INDEX evidence_parcel_idx     ON iris_core.evidence (country_code, parcel_id, check_type);
CREATE INDEX evidence_substation_idx ON iris_core.evidence (country_code, substation_id)      WHERE substation_id IS NOT NULL;
CREATE INDEX evidence_peatland_idx   ON iris_core.evidence (country_code, peatland_id)        WHERE peatland_id IS NOT NULL;
CREATE INDEX evidence_layer_idx      ON iris_core.evidence (country_code, screening_layer_id) WHERE screening_layer_id IS NOT NULL;

-- Staging is small and short-lived; promotion only needs to find pending rows of a run.
CREATE INDEX staging_parcel_run_idx          ON iris_staging.parcel          (source_run_id, load_status);
CREATE INDEX staging_substation_run_idx      ON iris_staging.substation      (source_run_id, load_status);
CREATE INDEX staging_peatland_run_idx        ON iris_staging.peatland        (source_run_id, load_status);
CREATE INDEX staging_screening_layer_run_idx ON iris_staging.screening_layer (source_run_id, load_status);
