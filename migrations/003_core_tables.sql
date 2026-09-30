-- Canonical business tables.
--
-- Conventions used in every table below:
--   * id is a surrogate key, but it is always used together with country_code.
--     UNIQUE (country_code, id) lets other tables point here with a composite FK,
--     so a DE row can never reference an NL row.
--   * (country_code, source_id, source_feature_id) is the natural key: the same
--     feature from the same dataset can only exist once per country.
--   * geom has a fixed type and SRID 3035, is NOT NULL and must be valid.
--   * Descriptive attributes that a source might not deliver (name, voltage, ...)
--     are nullable with no default. Missing stays missing.

CREATE TABLE iris_core.parcel (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code       char(2)     NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    region_code        text        NOT NULL,
    source_id          text        NOT NULL,
    source_feature_id  text        NOT NULL,
    source_date        date        NOT NULL,
    source_run_id      bigint      NOT NULL,
    geom               geometry(MultiPolygon, 3035) NOT NULL,
    area_m2            double precision GENERATED ALWAYS AS (ST_Area(geom)) STORED,
    created_at         timestamptz NOT NULL DEFAULT now(),

    UNIQUE (country_code, id),
    UNIQUE (country_code, source_id, source_feature_id),
    FOREIGN KEY (country_code, source_run_id) REFERENCES iris_core.source_run (country_code, id),
    CHECK (ST_IsValid(geom) AND NOT ST_IsEmpty(geom))
);

CREATE TABLE iris_core.substation (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code       char(2)     NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    region_code        text        NOT NULL,
    source_id          text        NOT NULL,
    source_feature_id  text        NOT NULL,
    source_date        date        NOT NULL,
    source_run_id      bigint      NOT NULL,
    name               text,
    voltage_kv         numeric     CHECK (voltage_kv > 0),
    geom               geometry(Point, 3035) NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),

    UNIQUE (country_code, id),
    UNIQUE (country_code, source_id, source_feature_id),
    FOREIGN KEY (country_code, source_run_id) REFERENCES iris_core.source_run (country_code, id),
    CHECK (NOT ST_IsEmpty(geom))
);

CREATE TABLE iris_core.peatland (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code       char(2)     NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    region_code        text        NOT NULL,
    source_id          text        NOT NULL,
    source_feature_id  text        NOT NULL,
    source_date        date        NOT NULL,
    source_run_id      bigint      NOT NULL,
    peat_class         text,
    geom               geometry(MultiPolygon, 3035) NOT NULL,
    area_m2            double precision GENERATED ALWAYS AS (ST_Area(geom)) STORED,
    created_at         timestamptz NOT NULL DEFAULT now(),

    UNIQUE (country_code, id),
    UNIQUE (country_code, source_id, source_feature_id),
    FOREIGN KEY (country_code, source_run_id) REFERENCES iris_core.source_run (country_code, id),
    CHECK (ST_IsValid(geom) AND NOT ST_IsEmpty(geom))
);

-- Generic constraint layers (protected areas, flood zones, ...) in one table.
CREATE TABLE iris_core.screening_layer (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code       char(2)     NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    region_code        text        NOT NULL,
    source_id          text        NOT NULL,
    source_feature_id  text        NOT NULL,
    source_date        date        NOT NULL,
    source_run_id      bigint      NOT NULL,
    layer_type         text        NOT NULL CHECK (layer_type ~ '^[a-z][a-z0-9_]*$'),
    geom               geometry(MultiPolygon, 3035) NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),

    UNIQUE (country_code, id),
    UNIQUE (country_code, source_id, source_feature_id),
    FOREIGN KEY (country_code, source_run_id) REFERENCES iris_core.source_run (country_code, id),
    CHECK (ST_IsValid(geom) AND NOT ST_IsEmpty(geom))
);

-- One row per screening check on a parcel: "parcel X is 340 m from substation Y",
-- "parcel X overlaps 1 200 m2 of peatland Z". Derived data, so there is no geom
-- here; the geometries live on the referenced rows.
CREATE TABLE iris_core.evidence (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code        char(2)     NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    region_code         text        NOT NULL,
    parcel_id           bigint      NOT NULL,
    check_type          text        NOT NULL
                        CHECK (check_type IN ('substation_distance', 'peatland_overlap', 'screening_overlap')),
    substation_id       bigint,
    peatland_id         bigint,
    screening_layer_id  bigint,
    value               double precision NOT NULL CHECK (value >= 0),
    unit                text        NOT NULL CHECK (unit IN ('m', 'm2')),
    method              text        NOT NULL,
    uncertainty_note    text        NOT NULL,
    source_date         date        NOT NULL,   -- oldest source_date of the inputs used
    created_at          timestamptz NOT NULL DEFAULT now(),

    FOREIGN KEY (country_code, parcel_id)          REFERENCES iris_core.parcel (country_code, id),
    FOREIGN KEY (country_code, substation_id)      REFERENCES iris_core.substation (country_code, id),
    FOREIGN KEY (country_code, peatland_id)        REFERENCES iris_core.peatland (country_code, id),
    FOREIGN KEY (country_code, screening_layer_id) REFERENCES iris_core.screening_layer (country_code, id),

    -- Each check type points at exactly one kind of target and uses a fixed unit.
    CHECK (
        (check_type = 'substation_distance' AND unit = 'm'
            AND substation_id IS NOT NULL AND peatland_id IS NULL AND screening_layer_id IS NULL)
     OR (check_type = 'peatland_overlap' AND unit = 'm2'
            AND peatland_id IS NOT NULL AND substation_id IS NULL AND screening_layer_id IS NULL)
     OR (check_type = 'screening_overlap' AND unit = 'm2'
            AND screening_layer_id IS NOT NULL AND substation_id IS NULL AND peatland_id IS NULL)
    ),

    -- The same check on the same pair should only be stored once.
    UNIQUE NULLS NOT DISTINCT (country_code, parcel_id, check_type, substation_id, peatland_id, screening_layer_id)
);

COMMENT ON COLUMN iris_core.parcel.area_m2 IS 'Computed from geom in EPSG:3035 (equal-area), so this is a real area in m2.';
COMMENT ON COLUMN iris_core.evidence.uncertainty_note IS 'Required. Evidence is indicative screening output, not a verified fact.';
