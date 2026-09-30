-- Deterministic pilot fixtures: one synthetic region (DE-BY), EPSG:4326 input.
-- All geometries are made up for testing. They are not real parcels,
-- substations or peatland.
--
-- Three rows are intentionally bad so promotion has something to reject:
--   parcel P-005  self-intersecting "bow-tie" polygon
--   parcel P-006  no geometry delivered
--   substation SS-03  geometry in the wrong CRS for its run

-- Source runs ------------------------------------------------------------
INSERT INTO iris_core.source_run (country_code, region_code, source_id, source_date, source_srid, description) VALUES
    ('DE', 'DE-BY', 'de_synthetic_cadastre',  '2026-06-30', 4326, 'Synthetic parcel fixture'),
    ('DE', 'DE-BY', 'de_synthetic_grid',      '2026-05-15', 4326, 'Synthetic substation fixture'),
    ('DE', 'DE-BY', 'de_synthetic_peat',      '2025-12-31', 4326, 'Synthetic peatland fixture'),
    ('DE', 'DE-BY', 'de_synthetic_protected', '2026-03-01', 4326, 'Synthetic protected-area fixture');

-- Staging rows -----------------------------------------------------------
-- Parcels are ~100 m x 100 m rectangles.
INSERT INTO iris_staging.parcel (country_code, region_code, source_run_id, source_feature_id, geom)
SELECT 'DE', 'DE-BY', r.id, v.fid, v.geom
  FROM iris_core.source_run r,
       (VALUES
           ('P-001', ST_MakeEnvelope(11.4000, 48.4000, 11.4014, 48.4009, 4326)),
           ('P-002', ST_MakeEnvelope(11.4020, 48.4000, 11.4034, 48.4009, 4326)),
           ('P-003', ST_MakeEnvelope(11.4040, 48.4000, 11.4054, 48.4009, 4326)),
           ('P-004', ST_MakeEnvelope(11.4000, 48.4015, 11.4014, 48.4024, 4326)),
           ('P-005', ST_GeomFromText('POLYGON((11.4060 48.4015, 11.4074 48.4024, 11.4074 48.4015, 11.4060 48.4024, 11.4060 48.4015))', 4326)),
           ('P-006', NULL::geometry)
       ) AS v(fid, geom)
 WHERE r.country_code = 'DE' AND r.source_id = 'de_synthetic_cadastre';

-- SS-02 has no voltage in the source, so it stays NULL.
INSERT INTO iris_staging.substation (country_code, region_code, source_run_id, source_feature_id, name, voltage_kv, geom)
SELECT 'DE', 'DE-BY', r.id, v.fid, v.name, v.kv, v.geom
  FROM iris_core.source_run r,
       (VALUES
           ('SS-01', 'Synthetic Substation North', 110::numeric, ST_SetSRID(ST_MakePoint(11.4100, 48.4005), 4326)),
           ('SS-02', 'Synthetic Substation West',  NULL,         ST_SetSRID(ST_MakePoint(11.3950, 48.4030), 4326)),
           ('SS-03', 'Synthetic Substation Wrong CRS', 20,       ST_SetSRID(ST_MakePoint(1269000, 6174000), 3857))
       ) AS v(fid, name, kv, geom)
 WHERE r.country_code = 'DE' AND r.source_id = 'de_synthetic_grid';

-- Peatland polygon partly covers P-001 and P-002.
INSERT INTO iris_staging.peatland (country_code, region_code, source_run_id, source_feature_id, peat_class, geom)
SELECT 'DE', 'DE-BY', r.id, 'PL-01', 'fen', ST_MakeEnvelope(11.4008, 48.3995, 11.4028, 48.4012, 4326)
  FROM iris_core.source_run r
 WHERE r.country_code = 'DE' AND r.source_id = 'de_synthetic_peat';

-- Protected area covering the eastern part of P-003.
INSERT INTO iris_staging.screening_layer (country_code, region_code, source_run_id, source_feature_id, layer_type, geom)
SELECT 'DE', 'DE-BY', r.id, 'PA-01', 'protected_area', ST_MakeEnvelope(11.4045, 48.3990, 11.4080, 48.4030, 4326)
  FROM iris_core.source_run r
 WHERE r.country_code = 'DE' AND r.source_id = 'de_synthetic_protected';

-- Promote every run, then derive evidence ---------------------------------
SELECT r.source_id, p.*
  FROM iris_core.source_run r
 CROSS JOIN LATERAL iris_core.promote_source_run(r.id) p
 ORDER BY r.id, p.entity;

SELECT * FROM iris_core.build_evidence('DE', 'DE-BY');
