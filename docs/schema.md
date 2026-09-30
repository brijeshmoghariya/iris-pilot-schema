# Schema diagram

Core tables (`iris_core`). Every arrow is a composite foreign key that includes
`country_code`, so a row can only reference rows from its own country.

```mermaid
erDiagram
    source_run ||--o{ parcel : "loaded by"
    source_run ||--o{ substation : "loaded by"
    source_run ||--o{ peatland : "loaded by"
    source_run ||--o{ screening_layer : "loaded by"
    parcel ||--o{ evidence : "checked in"
    substation |o--o{ evidence : "distance to"
    peatland |o--o{ evidence : "overlap with"
    screening_layer |o--o{ evidence : "overlap with"

    source_run {
        bigint id PK
        char2 country_code "NOT NULL"
        text region_code "NULL = whole country"
        text source_id "dataset id"
        date source_date
        int source_srid "CRS delivered by source"
        timestamptz created_at
    }
    parcel {
        bigint id PK
        char2 country_code "NOT NULL"
        text region_code
        text source_id
        text source_feature_id
        date source_date
        bigint source_run_id FK
        geometry geom "MultiPolygon, 3035"
        float area_m2 "generated"
        timestamptz created_at
    }
    substation {
        bigint id PK
        char2 country_code "NOT NULL"
        text region_code
        text source_id
        text source_feature_id
        date source_date
        bigint source_run_id FK
        text name "nullable"
        numeric voltage_kv "nullable"
        geometry geom "Point, 3035"
        timestamptz created_at
    }
    peatland {
        bigint id PK
        char2 country_code "NOT NULL"
        text region_code
        text source_id
        text source_feature_id
        date source_date
        bigint source_run_id FK
        text peat_class "nullable"
        geometry geom "MultiPolygon, 3035"
        float area_m2 "generated"
        timestamptz created_at
    }
    screening_layer {
        bigint id PK
        char2 country_code "NOT NULL"
        text region_code
        text source_id
        text source_feature_id
        date source_date
        bigint source_run_id FK
        text layer_type
        geometry geom "MultiPolygon, 3035"
        timestamptz created_at
    }
    evidence {
        bigint id PK
        char2 country_code "NOT NULL"
        text region_code
        bigint parcel_id FK
        text check_type
        bigint substation_id FK "one of these three"
        bigint peatland_id FK "one of these three"
        bigint screening_layer_id FK "one of these three"
        float value
        text unit "m or m2"
        text method
        text uncertainty_note
        date source_date
        timestamptz created_at
    }
```

Keys, written out:

| Table | Primary key | Country-scoped unique keys | Foreign keys |
|---|---|---|---|
| source_run | id | (country_code, id), (country_code, source_id, source_date) | - |
| parcel, substation, peatland, screening_layer | id | (country_code, id), (country_code, source_id, source_feature_id) | (country_code, source_run_id) -> source_run |
| evidence | id | (country_code, parcel_id, check_type, substation_id, peatland_id, screening_layer_id) NULLS NOT DISTINCT | (country_code, parcel_id), (country_code, substation_id), (country_code, peatland_id), (country_code, screening_layer_id) |

## Staging and promotion flow

```mermaid
flowchart LR
    A["source file / fixture<br/>(any CRS, declared SRID)"] --> B["iris_staging.&lt;entity&gt;<br/>load_status = pending"]
    B --> C{"promote_source_run(run_id)"}
    C -- "missing id / region / geom,<br/>wrong SRID or type,<br/>invalid geometry" --> D["stays in staging<br/>load_status = rejected<br/>reject_reason set"]
    C -- "ok" --> E["ST_Transform to 3035<br/>ST_Multi for polygons"]
    E --> F["iris_core.&lt;entity&gt;"]
    F --> G["build_evidence(country, region)"]
    G --> H["iris_core.evidence"]
```

Staging tables mirror the core names (`iris_staging.parcel`, `.substation`,
`.peatland`, `.screening_layer`). They have an untyped `geom`, nullable attributes,
`load_status` and `reject_reason`. `source_run` lives in `iris_core` and is shared
by both schemas.
