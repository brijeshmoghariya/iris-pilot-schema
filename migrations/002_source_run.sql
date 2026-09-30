-- One row per load of one source dataset (e.g. a cadastre extract of a given date).
-- Every staging and core row points back to the run it came from.

CREATE TABLE iris_core.source_run (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code  char(2)     NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    region_code   text,                        -- NULL = run covers the whole country
    source_id     text        NOT NULL,        -- dataset identifier, e.g. 'de_synthetic_cadastre'
    source_date   date        NOT NULL,        -- date the source data refers to, not the load date
    source_srid   integer     NOT NULL CHECK (source_srid > 0),
    description   text,
    created_at    timestamptz NOT NULL DEFAULT now(),

    -- Needed so child tables can use (country_code, source_run_id) as a composite FK.
    UNIQUE (country_code, id),
    -- The same dataset version should only be loaded once per country.
    UNIQUE (country_code, source_id, source_date)
);

COMMENT ON COLUMN iris_core.source_run.source_srid IS 'CRS the source delivered its geometry in. Core geometry is always transformed to 3035.';
