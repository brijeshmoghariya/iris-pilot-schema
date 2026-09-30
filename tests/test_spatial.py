"""Acceptance criterion 4 and the geometry contract."""

import json

import psycopg
import pytest

from conftest import run_id

INSERT_PARCEL = """
    INSERT INTO iris_core.parcel
        (country_code, region_code, source_id, source_feature_id, source_date, source_run_id, geom)
    VALUES ('DE', 'DE-BY', 'de_synthetic_cadastre', %s, '2026-06-30', %s, {geom})
    RETURNING id
"""


def test_core_rejects_geometry_in_wrong_srid(conn):
    run = run_id(conn, "DE", "de_synthetic_cadastre")
    sql = INSERT_PARCEL.format(geom="ST_Multi(ST_MakeEnvelope(11.4, 48.4, 11.401, 48.401, 4326))")
    with pytest.raises(psycopg.Error, match="SRID"):
        conn.execute(sql, ("WRONG-SRID", run))


def test_core_rejects_wrong_geometry_type(conn):
    run = run_id(conn, "DE", "de_synthetic_cadastre")
    sql = INSERT_PARCEL.format(geom="ST_Transform(ST_SetSRID(ST_MakePoint(11.4, 48.4), 4326), 3035)")
    with pytest.raises(psycopg.Error, match="type"):
        conn.execute(sql, ("WRONG-TYPE", run))


def test_core_rejects_invalid_geometry(conn):
    run = run_id(conn, "DE", "de_synthetic_cadastre")
    bowtie = "ST_Multi(ST_GeomFromText('POLYGON((0 0, 10 10, 10 0, 0 10, 0 0))', 3035))"
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(INSERT_PARCEL.format(geom=bowtie), ("BOWTIE", run))


def test_promotion_rejects_bad_fixture_rows_with_a_reason(conn):
    rows = conn.execute(
        """SELECT source_feature_id, reject_reason FROM iris_staging.parcel WHERE load_status = 'rejected'
           UNION ALL
           SELECT source_feature_id, reject_reason FROM iris_staging.substation WHERE load_status = 'rejected'
           ORDER BY 1"""
    ).fetchall()
    rejected = dict(rows)
    assert set(rejected) == {"P-005", "P-006", "SS-03"}
    assert rejected["P-005"].startswith("invalid geometry")
    assert rejected["P-006"] == "missing geometry"
    assert "SRID 3857" in rejected["SS-03"]

    pending = conn.execute(
        "SELECT count(*) FROM iris_staging.parcel WHERE load_status = 'pending'"
    ).fetchone()[0]
    assert pending == 0


def test_missing_attributes_are_not_invented(conn):
    voltage = conn.execute(
        "SELECT voltage_kv FROM iris_core.substation WHERE country_code = 'DE' AND source_feature_id = 'SS-02'"
    ).fetchone()[0]
    assert voltage is None


def test_geojson_round_trip_through_core(conn):
    ring = [[11.41, 48.41], [11.4113, 48.41], [11.4113, 48.4109], [11.41, 48.4109], [11.41, 48.41]]
    geojson_in = json.dumps({"type": "Polygon", "coordinates": [ring]})
    run = run_id(conn, "DE", "de_synthetic_cadastre")

    parcel_id = conn.execute(
        INSERT_PARCEL.format(geom="ST_Multi(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326), 3035))"),
        ("ROUNDTRIP", run, geojson_in),
    ).fetchone()[0]

    srid, geojson_out = conn.execute(
        "SELECT ST_SRID(geom), ST_AsGeoJSON(ST_Transform(geom, 4326), 9) FROM iris_core.parcel "
        "WHERE country_code = 'DE' AND id = %s",
        (parcel_id,),
    ).fetchone()

    assert srid == 3035
    ring_out = json.loads(geojson_out)["coordinates"][0][0]
    assert len(ring_out) == len(ring)
    for (x_in, y_in), (x_out, y_out) in zip(ring, ring_out):
        assert x_out == pytest.approx(x_in, abs=1e-8)
        assert y_out == pytest.approx(y_in, abs=1e-8)


def test_area_m2_matches_geodesic_area(conn):
    """EPSG:3035 is equal-area, so area_m2 should agree with the geodesic area on the ellipsoid."""
    stored, geodesic = conn.execute(
        "SELECT area_m2, ST_Area(ST_Transform(geom, 4326)::geography) FROM iris_core.parcel "
        "WHERE country_code = 'DE' AND source_feature_id = 'P-001'"
    ).fetchone()
    assert stored == pytest.approx(geodesic, rel=1e-3)


def test_evidence_matches_fixture_layout(conn):
    rows = conn.execute(
        """SELECT p.source_feature_id, e.check_type
             FROM iris_core.evidence e
             JOIN iris_core.parcel p ON p.country_code = e.country_code AND p.id = e.parcel_id
            WHERE e.check_type <> 'substation_distance'
            ORDER BY 1, 2"""
    ).fetchall()
    assert rows == [
        ("P-001", "peatland_overlap"),
        ("P-002", "peatland_overlap"),
        ("P-003", "screening_overlap"),
    ]
    distance_rows = conn.execute(
        "SELECT count(*) FROM iris_core.evidence WHERE check_type = 'substation_distance' AND value > 0"
    ).fetchone()[0]
    assert distance_rows == 4


def plan_index_names(conn, query: str) -> set[str]:
    conn.execute("SET LOCAL enable_seqscan = off")
    plan = conn.execute("EXPLAIN (FORMAT JSON) " + query).fetchone()[0]
    names = set()

    def walk(node):
        if "Index Name" in node:
            names.add(node["Index Name"])
        for child in node.get("Plans", []):
            walk(child)

    walk(plan[0]["Plan"])
    return names


def test_gist_index_used_for_substation_distance(conn):
    names = plan_index_names(
        conn,
        """SELECT p.id, s.id FROM iris_core.parcel p
             JOIN iris_core.substation s
               ON s.country_code = p.country_code AND ST_DWithin(p.geom, s.geom, 500)
            WHERE p.country_code = 'DE'""",
    )
    assert "substation_geom_gix" in names or "parcel_geom_gix" in names


def test_gist_index_used_for_peatland_overlap(conn):
    names = plan_index_names(
        conn,
        """SELECT p.id, pl.id FROM iris_core.parcel p
             JOIN iris_core.peatland pl
               ON pl.country_code = p.country_code AND ST_Intersects(p.geom, pl.geom)
            WHERE p.country_code = 'DE'""",
    )
    assert "peatland_geom_gix" in names or "parcel_geom_gix" in names
