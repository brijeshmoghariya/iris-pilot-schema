"""Acceptance criteria 2 and 3, plus the country-scoped key design."""

import psycopg
import pytest

from conftest import add_source_run, run_id

CANONICAL_COLUMNS = {"geom", "country_code", "region_code", "source_id", "source_date", "created_at"}
CORE_ENTITY_TABLES = ["parcel", "substation", "peatland", "screening_layer"]


def test_core_entity_tables_have_canonical_columns(conn):
    for table in CORE_ENTITY_TABLES:
        columns = {
            row[0]
            for row in conn.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = 'iris_core' AND table_name = %s",
                (table,),
            )
        }
        missing = CANONICAL_COLUMNS - columns
        assert not missing, f"iris_core.{table} is missing {missing}"


def test_no_column_is_called_geometry(conn):
    rows = conn.execute(
        "SELECT table_schema, table_name FROM information_schema.columns "
        "WHERE table_schema IN ('iris_core', 'iris_staging') AND column_name = 'geometry'"
    ).fetchall()
    assert rows == []


def test_every_table_has_non_null_country_code(conn):
    tables = conn.execute(
        """SELECT t.table_schema, t.table_name, c.is_nullable
             FROM information_schema.tables t
             LEFT JOIN information_schema.columns c
               ON c.table_schema = t.table_schema
              AND c.table_name = t.table_name
              AND c.column_name = 'country_code'
            WHERE t.table_schema IN ('iris_core', 'iris_staging')
              AND t.table_type = 'BASE TABLE'"""
    ).fetchall()
    assert len(tables) == 10
    for schema, table, is_nullable in tables:
        assert is_nullable == "NO", f"{schema}.{table}.country_code must exist and be NOT NULL"


@pytest.mark.parametrize("schema", ["iris_core", "iris_staging"])
def test_null_country_code_is_rejected(conn, schema):
    run = run_id(conn, "DE", "de_synthetic_cadastre")
    if schema == "iris_core":
        sql = """INSERT INTO iris_core.parcel
                     (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, geom)
                 VALUES (NULL, 'DE-BY', 'x', 'x', '2026-01-01', %s,
                         ST_Multi(ST_Transform(ST_MakeEnvelope(11.4, 48.4, 11.401, 48.401, 4326), 3035)))"""
    else:
        sql = "INSERT INTO iris_staging.parcel (country_code, source_run_id) VALUES (NULL, %s)"
    with pytest.raises(psycopg.errors.NotNullViolation):
        conn.execute(sql, (run,))


def test_country_code_must_be_two_uppercase_letters(conn):
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO iris_core.source_run (country_code, source_id, source_date, source_srid) "
            "VALUES ('de', 'x', '2026-01-01', 4326)"
        )


def test_same_feature_id_is_allowed_in_another_country(conn):
    nl_run = add_source_run(conn, "NL", "nl_synthetic_cadastre")
    # Same source_id and feature id as a DE parcel, but in NL: must be accepted.
    conn.execute(
        """INSERT INTO iris_core.parcel
               (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, geom)
           VALUES ('NL', 'NL-GE', 'de_synthetic_cadastre', 'P-001', '2026-01-01', %s,
                   ST_Multi(ST_Transform(ST_MakeEnvelope(5.9, 52.0, 5.901, 52.001, 4326), 3035)))""",
        (nl_run,),
    )


def test_duplicate_feature_in_same_country_is_rejected(conn):
    run = run_id(conn, "DE", "de_synthetic_cadastre")
    with pytest.raises(psycopg.errors.UniqueViolation):
        conn.execute(
            """INSERT INTO iris_core.parcel
                   (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, geom)
               VALUES ('DE', 'DE-BY', 'de_synthetic_cadastre', 'P-001', '2026-06-30', %s,
                       ST_Multi(ST_Transform(ST_MakeEnvelope(11.5, 48.5, 11.501, 48.501, 4326), 3035)))""",
            (run,),
        )


def test_row_cannot_use_a_source_run_from_another_country(conn):
    nl_run = add_source_run(conn, "NL", "nl_synthetic_cadastre")
    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        conn.execute(
            """INSERT INTO iris_core.parcel
                   (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, geom)
               VALUES ('DE', 'DE-BY', 'x', 'x', '2026-01-01', %s,
                       ST_Multi(ST_Transform(ST_MakeEnvelope(11.4, 48.4, 11.401, 48.401, 4326), 3035)))""",
            (nl_run,),
        )


def test_evidence_cannot_link_parcel_to_substation_in_another_country(conn):
    nl_run = add_source_run(conn, "NL", "nl_synthetic_grid")
    nl_substation = conn.execute(
        """INSERT INTO iris_core.substation
               (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, geom)
           VALUES ('NL', 'NL-GE', 'nl_synthetic_grid', 'SS-NL-1', '2026-01-01', %s,
                   ST_Transform(ST_SetSRID(ST_MakePoint(5.9, 52.0), 4326), 3035))
           RETURNING id""",
        (nl_run,),
    ).fetchone()[0]
    de_parcel = conn.execute(
        "SELECT id FROM iris_core.parcel WHERE country_code = 'DE' AND source_feature_id = 'P-001'"
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        conn.execute(
            """INSERT INTO iris_core.evidence
                   (country_code, region_code, parcel_id, check_type, substation_id,
                    value, unit, method, uncertainty_note, source_date)
               VALUES ('DE', 'DE-BY', %s, 'substation_distance', %s,
                       100, 'm', 'test', 'test', '2026-01-01')""",
            (de_parcel, nl_substation),
        )


def test_evidence_check_type_must_match_target_and_unit(conn):
    de_parcel = conn.execute(
        "SELECT id FROM iris_core.parcel WHERE country_code = 'DE' AND source_feature_id = 'P-001'"
    ).fetchone()[0]
    de_substation = conn.execute(
        "SELECT id FROM iris_core.substation WHERE country_code = 'DE' AND source_feature_id = 'SS-01'"
    ).fetchone()[0]
    # A distance check stored in m2 is a contract error.
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            """INSERT INTO iris_core.evidence
                   (country_code, region_code, parcel_id, check_type, substation_id,
                    value, unit, method, uncertainty_note, source_date)
               VALUES ('DE', 'DE-BY', %s, 'substation_distance', %s,
                       100, 'm2', 'test', 'test', '2026-01-01')""",
            (de_parcel, de_substation),
        )
