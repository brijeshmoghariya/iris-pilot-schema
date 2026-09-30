-- Staging tables: one per entity, same names as core.
-- They accept what a source delivers (any geometry type, any declared CRS, missing
-- values) and record whether each row was promoted or why it was rejected.
-- The only hard rules here: every row has a country and a run, and geometry must
-- declare an SRID. A geometry without a CRS is not something we should guess.

CREATE TABLE iris_staging.parcel (
    staging_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code       char(2)  NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    region_code        text,
    source_run_id      bigint   NOT NULL,
    source_feature_id  text,
    geom               geometry CHECK (geom IS NULL OR ST_SRID(geom) > 0),
    load_status        text     NOT NULL DEFAULT 'pending' CHECK (load_status IN ('pending', 'promoted', 'rejected')),
    reject_reason      text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (country_code, source_run_id) REFERENCES iris_core.source_run (country_code, id)
);

CREATE TABLE iris_staging.substation (
    staging_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code       char(2)  NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    region_code        text,
    source_run_id      bigint   NOT NULL,
    source_feature_id  text,
    name               text,
    voltage_kv         numeric,
    geom               geometry CHECK (geom IS NULL OR ST_SRID(geom) > 0),
    load_status        text     NOT NULL DEFAULT 'pending' CHECK (load_status IN ('pending', 'promoted', 'rejected')),
    reject_reason      text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (country_code, source_run_id) REFERENCES iris_core.source_run (country_code, id)
);

CREATE TABLE iris_staging.peatland (
    staging_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code       char(2)  NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    region_code        text,
    source_run_id      bigint   NOT NULL,
    source_feature_id  text,
    peat_class         text,
    geom               geometry CHECK (geom IS NULL OR ST_SRID(geom) > 0),
    load_status        text     NOT NULL DEFAULT 'pending' CHECK (load_status IN ('pending', 'promoted', 'rejected')),
    reject_reason      text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (country_code, source_run_id) REFERENCES iris_core.source_run (country_code, id)
);

CREATE TABLE iris_staging.screening_layer (
    staging_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code       char(2)  NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    region_code        text,
    source_run_id      bigint   NOT NULL,
    source_feature_id  text,
    layer_type         text,
    geom               geometry CHECK (geom IS NULL OR ST_SRID(geom) > 0),
    load_status        text     NOT NULL DEFAULT 'pending' CHECK (load_status IN ('pending', 'promoted', 'rejected')),
    reject_reason      text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (country_code, source_run_id) REFERENCES iris_core.source_run (country_code, id)
);
