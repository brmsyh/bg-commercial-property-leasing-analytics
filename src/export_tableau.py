"""Export the tableau.* views to CSV files for Tableau Public / Desktop.

    python src/export_tableau.py

(also called at the end of src/run_pipeline.py)
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import db  # noqa: E402

OUT = db.ROOT / "tableau" / "data"
VIEWS = ["unit_month", "building_scorecard", "tickets", "lease_expiry",
         "receivables", "vacancy_spells", "retention_watchlist"]


def export_all() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    conn = db.connect()
    with conn.cursor() as cur:
        for v in VIEWS:
            target = OUT / f"{v}.csv"
            with open(target, "w", encoding="utf-8", newline="") as f:
                cur.copy_expert(f"COPY (SELECT * FROM tableau.{v}) TO STDOUT WITH (FORMAT csv, HEADER true)", f)
            n = sum(1 for _ in open(target, encoding="utf-8")) - 1
            print(f"   {v:22s} {n:>9,} rows -> {target.relative_to(db.ROOT)}")
    conn.close()


if __name__ == "__main__":
    export_all()
