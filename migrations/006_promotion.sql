-- Controlled promotion from iris_staging to iris_core for one source_run.
--
-- For each staging row of the run:
--   * if something required is missing or wrong, the row is marked 'rejected'
--     with a reason and stays in staging;
--   * otherwise it is transformed to EPSG:3035, inserted into core and marked 'promoted'.
--
-- I deliberately do not auto-repair geometry (e.g. ST_MakeValid) during promotion.
-- A repaired polygon can have a different area, which matters for peatland figures,
-- so invalid input is rejected and has to be fixed at the source.

CREATE FUNCTION iris_staging.reject_reason(
    p_geom           geometry,
    p_allowed_types  text[],
    p_feature_id     text,
    p_region_code    text,
    p_run_srid       integer
) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_feature_id IS NULL                         THEN 'missing source_feature_id'
        WHEN p_region_code IS NULL                        THEN 'missing region_code'
        WHEN p_geom IS NULL                               THEN 'missing geometry'
        WHEN ST_IsEmpty(p_geom)                           THEN 'empty geometry'
        WHEN ST_SRID(p_geom) <> p_run_srid                THEN format('SRID %s does not match source_run SRID %s', ST_SRID(p_geom), p_run_srid)
        WHEN GeometryType(p_geom) <> ALL (p_allowed_types) THEN 'unexpected geometry type ' || GeometryType(p_geom)
        WHEN NOT ST_IsValid(p_geom)                       THEN 'invalid geometry: ' || ST_IsValidReason(p_geom)
    END
$$;


CREATE FUNCTION iris_core.promote_source_run(p_run_id bigint)
RETURNS TABLE (entity text, promoted bigint, rejected bigint)
LANGUAGE plpgsql AS $$
DECLARE
    run iris_core.source_run;
BEGIN
    SELECT * INTO run FROM iris_core.source_run WHERE id = p_run_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'source_run % does not exist', p_run_id;
    END IF;

    -- parcel -------------------------------------------------------------
    UPDATE iris_staging.parcel s
       SET load_status = 'rejected',
           reject_reason = iris_staging.reject_reason(s.geom, ARRAY['POLYGON', 'MULTIPOLYGON'],
                               s.source_feature_id, COALESCE(s.region_code, run.region_code), run.source_srid)
     WHERE s.source_run_id = p_run_id AND s.load_status = 'pending'
       AND iris_staging.reject_reason(s.geom, ARRAY['POLYGON', 'MULTIPOLYGON'],
               s.source_feature_id, COALESCE(s.region_code, run.region_code), run.source_srid) IS NOT NULL;

    INSERT INTO iris_core.parcel
        (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, geom)
    SELECT s.country_code, COALESCE(s.region_code, run.region_code), run.source_id,
           s.source_feature_id, run.source_date, run.id, ST_Multi(ST_Transform(s.geom, 3035))
      FROM iris_staging.parcel s
     WHERE s.source_run_id = p_run_id AND s.load_status = 'pending';

    UPDATE iris_staging.parcel SET load_status = 'promoted'
     WHERE source_run_id = p_run_id AND load_status = 'pending';

    RETURN QUERY
        SELECT 'parcel', count(*) FILTER (WHERE load_status = 'promoted'), count(*) FILTER (WHERE load_status = 'rejected')
          FROM iris_staging.parcel WHERE source_run_id = p_run_id;

    -- substation ---------------------------------------------------------
    UPDATE iris_staging.substation s
       SET load_status = 'rejected',
           reject_reason = iris_staging.reject_reason(s.geom, ARRAY['POINT'],
                               s.source_feature_id, COALESCE(s.region_code, run.region_code), run.source_srid)
     WHERE s.source_run_id = p_run_id AND s.load_status = 'pending'
       AND iris_staging.reject_reason(s.geom, ARRAY['POINT'],
               s.source_feature_id, COALESCE(s.region_code, run.region_code), run.source_srid) IS NOT NULL;

    INSERT INTO iris_core.substation
        (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, name, voltage_kv, geom)
    SELECT s.country_code, COALESCE(s.region_code, run.region_code), run.source_id,
           s.source_feature_id, run.source_date, run.id, s.name, s.voltage_kv, ST_Transform(s.geom, 3035)
      FROM iris_staging.substation s
     WHERE s.source_run_id = p_run_id AND s.load_status = 'pending';

    UPDATE iris_staging.substation SET load_status = 'promoted'
     WHERE source_run_id = p_run_id AND load_status = 'pending';

    RETURN QUERY
        SELECT 'substation', count(*) FILTER (WHERE load_status = 'promoted'), count(*) FILTER (WHERE load_status = 'rejected')
          FROM iris_staging.substation WHERE source_run_id = p_run_id;

    -- peatland -----------------------------------------------------------
    UPDATE iris_staging.peatland s
       SET load_status = 'rejected',
           reject_reason = iris_staging.reject_reason(s.geom, ARRAY['POLYGON', 'MULTIPOLYGON'],
                               s.source_feature_id, COALESCE(s.region_code, run.region_code), run.source_srid)
     WHERE s.source_run_id = p_run_id AND s.load_status = 'pending'
       AND iris_staging.reject_reason(s.geom, ARRAY['POLYGON', 'MULTIPOLYGON'],
               s.source_feature_id, COALESCE(s.region_code, run.region_code), run.source_srid) IS NOT NULL;

    INSERT INTO iris_core.peatland
        (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, peat_class, geom)
    SELECT s.country_code, COALESCE(s.region_code, run.region_code), run.source_id,
           s.source_feature_id, run.source_date, run.id, s.peat_class, ST_Multi(ST_Transform(s.geom, 3035))
      FROM iris_staging.peatland s
     WHERE s.source_run_id = p_run_id AND s.load_status = 'pending';

    UPDATE iris_staging.peatland SET load_status = 'promoted'
     WHERE source_run_id = p_run_id AND load_status = 'pending';

    RETURN QUERY
        SELECT 'peatland', count(*) FILTER (WHERE load_status = 'promoted'), count(*) FILTER (WHERE load_status = 'rejected')
          FROM iris_staging.peatland WHERE source_run_id = p_run_id;

    -- screening_layer ----------------------------------------------------
    -- layer_type is required in core, so a missing one is also a rejection.
    UPDATE iris_staging.screening_layer s
       SET load_status = 'rejected',
           reject_reason = COALESCE(
               CASE WHEN s.layer_type IS NULL THEN 'missing layer_type' END,
               iris_staging.reject_reason(s.geom, ARRAY['POLYGON', 'MULTIPOLYGON'],
                   s.source_feature_id, COALESCE(s.region_code, run.region_code), run.source_srid))
     WHERE s.source_run_id = p_run_id AND s.load_status = 'pending'
       AND (s.layer_type IS NULL
            OR iris_staging.reject_reason(s.geom, ARRAY['POLYGON', 'MULTIPOLYGON'],
                   s.source_feature_id, COALESCE(s.region_code, run.region_code), run.source_srid) IS NOT NULL);

    INSERT INTO iris_core.screening_layer
        (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, layer_type, geom)
    SELECT s.country_code, COALESCE(s.region_code, run.region_code), run.source_id,
           s.source_feature_id, run.source_date, run.id, s.layer_type, ST_Multi(ST_Transform(s.geom, 3035))
      FROM iris_staging.screening_layer s
     WHERE s.source_run_id = p_run_id AND s.load_status = 'pending';

    UPDATE iris_staging.screening_layer SET load_status = 'promoted'
     WHERE source_run_id = p_run_id AND load_status = 'pending';

    RETURN QUERY
        SELECT 'screening_layer', count(*) FILTER (WHERE load_status = 'promoted'), count(*) FILTER (WHERE load_status = 'rejected')
          FROM iris_staging.screening_layer WHERE source_run_id = p_run_id;
END;
$$;

COMMENT ON FUNCTION iris_core.promote_source_run(bigint) IS
    'Validates pending staging rows of one run, rejects bad ones with a reason, transforms the rest to EPSG:3035 and inserts them into core.';
