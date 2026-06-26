#!/usr/bin/env python3
"""
Power Utility Asset Management — CSV → PostgreSQL ETL
=====================================================

Reads a CSV of asset records, validates and cleans each row, and UPSERTs them
into the `assets` table (insert new tags, update existing ones). Designed to be
idempotent: running it twice with the same file leaves the database unchanged.

Usage
-----
    python etl/load_assets.py --csv data/assets_import.csv

Connection settings come from environment variables (with sensible defaults):

    PGHOST      (default: localhost)
    PGPORT      (default: 5432)
    PGDATABASE  (default: power_utility)
    PGUSER      (default: current OS user)
    PGPASSWORD  (default: empty)

or a single DATABASE_URL, e.g.
    export DATABASE_URL="postgresql://user:pass@localhost:5432/power_utility"

Dependencies
------------
    pip install psycopg2-binary
"""

from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
from datetime import datetime
from decimal import Decimal, InvalidOperation

try:
    import psycopg2
    from psycopg2.extras import execute_batch
except ImportError:  # pragma: no cover
    sys.exit(
        "psycopg2 is required. Install it with:\n"
        "    pip install psycopg2-binary"
    )

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("etl")

# Allowed enum values mirrored from the schema so we can fail fast on bad data.
VALID_ASSET_TYPES = {
    "transformer", "circuit_breaker", "transmission_line", "substation",
    "switchgear", "capacitor_bank", "recloser", "meter", "pole", "regulator",
}
VALID_STATUSES = {
    "in_service", "out_of_service", "under_maintenance", "decommissioned",
}

EXPECTED_COLUMNS = [
    "asset_tag", "name", "asset_type", "manufacturer", "model_number",
    "voltage_rating_kv", "location", "latitude", "longitude",
    "install_date", "status", "criticality",
]

UPSERT_SQL = """
    INSERT INTO assets (
        asset_tag, name, asset_type, manufacturer, model_number,
        voltage_rating_kv, location, latitude, longitude,
        install_date, status, criticality
    ) VALUES (
        %(asset_tag)s, %(name)s, %(asset_type)s, %(manufacturer)s,
        %(model_number)s, %(voltage_rating_kv)s, %(location)s,
        %(latitude)s, %(longitude)s, %(install_date)s, %(status)s,
        %(criticality)s
    )
    ON CONFLICT (asset_tag) DO UPDATE SET
        name              = EXCLUDED.name,
        asset_type        = EXCLUDED.asset_type,
        manufacturer      = EXCLUDED.manufacturer,
        model_number      = EXCLUDED.model_number,
        voltage_rating_kv = EXCLUDED.voltage_rating_kv,
        location          = EXCLUDED.location,
        latitude          = EXCLUDED.latitude,
        longitude         = EXCLUDED.longitude,
        install_date      = EXCLUDED.install_date,
        status            = EXCLUDED.status,
        criticality       = EXCLUDED.criticality,
        updated_at        = now();
"""


# --------------------------------------------------------------------------- #
# Transform / validation helpers
# --------------------------------------------------------------------------- #
def _clean_str(value: str | None) -> str | None:
    """Trim whitespace; turn empty strings into None."""
    if value is None:
        return None
    value = value.strip()
    return value or None


def _to_decimal(value: str | None, field: str, row_num: int) -> Decimal | None:
    value = _clean_str(value)
    if value is None:
        return None
    try:
        return Decimal(value)
    except (InvalidOperation, ValueError):
        raise ValueError(f"row {row_num}: '{field}' is not a number: {value!r}")


def _to_int(value: str | None, field: str, row_num: int) -> int | None:
    value = _clean_str(value)
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        raise ValueError(f"row {row_num}: '{field}' is not an integer: {value!r}")


def _to_date(value: str | None, field: str, row_num: int) -> str | None:
    """Accept YYYY-MM-DD or MM/DD/YYYY; return ISO date string."""
    value = _clean_str(value)
    if value is None:
        return None
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%d-%b-%Y"):
        try:
            return datetime.strptime(value, fmt).date().isoformat()
        except ValueError:
            continue
    raise ValueError(f"row {row_num}: '{field}' is not a valid date: {value!r}")


def transform_row(raw: dict[str, str], row_num: int) -> dict:
    """Validate and coerce one CSV row into a DB-ready dict. Raises ValueError."""
    asset_tag = _clean_str(raw.get("asset_tag"))
    name = _clean_str(raw.get("name"))
    asset_type = (_clean_str(raw.get("asset_type")) or "").lower()
    status = (_clean_str(raw.get("status")) or "in_service").lower()
    location = _clean_str(raw.get("location"))

    # Required-field checks.
    if not asset_tag:
        raise ValueError(f"row {row_num}: asset_tag is required")
    if not name:
        raise ValueError(f"row {row_num}: name is required")
    if not location:
        raise ValueError(f"row {row_num}: location is required")
    if asset_type not in VALID_ASSET_TYPES:
        raise ValueError(
            f"row {row_num}: invalid asset_type {asset_type!r}; "
            f"must be one of {sorted(VALID_ASSET_TYPES)}"
        )
    if status not in VALID_STATUSES:
        raise ValueError(
            f"row {row_num}: invalid status {status!r}; "
            f"must be one of {sorted(VALID_STATUSES)}"
        )

    criticality = _to_int(raw.get("criticality"), "criticality", row_num)
    if criticality is None:
        criticality = 3
    if not 1 <= criticality <= 5:
        raise ValueError(
            f"row {row_num}: criticality must be 1-5, got {criticality}"
        )

    return {
        "asset_tag": asset_tag,
        "name": name,
        "asset_type": asset_type,
        "manufacturer": _clean_str(raw.get("manufacturer")),
        "model_number": _clean_str(raw.get("model_number")),
        "voltage_rating_kv": _to_decimal(
            raw.get("voltage_rating_kv"), "voltage_rating_kv", row_num),
        "location": location,
        "latitude": _to_decimal(raw.get("latitude"), "latitude", row_num),
        "longitude": _to_decimal(raw.get("longitude"), "longitude", row_num),
        "install_date": _to_date(raw.get("install_date"), "install_date", row_num),
        "status": status,
        "criticality": criticality,
    }


# --------------------------------------------------------------------------- #
# Extract
# --------------------------------------------------------------------------- #
def read_csv(path: str) -> tuple[list[dict], list[str]]:
    """Read the CSV; return (clean_rows, errors)."""
    if not os.path.exists(path):
        sys.exit(f"CSV file not found: {path}")

    clean_rows: list[dict] = []
    errors: list[str] = []

    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)

        missing = [c for c in ("asset_tag", "name", "asset_type", "location")
                   if c not in (reader.fieldnames or [])]
        if missing:
            sys.exit(f"CSV is missing required columns: {missing}\n"
                     f"Found columns: {reader.fieldnames}")

        # Enumerate from 2 because row 1 is the header.
        for row_num, raw in enumerate(reader, start=2):
            try:
                clean_rows.append(transform_row(raw, row_num))
            except ValueError as exc:
                errors.append(str(exc))

    return clean_rows, errors


# --------------------------------------------------------------------------- #
# Load
# --------------------------------------------------------------------------- #
def get_connection():
    """Build a psycopg2 connection from DATABASE_URL or PG* env vars."""
    dsn = os.environ.get("DATABASE_URL")
    if dsn:
        return psycopg2.connect(dsn)
    return psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ.get("PGDATABASE", "power_utility"),
        user=os.environ.get("PGUSER", os.environ.get("USER", "postgres")),
        password=os.environ.get("PGPASSWORD", ""),
    )


def load_rows(rows: list[dict]) -> int:
    """UPSERT the rows in a single transaction. Returns count loaded."""
    if not rows:
        return 0
    conn = get_connection()
    try:
        with conn:  # commits on success, rolls back on exception
            with conn.cursor() as cur:
                execute_batch(cur, UPSERT_SQL, rows, page_size=100)
        return len(rows)
    finally:
        conn.close()


# --------------------------------------------------------------------------- #
# Orchestration
# --------------------------------------------------------------------------- #
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Load power-utility assets from CSV into PostgreSQL.")
    parser.add_argument(
        "--csv", default="data/assets_import.csv",
        help="Path to the assets CSV (default: data/assets_import.csv)")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Validate and report only; do not write to the database.")
    args = parser.parse_args()

    log.info("Reading CSV: %s", args.csv)
    rows, errors = read_csv(args.csv)

    log.info("Parsed %d valid row(s); %d error(s).", len(rows), len(errors))
    for err in errors:
        log.warning("SKIP  %s", err)

    if not rows:
        log.error("No valid rows to load. Aborting.")
        return 1

    if args.dry_run:
        log.info("--dry-run set: not writing. Sample row: %s", rows[0])
        return 0

    try:
        loaded = load_rows(rows)
    except psycopg2.Error as exc:
        log.error("Database error: %s", exc)
        return 2

    log.info("Done. Upserted %d asset row(s) into PostgreSQL.", loaded)
    if errors:
        log.info("(%d row(s) were skipped due to validation errors.)", len(errors))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
