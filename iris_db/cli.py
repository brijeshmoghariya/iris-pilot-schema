"""Small command-line tool to build, seed and check the IRIS pilot database.

Usage:
    python -m iris_db rebuild   # reset + migrate + seed (the one command you usually need)
    python -m iris_db reset     # drop both schemas and the migration log
    python -m iris_db migrate   # apply migrations that have not been applied yet
    python -m iris_db seed      # load fixtures, promote them and build evidence
    python -m iris_db verify    # run sql/verify.sql and print the results
"""

import argparse
import os
import re
import sys
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parent.parent
MIGRATIONS_DIR = ROOT / "migrations"
FIXTURES_FILE = ROOT / "seeds" / "fixtures.sql"
VERIFY_FILE = ROOT / "sql" / "verify.sql"

DEFAULT_URL = "postgresql://iris:iris@localhost:5432/iris"


def connect(url: str | None = None) -> psycopg.Connection:
    return psycopg.connect(url or os.environ.get("DATABASE_URL", DEFAULT_URL))


def reset(conn: psycopg.Connection) -> None:
    # The postgis extension is left in place; everything the project owns is dropped.
    with conn.transaction():
        conn.execute("DROP SCHEMA IF EXISTS iris_core CASCADE")
        conn.execute("DROP SCHEMA IF EXISTS iris_staging CASCADE")
        conn.execute("DROP TABLE IF EXISTS public.schema_migrations")
    print("reset: dropped iris_core, iris_staging and schema_migrations")


def migrate(conn: psycopg.Connection) -> None:
    conn.execute(
        """CREATE TABLE IF NOT EXISTS public.schema_migrations (
               filename   text PRIMARY KEY,
               applied_at timestamptz NOT NULL DEFAULT now()
           )"""
    )
    conn.commit()
    applied = {row[0] for row in conn.execute("SELECT filename FROM public.schema_migrations")}

    for path in sorted(MIGRATIONS_DIR.glob("*.sql")):
        if path.name in applied:
            continue
        # Each file runs in its own transaction together with its log entry,
        # so a failing migration leaves nothing half-applied.
        with conn.transaction():
            conn.execute(path.read_text())
            conn.execute("INSERT INTO public.schema_migrations (filename) VALUES (%s)", (path.name,))
        print(f"migrate: applied {path.name}")


def seed(conn: psycopg.Connection) -> None:
    with conn.transaction():
        conn.execute(FIXTURES_FILE.read_text())
    print(f"seed: loaded {FIXTURES_FILE.relative_to(ROOT)}")


def rebuild(conn: psycopg.Connection) -> None:
    reset(conn)
    migrate(conn)
    seed(conn)


def split_named_blocks(sql_text: str) -> list[tuple[str, str]]:
    """Split verify.sql on '-- name:' lines into (title, sql) pairs."""
    parts = re.split(r"^-- name:\s*(.+)$", sql_text, flags=re.MULTILINE)
    # parts = [preamble, title1, body1, title2, body2, ...]
    return [(title.strip(), body.strip()) for title, body in zip(parts[1::2], parts[2::2])]


def print_rows(columns: list[str], rows: list[tuple]) -> None:
    if not rows:
        print("  (no rows)")
        return
    cells = [[("" if v is None else str(v)) for v in row] for row in rows]
    widths = [max(len(c), *(len(r[i]) for r in cells)) for i, c in enumerate(columns)]
    print("  " + " | ".join(c.ljust(w) for c, w in zip(columns, widths)))
    print("  " + "-+-".join("-" * w for w in widths))
    for row in cells:
        print("  " + " | ".join(v.ljust(w) for v, w in zip(row, widths)))


def verify(conn: psycopg.Connection) -> None:
    try:
        with conn.cursor() as cur:
            for title, sql in split_named_blocks(VERIFY_FILE.read_text()):
                print(f"\n== {title}")
                cur.execute(sql)
                if cur.description is not None:
                    columns = [d.name for d in cur.description]
                    print_rows(columns, cur.fetchall())
    finally:
        conn.rollback()


COMMANDS = {
    "reset": reset,
    "migrate": migrate,
    "seed": seed,
    "rebuild": rebuild,
    "verify": verify,
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m iris_db", description="IRIS pilot database tool")
    parser.add_argument("command", choices=COMMANDS)
    parser.add_argument("--database-url", help="defaults to $DATABASE_URL, then " + DEFAULT_URL)
    args = parser.parse_args(argv)

    try:
        with connect(args.database_url) as conn:
            COMMANDS[args.command](conn)
    except psycopg.Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0
