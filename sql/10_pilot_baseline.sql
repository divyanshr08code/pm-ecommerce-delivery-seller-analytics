-- 10_pilot_baseline.sql
-- Question : What is the pilot's baseline, and how long must it run to detect an improvement?
-- Grain    : rpt_pilot_segments = one row per candidate segment.
--            rpt_pilot_sizing = one row per segment x baseline x target improvement.
-- Metrics  : two-proportion sample size per arm (alpha 5% two-sided, power 80%):
--            n = (1.96 + 0.84)^2 * (p1(1-p1) + p2(1-p2)) / (p1 - p2)^2
-- Volume is the recent run rate: delivered orders per month over Apr-Aug 2018.
-- Non-wave baseline: a pilot should not assume a wave will occur during its window.

CREATE OR REPLACE TABLE rpt_pilot_segments AS
WITH waves AS (
    SELECT purchase_month FROM rpt_kpi_monthly WHERE breach_rate >= 0.12
),
facts AS (
    SELECT f.*, w.purchase_month IS NOT NULL AS is_wave
    FROM fct_orders f LEFT JOIN waves w USING (purchase_month)
    WHERE f.is_delivered AND f.purchase_month BETWEEN DATE '2017-01-01' AND DATE '2018-08-01'
),
segments AS (
    SELECT 'Customers in RJ' AS segment, * FROM facts WHERE customer_state = 'RJ'
    UNION ALL SELECT 'Lane SP>RJ', * FROM facts WHERE lane = 'SP>RJ'
    UNION ALL SELECT 'Customers in AL', * FROM facts WHERE customer_state = 'AL'
    UNION ALL SELECT 'Customers in RJ, BA, ES', * FROM facts WHERE customer_state IN ('RJ', 'BA', 'ES')
)
SELECT segment,
       COUNT(*)                                                    AS delivered,
       COUNT(*) FILTER (is_late)                                   AS late,
       AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END)                  AS breach_rate,
       AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) FILTER (NOT is_wave) AS non_wave_breach_rate,
       AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) FILTER (is_wave)     AS wave_breach_rate,
       COUNT(*) FILTER (purchase_month >= DATE '2018-04-01') / 5.0 AS recent_orders_per_month,
       -- The share of pilot-eligible orders that would receive an alert: guardrail for ops load.
       QUANTILE_CONT(carrier_transit_days, 0.75)                   AS p75_transit_days
FROM segments
GROUP BY segment
ORDER BY late DESC;

CREATE OR REPLACE TABLE rpt_pilot_sizing AS
WITH targets AS (
    SELECT * FROM (VALUES (0.25), (0.33), (0.50)) AS t(relative_reduction)
),
inputs AS (
    SELECT s.segment, s.non_wave_breach_rate AS p1, t.relative_reduction,
           s.non_wave_breach_rate * (1 - t.relative_reduction) AS p2,
           s.recent_orders_per_month
    FROM rpt_pilot_segments s CROSS JOIN targets t
)
SELECT segment, p1 AS baseline_rate, relative_reduction, p2 AS target_rate, recent_orders_per_month,
       CEIL(pow(1.96 + 0.84, 2) * (p1 * (1 - p1) + p2 * (1 - p2)) / pow(p1 - p2, 2)) AS n_per_arm,
       CEIL(pow(1.96 + 0.84, 2) * (p1 * (1 - p1) + p2 * (1 - p2)) / pow(p1 - p2, 2)) * 2
           / recent_orders_per_month AS months_needed
FROM inputs
ORDER BY segment, relative_reduction;

-- Sellers who would be in scope of the dispatch SOP: enough volume, and missing deadlines often.
CREATE OR REPLACE TABLE rpt_sop_scope AS
SELECT COUNT(*) AS scored_sellers,
       COUNT(*) FILTER (dispatch_miss_rate >= 0.20) AS sellers_miss_20pct,
       SUM(delivered) FILTER (dispatch_miss_rate >= 0.20) AS orders_of_those_sellers,
       SUM(late) FILTER (dispatch_miss_rate >= 0.20) AS late_of_those_sellers,
       SUM(late) FILTER (dispatch_miss_rate >= 0.20) * 1.0 / SUM(delivered) FILTER (dispatch_miss_rate >= 0.20) AS breach_rate_those,
       SUM(late) FILTER (dispatch_miss_rate < 0.20) * 1.0 / SUM(delivered) FILTER (dispatch_miss_rate < 0.20) AS breach_rate_others
FROM rpt_seller_scorecard;
