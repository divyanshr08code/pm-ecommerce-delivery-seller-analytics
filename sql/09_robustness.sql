-- 09_robustness.sql
-- Question : Do the headline conclusions survive a change of definition or filter?
-- Grain    : rpt_robustness = one row per test. rpt_two_way_check = one row per reproduced number.
-- Metrics  : base_value is the headline; variant_value is the same metric under the changed rule.
--            how_to_read says what result would support or undermine the claim. Failing is allowed.

-- ---------- Alternative attribution: "normal" transit measured within the same month ----------
-- This is the strongest challenge to "carrier is the problem". If a whole month is slow, the norm
-- slows too, so wave lateness moves to "promise" (the estimate did not adapt to current conditions).
CREATE OR REPLACE TABLE stg_late_month_norm AS
WITH lane_month AS (
    SELECT lane, purchase_month, QUANTILE_CONT(carrier_transit_days, 0.75) AS n
    FROM fct_orders WHERE is_delivered AND carrier_transit_days IS NOT NULL
    GROUP BY lane, purchase_month HAVING COUNT(*) >= 30
),
state_month AS (
    SELECT customer_state, purchase_month, QUANTILE_CONT(carrier_transit_days, 0.75) AS n
    FROM fct_orders WHERE is_delivered AND carrier_transit_days IS NOT NULL
    GROUP BY customer_state, purchase_month
),
tested AS (
    SELECT f.order_id,
           CAST(LEAST(f.carrier_ts, f.shipping_limit_ts)
                + to_seconds(CAST(LEAST(f.carrier_transit_days, COALESCE(l.n, s.n)) * 86400 AS BIGINT)) AS DATE)
             > f.estimated_date AS late_with_normal_execution
    FROM fct_orders f
    LEFT JOIN lane_month  l ON l.lane = f.lane AND l.purchase_month = f.purchase_month
    LEFT JOIN state_month s ON s.customer_state = f.customer_state AND s.purchase_month = f.purchase_month
    WHERE f.is_delivered AND f.is_late AND f.carrier_transit_days IS NOT NULL AND f.shipping_limit_ts IS NOT NULL
)
SELECT * FROM tested;

-- ---------- Independent promise test with no seller or carrier logic ----------
-- Compare each late order's promise with what its lane usually takes end to end.
CREATE OR REPLACE TABLE stg_promise_simple AS
WITH lane_total AS (
    SELECT lane, MEDIAN(total_days) AS p50, QUANTILE_CONT(total_days, 0.75) AS p75
    FROM fct_orders WHERE is_delivered
    GROUP BY lane HAVING COUNT(*) >= 30
)
SELECT f.order_id, f.promised_days < t.p50 AS below_lane_p50, f.promised_days < t.p75 AS below_lane_p75
FROM fct_orders f
JOIN lane_total t USING (lane)
WHERE f.is_delivered AND f.is_late;

-- ---------- Variants ----------
CREATE OR REPLACE TABLE rpt_robustness AS
WITH base AS (
    SELECT breach_rate, delivered, late FROM rpt_kpi_overall
),
exec_share AS (
    SELECT execution_share AS v FROM rpt_promise_vs_execution
),
open_past AS (
    -- Survivorship: orders never delivered and past their promise by the data's last date.
    SELECT COUNT(*) AS n FROM fct_orders
    WHERE NOT is_delivered AND NOT is_canceled_unavailable
      AND estimated_date < (SELECT CAST(MAX(purchase_ts) AS DATE) FROM fct_orders)
),
top5_date AS (
    SELECT customer_state FROM rpt_kpi_state ORDER BY breach_rank LIMIT 5
),
state_ts AS (
    SELECT customer_state,
           RANK() OVER (ORDER BY AVG(CASE WHEN is_late_by_timestamp THEN 1.0 ELSE 0 END) DESC) AS r
    FROM fct_orders WHERE is_delivered GROUP BY customer_state
),
top5_overlap AS (
    SELECT COUNT(*) AS n FROM top5_date JOIN state_ts USING (customer_state) WHERE r <= 5
),
seller_vol AS (
    SELECT seller_id, COUNT(*) AS n FROM stg_seller_order_facts WHERE is_delivered GROUP BY seller_id
),
attr AS (
    SELECT a.root_cause, a.purchase_month, a.seller_count, COALESCE(v.n, 0) AS seller_volume
    FROM stg_late_attributed a
    LEFT JOIN seller_vol v ON v.seller_id = a.primary_seller_id
    WHERE a.root_cause <> 'unattributable'
),
waves AS (
    SELECT purchase_month FROM rpt_kpi_monthly WHERE breach_rate >= 0.12
),
top10_30 AS (
    SELECT seller_id FROM rpt_seller_scorecard ORDER BY worst_rank LIMIT 10
),
top10_100 AS (
    SELECT seller_id FROM rpt_seller_scorecard WHERE delivered >= 100 ORDER BY worst_rank LIMIT 10
)
          SELECT 'Breach by timestamp instead of date' AS test, 'breach_rate' AS metric,
                 (SELECT breach_rate FROM base) AS base_value,
                 (SELECT AVG(CASE WHEN is_late_by_timestamp THEN 1.0 ELSE 0 END) FROM fct_orders WHERE is_delivered) AS variant_value,
                 'Rate rises because same-day deliveries count as late; ordering is tested next' AS how_to_read
UNION ALL SELECT 'Top-5 worst states: date vs timestamp', 'states in common (of 5)', 5,
                 (SELECT n FROM top5_overlap), 'Worst-state list is mostly unchanged if 4 or 5'
UNION ALL SELECT 'Count open orders past promise as late (survivorship)', 'breach_rate',
                 (SELECT breach_rate FROM base),
                 ((SELECT late FROM base) + (SELECT n FROM open_past)) * 1.0
                   / ((SELECT delivered FROM base) + (SELECT n FROM open_past)),
                 'Upper bound: headline understates failure, still a minority of orders'
UNION ALL SELECT 'Open orders past promise', 'orders', 0, (SELECT n FROM open_past), 'Context for the row above'
UNION ALL SELECT 'Execution share: transit norm P50', 'execution_share', (SELECT v FROM exec_share),
                 (SELECT COUNT(*) FILTER (root_cause <> 'promise') * 1.0 / COUNT(*)
                    FROM attribute_late(0.50) WHERE root_cause <> 'unattributable'),
                 'Execution remains the majority if above 0.5'
UNION ALL SELECT 'Execution share: transit norm P90', 'execution_share', (SELECT v FROM exec_share),
                 (SELECT COUNT(*) FILTER (root_cause <> 'promise') * 1.0 / COUNT(*)
                    FROM attribute_late(0.90) WHERE root_cause <> 'unattributable'),
                 'Execution remains the majority if above 0.5'
UNION ALL SELECT 'Execution share: transit norm from the same month', 'execution_share', (SELECT v FROM exec_share),
                 (SELECT COUNT(*) FILTER (NOT late_with_normal_execution) * 1.0 / COUNT(*) FROM stg_late_month_norm),
                 'Strongest challenge: a slow month raises its own norm'
UNION ALL SELECT 'Execution share: drop sellers under 30 orders', 'execution_share', (SELECT v FROM exec_share),
                 (SELECT COUNT(*) FILTER (root_cause <> 'promise') * 1.0 / COUNT(*) FROM attr WHERE seller_volume >= 30),
                 'Execution remains the majority if above 0.5'
UNION ALL SELECT 'Execution share: drop multi-seller orders', 'execution_share', (SELECT v FROM exec_share),
                 (SELECT COUNT(*) FILTER (root_cause <> 'promise') * 1.0 / COUNT(*) FROM attr WHERE seller_count = 1),
                 'Execution remains the majority if above 0.5'
UNION ALL SELECT 'Execution share: drop the three wave months', 'execution_share', (SELECT v FROM exec_share),
                 (SELECT COUNT(*) FILTER (root_cause <> 'promise') * 1.0 / COUNT(*) FROM attr
                   WHERE purchase_month NOT IN (SELECT purchase_month FROM waves)),
                 'Execution remains the majority if above 0.5'
UNION ALL SELECT 'Late orders with promise below lane median total', 'share_of_late', NULL,
                 (SELECT AVG(CASE WHEN below_lane_p50 THEN 1.0 ELSE 0 END) FROM stg_promise_simple),
                 'Independent promise test: a low share supports execution'
UNION ALL SELECT 'Late orders with promise below lane P75 total', 'share_of_late', NULL,
                 (SELECT AVG(CASE WHEN below_lane_p75 THEN 1.0 ELSE 0 END) FROM stg_promise_simple),
                 'Independent promise test: a low share supports execution'
UNION ALL SELECT 'Worst-10 sellers: min 30 vs min 100 orders', 'sellers in common (of 10)', 10,
                 (SELECT COUNT(*) FROM (SELECT seller_id FROM top10_30 INTERSECT SELECT seller_id FROM top10_100)),
                 'Low overlap means the bottom list depends on the volume filter'
UNION ALL SELECT 'Defect rate: reviewed orders only as denominator', 'defect_rate',
                 (SELECT defect_rate FROM rpt_kpi_overall),
                 (SELECT AVG(CASE WHEN is_defect_proxy THEN 1.0 ELSE 0 END) FROM fct_orders WHERE review_score IS NOT NULL),
                 'Small movement means missing reviews barely affect the proxy'
UNION ALL SELECT 'Share of low reviews on on-time orders: earliest review instead of latest', 'share_low_reviews_on_time',
                 (SELECT share_low_reviews_on_time FROM rpt_low_review_split),
                 (WITH first_review AS (
                      SELECT order_id, review_score,
                             ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY review_answer_timestamp, review_id) AS rn
                      FROM raw_reviews)
                  SELECT COUNT(*) FILTER (r.review_score <= 2 AND NOT f.is_late) * 1.0 / COUNT(*) FILTER (r.review_score <= 2)
                  FROM fct_orders f JOIN first_review r ON r.order_id = f.order_id AND r.rn = 1
                  WHERE f.is_delivered),
                 'Choice of review for duplicates does not change the finding if close';

-- ---------- One number, two independent SQL formulations ----------
-- A: FILTER aggregates on the fact table. B: set operations straight on raw orders, with no use
-- of fct_orders: all delivered ids EXCEPT those delivered by the promised date.
CREATE OR REPLACE TABLE rpt_two_way_check AS
WITH delivered_ids AS (
    SELECT order_id FROM raw_orders
    WHERE order_status = 'delivered' AND order_delivered_customer_date IS NOT NULL
),
on_time_ids AS (
    SELECT order_id FROM raw_orders
    WHERE order_status = 'delivered'
      AND CAST(order_delivered_customer_date AS DATE) <= CAST(order_estimated_delivery_date AS DATE)
),
late_ids AS (
    SELECT order_id FROM delivered_ids EXCEPT SELECT order_id FROM on_time_ids
)
SELECT 'breach_rate' AS metric,
       (SELECT breach_rate FROM rpt_kpi_overall) AS method_a_fact_filter,
       (SELECT COUNT(*) FROM late_ids) * 1.0 / (SELECT COUNT(*) FROM delivered_ids) AS method_b_raw_except;

SELECT CASE WHEN abs(method_a_fact_filter - method_b_raw_except) > 1e-12
            THEN error('two-way breach rate check failed') END FROM rpt_two_way_check;
