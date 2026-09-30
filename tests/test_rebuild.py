"""Acceptance criterion 1: the schema rebuilds from an empty database without manual steps."""

import uuid

import psycopg
import pytest

from iris_db.cli import migrate, rebuild, seed

EXPECTED_CORE_COUNTS = {
    "parcel": 4,
    "substation": 2,
    "peatland": 1,
    "screening_layer": 1,
    "evidence": 7,
}


def core_counts(conn) -> dict[str, int]:
    return {
        table: conn.execute(f"SELECT count(*) FROM iris_core.{table}").fetchone()[0]
        for table in EXPECTED_CORE_COUNTS
    }


def test_build_in_brand_new_database(db_url):
    """Create a truly empty database (no postgis, no schemas) and build it from scratch."""
    db_name = f"iris_empty_{uuid.uuid4().hex[:8]}"
    admin = psycopg.connect(db_url, autocommit=True)
    try:
        admin.execute(f"CREATE DATABASE {db_name} TEMPLATE template0")
    except psycopg.errors.InsufficientPrivilege:
        admin.close()
        pytest.skip("database user cannot create databases")

    try:
        new_url = psycopg.conninfo.make_conninfo(db_url, dbname=db_name)
        with psycopg.connect(new_url) as conn:
            migrate(conn)
            seed(conn)
            assert core_counts(conn) == EXPECTED_CORE_COUNTS
    finally:
        admin.execute(f"DROP DATABASE IF EXISTS {db_name} WITH (FORCE)")
        admin.close()


def test_rebuild_twice_gives_same_result(db_url):
    with psycopg.connect(db_url) as conn:
        rebuild(conn)
        first = core_counts(conn)
        rebuild(conn)
        second = core_counts(conn)
    assert first == second == EXPECTED_CORE_COUNTS


def test_migrate_is_a_no_op_when_up_to_date(db_url):
    with psycopg.connect(db_url) as conn:
        before = conn.execute("SELECT count(*) FROM public.schema_migrations").fetchone()[0]
        migrate(conn)
        after = conn.execute("SELECT count(*) FROM public.schema_migrations").fetchone()[0]
    assert before == after
