# SQL skills checklist

| Skill | Where | What it does there |
|---|---|---|
| [x] Inner join | `sql/07_seller_category_scorecard.sql` (`stg_seller_order_facts`) | Attaches order outcomes to order x seller rows |
| [x] Left join | `sql/03_fct_orders.sql` | Keeps every order, even with no items or review |
| [x] Anti join | `sql/02_stg_data_quality.sql` (`rpt_dq_checks`) | LEFT JOIN + IS NULL finds orders with no items, reviews or payments |
| [x] Multi-table joins with grain control | `sql/02_stg_data_quality.sql`, `sql/03_fct_orders.sql` | Collapses each table to one row per order first |
| [x] CTE chains | `sql/06_root_cause.sql` (`attribute_late`, `rpt_root_cause_by_state`) | Norms, late orders, counterfactuals, classes |
| [x] ROW_NUMBER | `sql/02_stg_data_quality.sql` (`stg_reviews`) | Keeps one review per order |
| [x] RANK | `sql/04_kpi_trends.sql` (`rpt_kpi_state`) | Ranks states by breach rate |
| [x] DENSE_RANK | `sql/04_kpi_trends.sql` (`rpt_kpi_state`) | Ranks states by whole-percent breach, keeping ties |
| [x] LAG | `sql/04_kpi_trends.sql` (`rpt_kpi_monthly`) | Month-on-month change |
| [x] LEAD | `sql/04_kpi_trends.sql` (`rpt_kpi_monthly`) | Next month's breach rate |
| [x] Running total | `sql/04_kpi_trends.sql` (`running_total_orders`) | ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW |
| [x] Rolling window | `sql/04_kpi_trends.sql`, `sql/05_anomalies.sql` | 3-month pooled rate; 6-month trailing mean and stddev |
| [x] NTILE | `sql/07_seller_category_scorecard.sql` | Volume quartiles, excess-late deciles |
| [x] Percentiles | `sql/04_kpi_trends.sql`, `sql/06_root_cause.sql` | MEDIAN and QUANTILE_CONT for P50, P75, P90 |
| [x] CASE bucketing | `sql/03_fct_orders.sql` (`lateness_bucket`), `sql/07_seller_category_scorecard.sql` (tiers) | On time, 1-3, 4-7, 8+ days late |
| [x] Date arithmetic | `sql/03_fct_orders.sql` | date_diff, date_trunc, CAST to DATE |
| [x] HAVING | `sql/07_seller_category_scorecard.sql`, `sql/06_root_cause.sql` | Minimum-volume filters after grouping |
| [x] Conditional aggregation | `sql/04_kpi_trends.sql` | COUNT(*) FILTER and AVG(CASE ...) |
| [x] COUNT(DISTINCT) | `sql/04_kpi_trends.sql` (`unique_customers`), `sql/02_stg_data_quality.sql` | Counts people and seller counts |
| [x] NULL-safe logic | `sql/03_fct_orders.sql`, `sql/02_stg_data_quality.sql` | COALESCE on flags, NULLIF on denominators, CASE on negative durations |
| [x] Set operations | `sql/01_load_raw.sql` (UNION ALL), `sql/02_stg_data_quality.sql` and `sql/09_robustness.sql` (EXCEPT, INTERSECT) | Row counts; anti-join check; two-way breach check; list overlap |
| [x] Performance note | `scripts/explain_plan.py`, `outputs/explain_plan.txt`, `docs/DECISIONS.md` | A real EXPLAIN showing the filter pushed to the scan |
