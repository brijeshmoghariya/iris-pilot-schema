import os

import psycopg
import pytest

from iris_db.cli import DEFAULT_URL, connect, rebuild


@pytest.fixture(scope="session")
def db_url() -> str:
    return os.environ.get("DATABASE_URL", DEFAULT_URL)


@pytest.fixture(scope="session", autouse=True)
def built_db(db_url):
    """Rebuild the database once per test run so every test starts from the fixtures."""
    with connect(db_url) as conn:
        rebuild(conn)


@pytest.fixture
def conn(db_url):
    """A connection whose changes are rolled back after the test."""
    connection = psycopg.connect(db_url)
    yield connection
    connection.rollback()
    connection.close()


def run_id(conn, country_code: str, source_id: str) -> int:
    return conn.execute(
        "SELECT id FROM iris_core.source_run WHERE country_code = %s AND source_id = %s",
        (country_code, source_id),
    ).fetchone()[0]


def add_source_run(conn, country_code: str, source_id: str) -> int:
    return conn.execute(
        """INSERT INTO iris_core.source_run (country_code, region_code, source_id, source_date, source_srid)
           VALUES (%s, NULL, %s, '2026-01-01', 4326) RETURNING id""",
        (country_code, source_id),
    ).fetchone()[0]
