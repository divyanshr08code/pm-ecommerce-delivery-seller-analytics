"""Save a real query plan for the performance note in docs/DECISIONS.md."""
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent
QUERY = """
SELECT customer_state, purchase_month, COUNT(*) FILTER (is_delivered) AS delivered
FROM fct_orders
WHERE purchase_month BETWEEN DATE '2017-01-01' AND DATE '2018-08-01'
GROUP BY customer_state, purchase_month
"""

con = duckdb.connect(str(ROOT / "data" / "olist.duckdb"), read_only=True)
plan = con.sql("EXPLAIN " + QUERY).fetchall()
text = "\n".join(row[1] for row in plan)
out = ROOT / "outputs" / "explain_plan.txt"
out.write_text(QUERY + "\n" + text + "\n", encoding="utf-8")
print(f"Saved {out}")
