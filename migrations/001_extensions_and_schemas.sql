-- PostGIS plus the two pilot schemas.
-- iris_staging: raw rows as delivered by a source, loosely typed, any CRS.
-- iris_core:    validated canonical rows, strict types, one storage CRS (EPSG:3035).

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE SCHEMA iris_staging;
CREATE SCHEMA iris_core;

COMMENT ON SCHEMA iris_staging IS 'Raw source rows before validation and promotion. Geometry keeps the source CRS.';
COMMENT ON SCHEMA iris_core IS 'Canonical pilot data. All geometry stored in EPSG:3035 (ETRS89 / LAEA Europe).';
