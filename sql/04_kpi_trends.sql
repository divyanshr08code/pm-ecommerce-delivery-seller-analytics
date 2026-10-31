-- 04_kpi_trends.sql
-- Question : How are delivery and quality KPIs moving, and which states are worst?
-- Grain    : rpt_kpi_overall = one row; rpt_kpi_monthly = one row per purchase month;
--            rpt_kpi_state = one row per customer state; rpt_state_month = state x month.
-- Metrics  : breach_rate = late / delivered. promise_accuracy = 1 - breach_rate.
--            cancellation_rate = canceled or unavailable / all orders.
--            defect_rate = defect proxy / all orders. Details in docs/METRICS.md.
-- Months are purchase months, so an order's lateness belongs to the month it was bought.
-- Trend window is 2017-01 to 2018-08: earlier and later months have too few orders.

CREATE OR REPLACE TABLE rpt_kpi_overall AS
SELECT
    COUNT(*)                                        AS orders,
    COUNT(*) FILTER (is_delivered)                  AS delivered,
    COUNT(*) FILTER (is_delivered AND is_late)      AS late,
    AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) FILTER (is_delivered) AS breach_rate,
    AVG(CASE WHEN is_late THEN 0.0 ELSE 1 END) FILTER (is_delivered) AS promise_accuracy,
    AVG(total_days)  FILTER (is_delivered)          AS mean_delivery_days,
    MEDIAN(total_days) FILTER (is_delivered)        AS p50_delivery_days,
    QUANTILE_CONT(total_days, 0.9) FILTER (is_delivered) AS p90_delivery_days,
    AVG(promised_days) FILTER (is_delivered)        AS mean_promised_days,
    AVG(approval_lag_days)    FILTER (is_delivered) AS mean_approval_lag_days,
    AVG(seller_handoff_days)  FILTER (is_delivered) AS mean_seller_handoff_days,
    AVG(carrier_transit_days) FILTER (is_delivered) AS mean_carrier_transit_days,
    MEDIAN(approval_lag_days)    FILTER (is_delivered) AS p50_approval_lag_days,
    MEDIAN(seller_handoff_days)  FILTER (is_delivered) AS p50_seller_handoff_days,
    MEDIAN(carrier_transit_days) FILTER (is_delivered) AS p50_carrier_transit_days,
    QUANTILE_CONT(seller_handoff_days, 0.9)  FILTER (is_delivered) AS p90_seller_handoff_days,
    QUANTILE_CONT(carrier_transit_days, 0.9) FILTER (is_delivered) AS p90_carrier_transit_days,
    AVG(days_late) FILTER (is_delivered AND is_late) AS mean_days_late_when_late,
    MEDIAN(days_late) FILTER (is_delivered AND is_late) AS p50_days_late_when_late,
    AVG(CASE WHEN is_canceled_unavailable THEN 1.0 ELSE 0 END) AS cancellation_rate,
    AVG(CASE WHEN is_defect_proxy THEN 1.0 ELSE 0 END)         AS defect_rate,
    COUNT(*) FILTER (is_canceled_unavailable)       AS canceled_unavailable,
    SUM(COALESCE(payment_value, 0)) FILTER (is_canceled_unavailable) AS canceled_unavailable_value,
    SUM(COALESCE(payment_value, 0))                 AS total_payment_value,
    SUM(COALESCE(payment_value, 0)) FILTER (is_delivered AND is_late) AS late_order_value
FROM fct_orders;

CREATE OR REPLACE TABLE rpt_kpi_monthly AS
WITH monthly AS (
    SELECT purchase_month,
           COUNT(*)                                   AS orders,
           COUNT(*) FILTER (is_delivered)             AS delivered,
           COUNT(*) FILTER (is_delivered AND is_late) AS late,
           AVG(total_days)   FILTER (is_delivered)    AS mean_delivery_days,
           MEDIAN(total_days) FILTER (is_delivered)   AS p50_delivery_days,
           QUANTILE_CONT(total_days, 0.9) FILTER (is_delivered) AS p90_delivery_days,
           AVG(promised_days) FILTER (is_delivered)   AS mean_promised_days,
           AVG(seller_handoff_days) FILTER (is_delivered)  AS mean_handoff_days,
           AVG(carrier_transit_days) FILTER (is_delivered) AS mean_transit_days,
           AVG(CASE WHEN is_canceled_unavailable THEN 1.0 ELSE 0 END) AS cancellation_rate,
           AVG(CASE WHEN is_defect_proxy THEN 1.0 ELSE 0 END)         AS defect_rate
    FROM fct_orders
    WHERE purchase_month BETWEEN DATE '2017-01-01' AND DATE '2018-08-01'
    GROUP BY purchase_month
),
with_rate AS (
    SELECT *, late * 1.0 / delivered AS breach_rate FROM monthly
)
SELECT *,
       -- Rolling 3 months: pool the orders rather than averaging the three rates, so that a
       -- small month does not count as much as a big one.
       SUM(late) OVER w3 * 1.0 / SUM(delivered) OVER w3 AS breach_rate_rolling_3m,
       AVG(breach_rate) OVER w3                         AS breach_rate_simple_avg_3m,
       breach_rate - LAG(breach_rate) OVER m            AS breach_rate_mom_change,
       orders * 1.0 / LAG(orders) OVER m - 1            AS orders_mom_growth,
       LEAD(breach_rate) OVER m                         AS next_month_breach_rate,
       SUM(orders) OVER (ORDER BY purchase_month
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total_orders
FROM with_rate
WINDOW m  AS (ORDER BY purchase_month),
       w3 AS (ORDER BY purchase_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
ORDER BY purchase_month;

CREATE OR REPLACE TABLE rpt_kpi_state AS
WITH state AS (
    SELECT customer_state,
           COUNT(*)                                   AS orders,
           COUNT(*) FILTER (is_delivered)             AS delivered,
           COUNT(*) FILTER (is_delivered AND is_late) AS late,
           COUNT(DISTINCT customer_unique_id)         AS unique_customers,
           AVG(total_days)    FILTER (is_delivered)   AS mean_delivery_days,
           MEDIAN(total_days) FILTER (is_delivered)   AS p50_delivery_days,
           QUANTILE_CONT(total_days, 0.9) FILTER (is_delivered) AS p90_delivery_days,
           AVG(promised_days) FILTER (is_delivered)   AS mean_promised_days,
           AVG(CASE WHEN is_defect_proxy THEN 1.0 ELSE 0 END) AS defect_rate
    FROM fct_orders
    GROUP BY customer_state
)
SELECT *,
       late * 1.0 / delivered                        AS breach_rate,
       1 - late * 1.0 / delivered                    AS on_time_rate,
       wilson_low(late, delivered)                   AS breach_ci_low,
       wilson_high(late, delivered)                  AS breach_ci_high,
       RANK()       OVER (ORDER BY late * 1.0 / delivered DESC) AS breach_rank,
       DENSE_RANK() OVER (ORDER BY ROUND(late * 100.0 / delivered, 0) DESC) AS breach_dense_rank_whole_pct,
       orders * 1.0 / SUM(orders) OVER ()            AS share_of_orders,
       late * 1.0 / SUM(late) OVER ()                AS share_of_late,
       SUM(late) OVER (ORDER BY late DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           * 1.0 / SUM(late) OVER ()                 AS cumulative_share_of_late
FROM state
ORDER BY breach_rank;

CREATE OR REPLACE TABLE rpt_state_month AS
SELECT customer_state, purchase_month,
       COUNT(*) FILTER (is_delivered)             AS delivered,
       COUNT(*) FILTER (is_delivered AND is_late) AS late,
       COUNT(*) FILTER (is_delivered AND is_late) * 1.0
           / NULLIF(COUNT(*) FILTER (is_delivered), 0) AS breach_rate
FROM fct_orders
WHERE purchase_month BETWEEN DATE '2017-01-01' AND DATE '2018-08-01'
GROUP BY customer_state, purchase_month
ORDER BY customer_state, purchase_month;

-- Performance note: scripts/explain_plan.py saves a real EXPLAIN of this state-month query to
-- outputs/explain_plan.txt, showing where the month filter is applied.
