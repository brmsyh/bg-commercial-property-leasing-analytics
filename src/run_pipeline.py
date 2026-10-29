"""Build the whole PostgreSQL pipeline from the raw CSV extracts - no psql needed.

    python src/run_pipeline.py

Steps: create database (if missing) -> 01 raw schema -> 02 load CSVs -> 03 clean
-> 04 mart -> 05 Tableau views -> export tableau/data/*.csv.
Connection settings come from .env (see .env.example).
"""
from __future__ import annotations

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import db  # noqa: E402
from export_tableau import export_all  # noqa: E402

ROOT = db.ROOT
SQL = ROOT / "sql"
COPY_RE = re.compile(r"^\\copy\s+(\S+)\s+FROM\s+'([^']+)'", re.IGNORECASE)


def ensure_database() -> None:
    name = db.SETTINGS["dbname"]
    try:                                   # database already exists (e.g. neondb on Neon)?
        db.connect().close()
        return
    except ConnectionError:
        pass
    conn = db.connect(dbname="postgres")
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (name,))
        if cur.fetchone() is None:
            cur.execute(f'CREATE DATABASE "{name}" ENCODING \'UTF8\' TEMPLATE template0')
            print(f"created database {name}")
    conn.close()


def print_result(cur) -> None:
    if cur.description:
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
        widths = [max(len(str(c)), *(len(str(r[i])) for r in rows)) if rows else len(str(c))
                  for i, c in enumerate(cols)]
        print("   " + "  ".join(str(c).ljust(w) for c, w in zip(cols, widths)))
        for r in rows:
            print("   " + "  ".join(str(v).ljust(w) for v, w in zip(r, widths)))


def run_sql_file(conn, path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    statements, buffer = [], []
    with conn.cursor() as cur:
        # psql meta-commands (\copy) are executed with COPY ... FROM STDIN
        for line in text.splitlines():
            m = COPY_RE.match(line.strip())
            if m:
                table, rel_path = m.groups()
                with open(ROOT / rel_path, "r", encoding="utf-8", newline="") as f:
                    cur.copy_expert(f"COPY {table} FROM STDIN WITH (FORMAT csv, HEADER true)", f)
                print(f"   loaded {rel_path:45s} -> {table} ({cur.rowcount:,} rows)")
            else:
                buffer.append(line)
        rest = "\n".join(buffer).strip()
        if rest:
            cur.execute(rest)
            print_result(cur)


def main() -> None:
    t0 = time.time()
    ensure_database()
    conn = db.connect()
    conn.autocommit = True
    for name in ["01_raw_schema.sql", "02_load_raw.sql", "03_clean.sql", "04_mart.sql", "05_tableau_views.sql"]:
        print(f">> {name}")
        run_sql_file(conn, SQL / name)
    conn.close()
    print(">> exporting Tableau extracts")
    export_all()
    print(f"done in {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()
