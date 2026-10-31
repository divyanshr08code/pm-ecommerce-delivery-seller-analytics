-- 06_root_cause.sql
-- Question : For each late order, what was the cause: an unrealistic promise, a seller who missed
--            the dispatch deadline, or a carrier slower than normal for that route?
-- Grain    : attribute_late() = one row per late delivered order.
--            rpt_root_cause = one row per cause. rpt_root_cause_by_state = state x cause.
-- Metrics  : counterfactual test on each late order. Replace a stage with its "normal" version
--            and ask if the order would then have arrived by the promised date.
--              seller fixed : pickup no later than the seller's shipping_limit deadline
--              carrier fixed: transit no longer than the lane's normal (default P75) transit
--              promise      : late even with BOTH fixed, so normal execution cannot hit the date
--              seller       : fixing the seller alone rescues it, fixing the carrier alone does not
--              carrier      : fixing the carrier alone rescues it, fixing the seller alone does not
--              either       : either fix alone would rescue it (two independent failures)
--              compound     : only fixing both rescues it
--              unattributable: a timestamp needed for the test is missing or invalid
-- A lane is seller state > customer state. Lanes with < 30 orders use the customer state's norm.

CREATE OR REPLACE MACRO attribute_late(norm_pct) AS TABLE
WITH lane_norm AS (
    SELECT lane, QUANTILE_CONT(carrier_transit_days, norm_pct) AS transit_norm
    FROM fct_orders
    WHERE is_delivered AND carrier_transit_days IS NOT NULL
    GROUP BY lane
    HAVING COUNT(*) >= 30
),
state_norm AS (
    SELECT customer_state, QUANTILE_CONT(carrier_transit_days, norm_pct) AS transit_norm
    FROM fct_orders
    WHERE is_delivered AND carrier_transit_days IS NOT NULL
    GROUP BY customer_state
),
late_orders AS (
    SELECT f.*, COALESCE(l.transit_norm, s.transit_norm) AS transit_norm
    FROM fct_orders f
    LEFT JOIN lane_norm  l ON l.lane = f.lane
    LEFT JOIN state_norm s ON s.customer_state = f.customer_state
    WHERE f.is_delivered AND f.is_late
),
counterfactuals AS (
    SELECT *,
           -- Seller fixed: pickup moves back to the deadline, the actual transit is kept.
           CAST(LEAST(carrier_ts, shipping_limit_ts)
                + to_seconds(CAST(carrier_transit_days * 86400 AS BIGINT)) AS DATE) AS seller_fixed_date,
           -- Carrier fixed: actual pickup is kept, transit capped at the lane norm.
           CAST(carrier_ts
                + to_seconds(CAST(LEAST(carrier_transit_days, transit_norm) * 86400 AS BIGINT)) AS DATE) AS carrier_fixed_date,
           -- Both fixed: what normal execution would have delivered.
           CAST(LEAST(carrier_ts, shipping_limit_ts)
                + to_seconds(CAST(LEAST(carrier_transit_days, transit_norm) * 86400 AS BIGINT)) AS DATE) AS both_fixed_date
    FROM late_orders
)
SELECT *,
       CASE WHEN carrier_transit_days IS NULL OR shipping_limit_ts IS NULL THEN 'unattributable'
            WHEN both_fixed_date > estimated_date                          THEN 'promise'
            WHEN seller_fixed_date <= estimated_date
             AND carrier_fixed_date <= estimated_date                      THEN 'either'
            WHEN seller_fixed_date <= estimated_date                       THEN 'seller'
            WHEN carrier_fixed_date <= estimated_date                      THEN 'carrier'
            ELSE 'compound' END AS root_cause
FROM counterfactuals;

CREATE OR REPLACE TABLE stg_late_attributed AS
SELECT * FROM attribute_late(0.75);

-- Every late order gets exactly one cause.
SELECT CASE WHEN (SELECT COUNT(*) FROM stg_late_attributed)
              <> (SELECT COUNT(*) FROM fct_orders WHERE is_delivered AND is_late)
            THEN error('root cause attribution lost or duplicated late orders') END;

CREATE OR REPLACE TABLE rpt_root_cause AS
SELECT root_cause,
       COUNT(*)                         AS late_orders,
       COUNT(*) * 1.0 / SUM(COUNT(*)) OVER () AS share_of_late,
       AVG(days_late)                   AS mean_days_late,
       AVG(promised_days)               AS mean_promised_days,
       AVG(carrier_transit_days)        AS mean_transit_days,
       AVG(seller_handoff_days)         AS mean_handoff_days
FROM stg_late_attributed
GROUP BY root_cause
ORDER BY late_orders DESC;

-- The stance in one row: promise versus execution.
CREATE OR REPLACE TABLE rpt_promise_vs_execution AS
WITH attributable AS (
    SELECT * FROM stg_late_attributed WHERE root_cause <> 'unattributable'
)
SELECT COUNT(*)                                                  AS attributable_late,
       COUNT(*) FILTER (root_cause = 'promise')                  AS promise_orders,
       COUNT(*) FILTER (root_cause <> 'promise')                 AS execution_orders,
       COUNT(*) FILTER (root_cause = 'promise') * 1.0 / COUNT(*) AS promise_share,
       COUNT(*) FILTER (root_cause <> 'promise') * 1.0 / COUNT(*) AS execution_share,
       COUNT(*) FILTER (root_cause = 'carrier') * 1.0 / COUNT(*) AS carrier_share,
       COUNT(*) FILTER (root_cause = 'seller')  * 1.0 / COUNT(*) AS seller_share,
       COUNT(*) FILTER (root_cause = 'either')  * 1.0 / COUNT(*) AS either_share,
       COUNT(*) FILTER (root_cause = 'compound') * 1.0 / COUNT(*) AS compound_share
FROM attributable;

-- A CTE chain: count -> share within state -> rank -> keep alongside the dominant cause.
CREATE OR REPLACE TABLE rpt_root_cause_by_state AS
WITH counts AS (
    SELECT customer_state, root_cause, COUNT(*) AS late_orders
    FROM stg_late_attributed
    GROUP BY customer_state, root_cause
),
shares AS (
    SELECT *, late_orders * 1.0 / SUM(late_orders) OVER (PARTITION BY customer_state) AS share_of_state_late,
           SUM(late_orders) OVER (PARTITION BY customer_state) AS state_late
    FROM counts
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_state
                                 ORDER BY late_orders DESC, root_cause) AS cause_rank
    FROM shares
)
SELECT *, MAX(CASE WHEN cause_rank = 1 THEN root_cause END)
              OVER (PARTITION BY customer_state) AS dominant_cause
FROM ranked
ORDER BY state_late DESC, cause_rank;

-- Same attribution by month: do the causes change during the national waves?
CREATE OR REPLACE TABLE rpt_root_cause_by_month AS
SELECT purchase_month, root_cause, COUNT(*) AS late_orders,
       COUNT(*) * 1.0 / SUM(COUNT(*)) OVER (PARTITION BY purchase_month) AS share_of_month_late
FROM stg_late_attributed
WHERE purchase_month BETWEEN DATE '2017-01-01' AND DATE '2018-08-01'
GROUP BY purchase_month, root_cause
ORDER BY purchase_month, late_orders DESC;

-- A separate, simpler view that does not depend on the counterfactual: how do stages and the
-- promise differ between late and on-time orders?
CREATE OR REPLACE TABLE rpt_stage_late_vs_ontime AS
SELECT CASE WHEN is_late THEN 'late' ELSE 'on time' END AS outcome,
       COUNT(*)                     AS orders,
       AVG(approval_lag_days)       AS mean_approval_days,
       AVG(seller_handoff_days)     AS mean_handoff_days,
       MEDIAN(seller_handoff_days)  AS p50_handoff_days,
       QUANTILE_CONT(seller_handoff_days, 0.9) AS p90_handoff_days,
       AVG(carrier_transit_days)    AS mean_transit_days,
       MEDIAN(carrier_transit_days) AS p50_transit_days,
       QUANTILE_CONT(carrier_transit_days, 0.9) AS p90_transit_days,
       AVG(promised_days)           AS mean_promised_days,
       MEDIAN(promised_days)        AS p50_promised_days,
       AVG(CASE WHEN is_seller_dispatch_late THEN 1.0 ELSE 0 END) AS seller_dispatch_late_rate
FROM fct_orders
WHERE is_delivered
GROUP BY 1
ORDER BY 1;

-- Is the estimate itself too aggressive? Compare the promise with what was actually delivered.
CREATE OR REPLACE TABLE rpt_estimate_quality AS
WITH state_actuals AS (
    SELECT customer_state,
           COUNT(*)              AS delivered,
           AVG(promised_days)    AS mean_promised_days,
           AVG(total_days)       AS mean_actual_days,
           MEDIAN(total_days)    AS p50_actual_days,
           QUANTILE_CONT(total_days, 0.9) AS p90_actual_days,
           AVG(promised_days - total_days) AS mean_buffer_days,
           AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) AS breach_rate,
           AVG(CASE WHEN days_vs_promise <= -14 THEN 1.0 ELSE 0 END) AS share_14plus_days_early
    FROM fct_orders
    WHERE is_delivered
    GROUP BY customer_state
)
SELECT *, mean_promised_days - p90_actual_days AS promise_minus_p90
FROM state_actuals
ORDER BY breach_rate DESC;

CREATE OR REPLACE TABLE rpt_estimate_overall AS
SELECT AVG(promised_days - total_days)                     AS mean_buffer_days,
       MEDIAN(days_vs_promise)                             AS p50_days_vs_promise,
       AVG(CASE WHEN days_vs_promise <= -7  THEN 1.0 ELSE 0 END) AS share_7plus_days_early,
       AVG(CASE WHEN days_vs_promise <= -14 THEN 1.0 ELSE 0 END) AS share_14plus_days_early,
       CORR(promised_days, total_days)                     AS corr_promised_actual,
       CORR(distance_km, promised_days)                    AS corr_distance_promised,
       CORR(distance_km, total_days)                       AS corr_distance_actual
FROM fct_orders
WHERE is_delivered;

-- What if the promise changed? Move every estimate by k days and recount late orders.
CREATE OR REPLACE TABLE rpt_estimate_shift AS
WITH shifts AS (
    SELECT * FROM (VALUES (-7), (-3), (-1), (0), (1), (3), (7), (14)) AS t(shift_days)
)
SELECT shift_days,
       AVG(CASE WHEN days_vs_promise > shift_days THEN 1.0 ELSE 0 END) AS breach_rate,
       AVG(promised_days + shift_days)                                 AS mean_promised_days
FROM fct_orders CROSS JOIN shifts
WHERE is_delivered
GROUP BY shift_days
ORDER BY shift_days;

-- Check for a state whose breach is promise-driven: RJ and RS deliver at a similar average speed.
-- rpt_same_speed_states puts two states side by side with their cause mix.
CREATE OR REPLACE TABLE rpt_same_speed_states AS
SELECT s.customer_state, s.delivered, s.breach_rate, s.mean_delivery_days, s.p50_delivery_days,
       s.p90_delivery_days, s.mean_promised_days,
       e.promise_minus_p90,
       COUNT(*) FILTER (l.root_cause = 'carrier') * 1.0 / COUNT(*) AS carrier_share,
       COUNT(*) FILTER (l.root_cause = 'promise') * 1.0 / COUNT(*) AS promise_share,
       COUNT(*) FILTER (l.root_cause = 'seller')  * 1.0 / COUNT(*) AS seller_share
FROM rpt_kpi_state s
JOIN rpt_estimate_quality e USING (customer_state)
JOIN stg_late_attributed l USING (customer_state)
WHERE s.customer_state IN ('RJ', 'RS', 'SC', 'ES', 'GO')
GROUP BY ALL
ORDER BY s.breach_rate DESC;
