"""Run every sql/NN_*.sql file in order against a fresh DuckDB file, then export
each rpt_* and dash_* table to outputs/tables/ as CSV.

Why a fresh file every time: the build must be reproducible from raw CSVs, with
no hidden state left over from an earlier run.
"""
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "olist.duckdb"
TABLES = ROOT / "outputs" / "tables"


def main() -> int:
    DB.unlink(missing_ok=True)
    TABLES.mkdir(parents=True, exist_ok=True)
    for old in TABLES.glob("*.csv"):
        old.unlink()

    con = duckdb.connect(str(DB))
    for path in sorted((ROOT / "sql").glob("[0-9][0-9]_*.sql")):
        print(f"Running {path.name}")
        # The SQL uses relative paths such as data/raw/x.csv, so run this script from the project root.
        con.execute(path.read_text(encoding="utf-8")).fetchall()

    names = [r[0] for r in con.sql(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_name LIKE 'rpt\\_%' ESCAPE '\\' "
        "OR table_name LIKE 'dash\\_%' ESCAPE '\\' ORDER BY 1").fetchall()]
    for name in names:
        out = (TABLES / f"{name}.csv").as_posix()
        con.execute(f"COPY {name} TO '{out}' (HEADER, DELIMITER ',')").fetchall()
    print(f"Exported {len(names)} tables to {TABLES}")
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
