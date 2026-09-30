-- Verification queries. Run with:  python -m iris_db verify
-- (or paste blocks into psql). The runner executes everything in one transaction
-- and rolls it back at the end, so the round-trip insert below leaves no trace.
-- Each block starts with "-- name:" so the runner can print a heading for it.

-- name: 1. Row counts per core table and country
SELECT 'parcel' AS table_name, country_code, count(*) FROM iris_core.parcel GROUP BY country_code
UNION ALL SELECT 'substation', country_code, count(*) FROM iris_core.substation GROUP BY country_code
UNION ALL SELECT 'peatland', country_code, count(*) FROM iris_core.peatland GROUP BY country_code
UNION ALL SELECT 'screening_layer', country_code, count(*) FROM iris_core.screening_layer GROUP BY country_code
UNION ALL SELECT 'evidence', country_code, count(*) FROM iris_core.evidence GROUP BY country_code
ORDER BY 1, 2;

-- name: 2. Staging rows that were rejected, and why
SELECT 'parcel' AS entity, source_feature_id, reject_reason FROM iris_staging.parcel WHERE load_status = 'rejected'
UNION ALL SELECT 'substation', source_feature_id, reject_reason FROM iris_staging.substation WHERE load_status = 'rejected'
UNION ALL SELECT 'peatland', source_feature_id, reject_reason FROM iris_staging.peatland WHERE load_status = 'rejected'
UNION ALL SELECT 'screening_layer', source_feature_id, reject_reason FROM iris_staging.screening_layer WHERE load_status = 'rejected'
ORDER BY 1, 2;

-- name: 3. Canonical columns missing from core entity tables (expect no rows)
SELECT t.table_name, c.required AS missing_column
  FROM (VALUES ('parcel'), ('substation'), ('peatland'), ('screening_layer')) AS t(table_name)
 CROSS JOIN (VALUES ('geom'), ('country_code'), ('region_code'), ('source_id'), ('source_date'), ('created_at')) AS c(required)
 WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns ic
         WHERE ic.table_schema = 'iris_core' AND ic.table_name = t.table_name AND ic.column_name = c.required);

-- name: 4. Geometry contract as registered in PostGIS
SELECT f_table_name AS table_name, f_geometry_column AS column_name, type, srid
  FROM geometry_columns
 WHERE f_table_schema = 'iris_core'
 ORDER BY 1;

-- name: 5. Spatial round trip: GeoJSON (EPSG:4326) -> core parcel (EPSG:3035) -> GeoJSON
WITH input AS (
    SELECT ST_SetSRID(ST_GeomFromGeoJSON(
        '{"type":"Polygon","coordinates":[[[11.4100,48.4100],[11.4113,48.4100],[11.4113,48.4109],[11.4100,48.4109],[11.4100,48.4100]]]}'
    ), 4326) AS geom
), inserted AS (
    INSERT INTO iris_core.parcel (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, geom)
    SELECT r.country_code, r.region_code, r.source_id, 'ROUNDTRIP-1', r.source_date, r.id,
           ST_Multi(ST_Transform(i.geom, 3035))
      FROM iris_core.source_run r, input i
     WHERE r.country_code = 'DE' AND r.source_id = 'de_synthetic_cadastre'
    RETURNING geom, area_m2
)
SELECT ST_SRID(ins.geom)                                        AS stored_srid,
       round(ins.area_m2::numeric, 1)                           AS stored_area_m2,
       ST_AsGeoJSON(ST_Transform(ins.geom, 4326), 7)            AS geojson_back,
       ST_HausdorffDistance(i.geom, ST_Transform(ins.geom, 4326)) < 1e-7 AS matches_input
  FROM inserted ins, input i;

-- name: 6. BESS query: nearest substation per parcel (from evidence)
SELECT p.source_feature_id AS parcel, s.source_feature_id AS substation, s.voltage_kv,
       round(e.value::numeric, 1) AS distance_m, e.source_date
  FROM iris_core.evidence e
  JOIN iris_core.parcel p     ON p.country_code = e.country_code AND p.id = e.parcel_id
  JOIN iris_core.substation s ON s.country_code = e.country_code AND s.id = e.substation_id
 WHERE e.country_code = 'DE' AND e.region_code = 'DE-BY' AND e.check_type = 'substation_distance'
 ORDER BY distance_m;

-- name: 7. Peatland query: parcel area covered by peatland
SELECT p.source_feature_id AS parcel, round(p.area_m2::numeric, 1) AS parcel_area_m2,
       pl.source_feature_id AS peatland, round(e.value::numeric, 1) AS overlap_m2,
       round((100 * e.value / p.area_m2)::numeric, 1) AS overlap_pct
  FROM iris_core.evidence e
  JOIN iris_core.parcel p    ON p.country_code = e.country_code AND p.id = e.parcel_id
  JOIN iris_core.peatland pl ON pl.country_code = e.country_code AND pl.id = e.peatland_id
 WHERE e.country_code = 'DE' AND e.region_code = 'DE-BY' AND e.check_type = 'peatland_overlap'
 ORDER BY parcel;

-- name: 8. Index usage (seq scans disabled because the fixture tables are tiny)
-- With only a handful of rows Postgres correctly prefers a sequential scan, so
-- the index would never show up. Turning seq scans off for this session shows
-- the planner can and will use the GiST indexes for these query shapes.
SET enable_seqscan = off;

-- name: 8a. EXPLAIN parcels within 500 m of a substation (ST_DWithin)
EXPLAIN (COSTS OFF)
SELECT p.id, s.id
  FROM iris_core.parcel p
  JOIN iris_core.substation s
    ON s.country_code = p.country_code
   AND ST_DWithin(p.geom, s.geom, 500)
 WHERE p.country_code = 'DE' AND p.region_code = 'DE-BY';

-- name: 8b. EXPLAIN parcels intersecting peatland (ST_Intersects)
EXPLAIN (COSTS OFF)
SELECT p.id, pl.id
  FROM iris_core.parcel p
  JOIN iris_core.peatland pl
    ON pl.country_code = p.country_code
   AND ST_Intersects(p.geom, pl.geom)
 WHERE p.country_code = 'DE';

-- name: 8c. reset planner setting
RESET enable_seqscan;
