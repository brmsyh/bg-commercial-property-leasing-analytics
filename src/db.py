"""Database helper shared by the notebook, the pipeline runner and the Tableau export.

Connects with psycopg2 (pure Python - no psql.exe needed, works the same on
Windows, macOS and Linux). Connection settings are read from a `.env` file in the
repository root (copy `.env.example` to `.env` and put your password in it), or
from the standard environment variables PGHOST, PGPORT, PGUSER, PGPASSWORD,
PGDATABASE.
"""
from __future__ import annotations

import os
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql" / "analysis"


# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
def _load_env_file() -> None:
    env = ROOT / ".env"
    if not env.exists():
        return
    for line in env.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        # the project's .env always wins over stale variables left in the terminal session
        os.environ[key.strip()] = value.strip().strip('"').strip("'")


_load_env_file()
SETTINGS = {
    "host": os.environ.get("PGHOST", "localhost"),
    "port": int(os.environ.get("PGPORT", "5432")),
    "user": os.environ.get("PGUSER", "postgres"),
    "password": os.environ.get("PGPASSWORD", ""),
    "dbname": os.environ.get("PGDATABASE", "bg_property"),
}


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------
try:
    import psycopg2
    import psycopg2.extensions as _ext

    # return NUMERIC columns as float (pandas / matplotlib friendly) instead of Decimal
    _DEC2FLOAT = _ext.new_type(_ext.DECIMAL.values, "DEC2FLOAT",
                               lambda v, cur: float(v) if v is not None else None)
    _ext.register_type(_DEC2FLOAT)
except ImportError as exc:  # pragma: no cover
    raise ImportError(
        "psycopg2 is not installed. Run:  pip install psycopg2-binary\n"
        "(or: pip install -r requirements.txt)"
    ) from exc


def connect(dbname: str | None = None):
    """Open a connection; raises a readable error when something is wrong."""
    params = dict(SETTINGS)
    if dbname:
        params["dbname"] = dbname
    try:
        conn = psycopg2.connect(**params)
    except psycopg2.OperationalError as exc:
        msg = str(exc).strip()
        hint = ""
        if "password" in msg.lower():
            hint = ("Check PGPASSWORD in the .env file in the repository root "
                    "(copy .env.example to .env and fill in your PostgreSQL password).")
        elif "does not exist" in msg.lower():
            hint = "The database has not been built yet. Run:  python src/run_pipeline.py"
        elif "connection refused" in msg.lower() or "could not connect" in msg.lower():
            hint = "Is the PostgreSQL service running? Check PGHOST / PGPORT in .env."
        raise ConnectionError(f"Cannot connect to PostgreSQL ({params['user']}@{params['host']}:"
                              f"{params['port']}/{params['dbname']}).\n{msg}\n{hint}") from None
    conn.set_client_encoding("UTF8")
    return conn


_conn = None


def _get_conn():
    global _conn
    if _conn is None or _conn.closed:
        _conn = connect()
        _conn.autocommit = True
    return _conn


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------
def query(sql: str) -> pd.DataFrame:
    """Run a SELECT and return a DataFrame."""
    with _get_conn().cursor() as cur:
        cur.execute(sql)
        cols = [d[0] for d in cur.description]
        return pd.DataFrame(cur.fetchall(), columns=cols)


def run_file(name: str) -> pd.DataFrame:
    """Run one of the analysis queries in sql/analysis/ by file name (without .sql)."""
    sql = (SQL_DIR / f"{name}.sql").read_text(encoding="utf-8")
    return query(sql.strip().rstrip(";"))
