-- Builds screening evidence for one country/region from what is currently in core.
-- Re-running it replaces the evidence for that region, so it is safe to call again
-- after new data is promoted.

CREATE FUNCTION iris_core.build_evidence(p_country_code char(2), p_region_code text)
RETURNS TABLE (check_type text, rows_written bigint)
LANGUAGE plpgsql AS $$
DECLARE
    note constant text := 'Indicative screening result based on available source data. '
                          'Not verified; subject to project-specific checks.';
BEGIN
    DELETE FROM iris_core.evidence e
     WHERE e.country_code = p_country_code AND e.region_code = p_region_code;

    -- BESS: nearest substation to each parcel (same country), boundary-to-point distance.
    -- The <-> operator uses the GiST index for the nearest-neighbour search.
    INSERT INTO iris_core.evidence
        (country_code, region_code, parcel_id, check_type, substation_id,
         value, unit, method, uncertainty_note, source_date)
    SELECT p.country_code, p.region_code, p.id, 'substation_distance', s.id,
           ST_Distance(p.geom, s.geom), 'm',
           'nearest substation, ST_Distance in EPSG:3035', note,
           LEAST(p.source_date, s.source_date)
      FROM iris_core.parcel p
      CROSS JOIN LATERAL (
            SELECT s.id, s.geom, s.source_date
              FROM iris_core.substation s
             WHERE s.country_code = p.country_code
             ORDER BY s.geom <-> p.geom
             LIMIT 1
      ) s
     WHERE p.country_code = p_country_code AND p.region_code = p_region_code;

    -- Peatland: overlap area between each parcel and each peatland polygon it touches.
    INSERT INTO iris_core.evidence
        (country_code, region_code, parcel_id, check_type, peatland_id,
         value, unit, method, uncertainty_note, source_date)
    SELECT p.country_code, p.region_code, p.id, 'peatland_overlap', pl.id,
           ST_Area(ST_Intersection(p.geom, pl.geom)), 'm2',
           'ST_Area(ST_Intersection) in EPSG:3035', note,
           LEAST(p.source_date, pl.source_date)
      FROM iris_core.parcel p
      JOIN iris_core.peatland pl
        ON pl.country_code = p.country_code
       AND ST_Intersects(p.geom, pl.geom)
     WHERE p.country_code = p_country_code AND p.region_code = p_region_code
       AND ST_Area(ST_Intersection(p.geom, pl.geom)) > 0;

    -- Other screening layers (protected areas etc.): same overlap logic.
    INSERT INTO iris_core.evidence
        (country_code, region_code, parcel_id, check_type, screening_layer_id,
         value, unit, method, uncertainty_note, source_date)
    SELECT p.country_code, p.region_code, p.id, 'screening_overlap', sl.id,
           ST_Area(ST_Intersection(p.geom, sl.geom)), 'm2',
           'ST_Area(ST_Intersection) in EPSG:3035, layer ' || sl.layer_type, note,
           LEAST(p.source_date, sl.source_date)
      FROM iris_core.parcel p
      JOIN iris_core.screening_layer sl
        ON sl.country_code = p.country_code
       AND ST_Intersects(p.geom, sl.geom)
     WHERE p.country_code = p_country_code AND p.region_code = p_region_code
       AND ST_Area(ST_Intersection(p.geom, sl.geom)) > 0;

    RETURN QUERY
        SELECT e.check_type, count(*)
          FROM iris_core.evidence e
         WHERE e.country_code = p_country_code AND e.region_code = p_region_code
         GROUP BY e.check_type
         ORDER BY e.check_type;
END;
$$;
