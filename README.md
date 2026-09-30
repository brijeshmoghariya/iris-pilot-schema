# IRIS pilot – canonical PostGIS schema (IRIS-CAND-03)

This repo contains the database schema for the IRIS pilot: SQL migrations for
`iris_staging` and `iris_core`, a small deterministic fixture set, a staging → core
promotion step, verification queries and tests. It supports the two pilot verticals:
BESS siting (parcel ↔ substation distance) and peatland inference (parcel ∩ peatland area).

Stack: Python 3.12+, PostgreSQL 16, PostGIS 3.4 (via Docker), `psycopg` 3, `pytest`.

## Quick start

You need Docker and Python 3.12+.

```bash
# 1. start PostgreSQL 16 + PostGIS 3.4
docker compose up -d --wait

# 2. Python environment
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# 3. build everything from scratch, then check it
python -m iris_db rebuild
python -m iris_db verify

# 4. tests
pytest
```

The default connection string is `postgresql://iris:iris@localhost:5432/iris`, which
matches `docker-compose.yml`. If port 5432 is already taken on your machine, change the
port mapping and set `DATABASE_URL` (see `.env.example`), or pass `--database-url`.

## Commands

| Command | What it does |
|---|---|
| `python -m iris_db rebuild` | `reset` + `migrate` + `seed`. The one command for a clean state. |
| `python -m iris_db reset` | Drops `iris_core`, `iris_staging` and the migration log. |
| `python -m iris_db migrate` | Applies migrations from `migrations/` that are not in `public.schema_migrations` yet. |
| `python -m iris_db seed` | Loads `seeds/fixtures.sql`, promotes it to core and builds evidence. |
| `python -m iris_db verify` | Runs `sql/verify.sql` and prints the results. Runs in a transaction that is rolled back. |

## Project layout

```
migrations/
  001_extensions_and_schemas.sql   postgis, iris_staging, iris_core
  002_source_run.sql               load metadata, one row per dataset load
  003_core_tables.sql              parcel, substation, peatland, screening_layer, evidence
  004_staging_tables.sql           raw landing tables with load_status / reject_reason
  005_indexes.sql                  GiST + btree indexes for the two verticals
  006_promotion.sql                promote_source_run(): validate, transform, insert
  007_evidence_builder.sql         build_evidence(): distance and overlap checks
seeds/fixtures.sql                 synthetic DE-BY fixtures (incl. 3 deliberately bad rows)
sql/verify.sql                     verification queries (acceptance criteria 2 and 4)
iris_db/cli.py                     reset / migrate / seed / rebuild / verify
tests/                             pytest suite against the real database
docs/schema.md                     Mermaid ER diagram, key table, promotion flow
```

## Design choices

### CRS policy

- **Core storage is EPSG:3035 (ETRS89 / LAEA Europe) for every geometry.** Each core
  `geom` column is typed, e.g. `geometry(MultiPolygon, 3035)`, so PostGIS rejects
  anything in another SRID or of another type.
- I chose 3035 because it is **equal-area**: `ST_Area` returns real square metres, which
  the peatland overlap figures depend on. It also covers all of Europe, so a second
  country can use the same columns. Distances are in metres. LAEA distorts distances a
  little away from its centre, which I think is acceptable for screening. A test checks
  that `area_m2` agrees with the geodesic area to within 0.1 %.
- Alternatives I considered:
  - **EPSG:4326 + `geography` casts.** Simple, but it is slower and makes it easy to
    compute areas in "square degrees" by accident.
  - **A national CRS such as EPSG:25832.** Most accurate locally, but it stops working
    once a second country is added.
- **Staging keeps the CRS the source delivered.** Geometry must declare an SRID
  (`ST_SRID(geom) > 0`), and it must match `source_run.source_srid`. Promotion is the
  only place where `ST_Transform(..., 3035)` happens.
- For output (e.g. GeoJSON), transform back to 4326 at query time. The round trip is in
  `verify.sql` block 5 and in `test_geojson_round_trip_through_core`.

### Keys and country scoping

- Every table in both schemas has `country_code char(2) NOT NULL`, checked against
  `^[A-Z]{2}$` (ISO 3166-1 alpha-2).
- Each table has a surrogate `id`, but it is never used on its own for relations. Each
  table also has `UNIQUE (country_code, id)`, and all foreign keys are composite, for
  example `(country_code, source_run_id) → source_run(country_code, id)`. This makes it
  impossible for a DE parcel to point at an NL run or an NL substation; there is a test
  for exactly that.
- The natural key is `UNIQUE (country_code, source_id, source_feature_id)`. The same
  feature can only be loaded once per country, and the same id in two countries is fine.
- I went with a surrogate key plus composite unique constraints rather than pure natural
  primary keys. Joins stay short, and the country scoping is still enforced by the
  database.

### Staging vs. core

- **Staging** accepts whatever a source delivers: untyped geometry, nullable attributes,
  any declared SRID. Each row has a `load_status`.
- **`iris_core.promote_source_run(run_id)`** checks the pending rows of one run:
  - A row is rejected with a readable `reject_reason` if it has a missing id, region or
    geometry, the wrong SRID, the wrong geometry type, or invalid geometry.
  - Everything else is transformed to 3035 and inserted into core.
- I do **not** run `ST_MakeValid` during promotion. A repaired polygon can have a
  different area, and for peatland that changes the numbers. So invalid input is rejected
  rather than silently changed.
- Missing descriptive attributes (substation name, voltage, peat class) stay NULL. There
  are no defaults that would invent values.

### Source metadata

- `source_run` holds one row per dataset load. It stores `source_id` (the dataset), its
  `source_date` and the SRID it was delivered in.
- Core rows carry `source_id` and `source_date` directly as well, because they are part
  of the canonical query contract. They are copied from the run during promotion.

### Evidence

- `evidence` stores one row per screening check on a parcel: the nearest substation
  distance (`m`), peatland overlap (`m2`), or other screening-layer overlap (`m2`).
- A CHECK constraint ties `check_type` to exactly one target column and to the right
  unit.
- `uncertainty_note` and `method` are mandatory, and `source_date` is the oldest input
  date used. The idea is that every number can be explained and is clearly marked as
  indicative.
- Evidence has no `geom` of its own. The geometries are on the referenced rows.
- `iris_core.build_evidence(country, region)` rebuilds evidence for one region.

### Indexes

- GiST on every core `geom`. These are used by `ST_DWithin`, `ST_Intersects` and the
  `<->` nearest-neighbour search.
- Btree on `(country_code, region_code)`, because the pilot works one region at a time.
- Btree on every foreign key, because Postgres does not index those automatically.
- The unique constraints already provide indexes for the key lookups.
- Index usage is shown in `verify.sql` (8a/8b) and asserted in two tests. With only a
  handful of fixture rows Postgres rightly prefers a sequential scan, so those checks set
  `enable_seqscan = off` to show the GiST index is usable for the query shape. On
  realistic volumes the planner picks it without that setting.

## Assumptions

- I did not have IRIS-003 / IRIS-007. I treated the six canonical names in the brief
  (`geom, country_code, region_code, source_id, source_date, created_at`) as the
  required pilot query fields. All four core entity tables have them, which is checked
  by a test and by `verify.sql` block 3.
- `source_id` means *the source dataset*, not the individual feature. The feature's own
  id is `source_feature_id`. I read `source_id` and `source_date` as a pair describing
  where a row came from.
- `region_code` uses ISO 3166-2 (e.g. `DE-BY`). If a staging row has no region, it takes
  the region of its `source_run`. If neither has one, the row is rejected.
- Substations are stored as points. Parcels, peatland and screening layers are stored as
  MultiPolygon, and single polygons are wrapped with `ST_Multi` so one column type fits
  both.
- `screening_layer` is one generic table with a `layer_type` column, rather than one
  table per layer.
- The fixtures are synthetic rectangles in Bavaria (`DE`, `DE-BY`), delivered in
  EPSG:4326. They are not real data.

## Simplifications, and what I'd change for production

| Now | Later |
|---|---|
| Small custom migration runner (numbered files + `schema_migrations`) | A proper tool (Alembic, Flyway, sqitch) with down-migrations |
| Fixtures are hand-written SQL | A Python loader reading GeoJSON/GPKG into staging (e.g. with GDAL/ogr2ogr), one `source_run` per file |
| One storage CRS (3035) for all countries | Keep 3035 for storage, but compute precise local distances in a national CRS where needed |
| Promotion is insert-only; a feature cannot be promoted twice | Versioning: new `source_date` → update or history table, with `valid_from/valid_to` |
| `uncertainty_note` is free text | A reference table of approved wording (like the project's disclaimer) plus a confidence level |
| Evidence is rebuilt per region with delete + insert | Incremental rebuild per changed run, and eco-point figures on top of `peatland_overlap` |
| Only `country_code` format is checked | FK to a `country` / `region` reference table |
| Local dev credentials in `docker-compose.yml` | Secrets from the environment / a secret store, separate roles for loader and readers |

## Tests

`pytest` rebuilds the database once, then each test works in a transaction that is
rolled back. The tests focus on the things that would be most costly to get wrong:

- **Rebuild:** building into a brand-new empty database (created from `template0`,
  without PostGIS), running `rebuild` twice, and `migrate` being a no-op when up to date.
- **Contract:** all canonical columns exist, no column is named `geometry`, and every
  table in both schemas has a NOT NULL `country_code`.
- **Keys:** NULL `country_code` is rejected in core and staging; the same feature id is
  allowed in another country; duplicates in the same country are rejected; references
  across countries (run and substation) are rejected; and evidence type/unit mismatch is
  rejected.
- **Spatial:**
  - Core rejects wrong SRID, wrong geometry type and invalid geometry.
  - Promotion rejects the 3 bad fixtures with the expected reasons.
  - Missing voltage stays NULL.
  - GeoJSON round trip matches to 1e-8°.
  - `area_m2` matches the geodesic area.
  - The evidence matches the fixture layout.
  - GiST indexes are used for distance and overlap queries.

## Results

Output of `python -m iris_db verify` on the fixtures (shortened):

```
== 2. Staging rows that were rejected, and why
  parcel     | P-005 | invalid geometry: Self-intersection[11.4067 48.40195]
  parcel     | P-006 | missing geometry
  substation | SS-03 | SRID 3857 does not match source_run SRID 4326

== 5. Spatial round trip
  stored_srid | stored_area_m2 | geojson_back                                          | matches_input
  3035        | 9631.6         | {"type":"MultiPolygon","coordinates":[[[[11.41,48.41],...| True

== 7. Peatland query: parcel area covered by peatland
  P-001 | 10374.6 | PL-01 | 4446.2 | 42.9
  P-002 | 10374.6 | PL-01 | 5928.3 | 57.1

== 8a. EXPLAIN parcels within 500 m of a substation (ST_DWithin)
  ->  Index Scan using substation_geom_gix on substation s
        Index Cond: (geom && st_expand(p.geom, '500'::double precision))
```

All figures are from synthetic fixtures and are only meant to show the schema works.
Screening results are indicative and based on the available source data.
