-- 05_anomalies.sql
-- Question : Which state-months had a breach rate abnormally high against that state's own recent
--            history, and what was different in those months?
-- Grain    : rpt_anomalies = one row per flagged state-month.
--            rpt_anomaly_months = one row per calendar month with at least one flag.
-- Metrics  : z = (rate - trailing mean) / trailing stddev. The baseline is the previous 6 months,
--            excluding the current month, so a spike cannot inflate its own baseline.
-- Filters  : current month needs >= 30 delivered orders; the baseline needs >= 4 prior months
--            that also had >= 30 orders. Below that a rate is mostly noise.
--            stddev below 0.01 is floored at 0.01 so that a calm state cannot produce an
--            enormous z from a very small rise.

CREATE OR REPLACE TABLE stg_state_month_baseline AS
WITH eligible AS (
    SELECT * FROM rpt_state_month WHERE delivered >= 30
)
SELECT *,
       AVG(breach_rate)        OVER w AS baseline_mean,
       STDDEV_SAMP(breach_rate) OVER w AS baseline_std,
       COUNT(*)                OVER w AS baseline_months,
       AVG(delivered)          OVER w AS baseline_volume
FROM eligible
WINDOW w AS (PARTITION BY customer_state ORDER BY purchase_month
             ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING);

CREATE OR REPLACE TABLE rpt_anomalies AS
WITH scored AS (
    SELECT *,
           (breach_rate - baseline_mean) / GREATEST(baseline_std, 0.01) AS z_score
    FROM stg_state_month_baseline
    WHERE baseline_months >= 4
),
flagged AS (
    SELECT * FROM scored WHERE z_score > 2
),
-- Context for each flagged state-month. Everything below is computed at state-month level from
-- fct_orders, then compared with that state's six prior months.
state_month_detail AS (
    SELECT customer_state, purchase_month,
           AVG(promised_days) FILTER (is_delivered)         AS promised_days,
           AVG(seller_handoff_days) FILTER (is_delivered)   AS handoff_days,
           AVG(carrier_transit_days) FILTER (is_delivered)  AS transit_days
    FROM fct_orders
    GROUP BY customer_state, purchase_month
),
detail_with_baseline AS (
    SELECT *,
           AVG(promised_days) OVER w AS base_promised,
           AVG(handoff_days)  OVER w AS base_handoff,
           AVG(transit_days)  OVER w AS base_transit
    FROM state_month_detail
    WINDOW w AS (PARTITION BY customer_state ORDER BY purchase_month
                 ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING)
),
-- How concentrated were this state-month's late orders in one seller?
seller_late AS (
    SELECT customer_state, purchase_month, primary_seller_id, COUNT(*) AS late_orders,
           ROW_NUMBER() OVER (PARTITION BY customer_state, purchase_month
                              ORDER BY COUNT(*) DESC, primary_seller_id) AS rn,
           SUM(COUNT(*)) OVER (PARTITION BY customer_state, purchase_month) AS total_late
    FROM fct_orders
    WHERE is_delivered AND is_late
    GROUP BY customer_state, purchase_month, primary_seller_id
)
SELECT f.customer_state, f.purchase_month, f.delivered, f.late,
       f.breach_rate, f.baseline_mean, f.baseline_std, f.baseline_months, f.z_score,
       f.delivered * 1.0 / f.baseline_volume AS volume_vs_baseline,
       m.breach_rate                         AS national_breach_rate,
       d.promised_days - d.base_promised     AS promised_days_change,
       d.handoff_days  - d.base_handoff      AS handoff_days_change,
       d.transit_days  - d.base_transit      AS transit_days_change,
       s.late_orders * 1.0 / s.total_late    AS top_seller_share_of_late,
       -- Label the most likely driver, in a fixed order. It is a description of what moved in
       -- that month, not proof of cause.
       CASE WHEN s.late_orders * 1.0 / s.total_late >= 0.3      THEN 'single seller concentration'
            WHEN m.breach_rate >= 0.12                          THEN 'national wave'
            WHEN f.delivered * 1.0 / f.baseline_volume >= 1.5   THEN 'local volume spike'
            WHEN d.transit_days - d.base_transit >= 2           THEN 'local carrier slowdown'
            ELSE 'unexplained / small sample' END AS driver_label
FROM flagged f
JOIN rpt_kpi_monthly m USING (purchase_month)
JOIN detail_with_baseline d USING (customer_state, purchase_month)
JOIN seller_late s ON s.customer_state = f.customer_state
                  AND s.purchase_month = f.purchase_month AND s.rn = 1
ORDER BY f.purchase_month, f.z_score DESC;

CREATE OR REPLACE TABLE rpt_anomaly_months AS
SELECT purchase_month, COUNT(*) AS flagged_states,
       STRING_AGG(customer_state, ', ' ORDER BY z_score DESC) AS states,
       SUM(late) AS late_orders_in_flagged
FROM rpt_anomalies
GROUP BY purchase_month
ORDER BY purchase_month;

-- Volume spike test: did the biggest volume jumps raise breaches?
CREATE OR REPLACE TABLE rpt_volume_vs_breach AS
SELECT purchase_month, orders, orders_mom_growth, breach_rate, breach_rate_mom_change,
       mean_promised_days, mean_handoff_days, mean_transit_days,
       RANK() OVER (ORDER BY orders_mom_growth DESC NULLS LAST) AS growth_rank
FROM rpt_kpi_monthly
ORDER BY purchase_month;

-- Black Friday 2017 (24 Nov) daily view against the rest of Nov and the 4 weeks before.
CREATE OR REPLACE TABLE rpt_black_friday AS
SELECT CASE WHEN CAST(purchase_ts AS DATE) BETWEEN DATE '2017-11-24' AND DATE '2017-11-27' THEN '1 BF weekend (24-27 Nov)'
            WHEN CAST(purchase_ts AS DATE) BETWEEN DATE '2017-10-27' AND DATE '2017-11-23' THEN '0 four weeks before'
            WHEN CAST(purchase_ts AS DATE) BETWEEN DATE '2017-11-28' AND DATE '2017-12-25' THEN '2 four weeks after'
       END AS period,
       COUNT(*) AS orders,
       COUNT(*) * 1.0 / COUNT(DISTINCT CAST(purchase_ts AS DATE)) AS orders_per_day,
       AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) FILTER (is_delivered) AS breach_rate,
       AVG(promised_days) FILTER (is_delivered) AS mean_promised_days,
       AVG(seller_handoff_days) FILTER (is_delivered) AS mean_handoff_days,
       AVG(carrier_transit_days) FILTER (is_delivered) AS mean_transit_days
FROM fct_orders
WHERE CAST(purchase_ts AS DATE) BETWEEN DATE '2017-10-27' AND DATE '2017-12-25'
GROUP BY 1
ORDER BY 1;

-- How much of all lateness sits in the three national waves? ("wave" = month with national breach
-- rate >= 12%: Nov 2017, Feb 2018, Mar 2018. Chosen from rpt_kpi_monthly, not assumed in advance.)
CREATE OR REPLACE TABLE rpt_wave_summary AS
WITH waves AS (
    SELECT purchase_month FROM rpt_kpi_monthly WHERE breach_rate >= 0.12
)
SELECT COUNT(*) FILTER (w.purchase_month IS NOT NULL)        AS wave_delivered,
       COUNT(*) FILTER (w.purchase_month IS NOT NULL AND is_late) AS wave_late,
       COUNT(*) FILTER (w.purchase_month IS NOT NULL) * 1.0 / COUNT(*)            AS wave_share_of_delivered,
       COUNT(*) FILTER (w.purchase_month IS NOT NULL AND is_late) * 1.0
           / COUNT(*) FILTER (is_late)                       AS wave_share_of_late,
       AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) FILTER (w.purchase_month IS NOT NULL) AS wave_breach_rate,
       AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) FILTER (w.purchase_month IS NULL)     AS non_wave_breach_rate
FROM fct_orders f
LEFT JOIN waves w USING (purchase_month)
WHERE f.is_delivered;

-- Chronic or episodic? A state can have a high rate all the time, or only during waves.
CREATE OR REPLACE TABLE rpt_state_chronic_vs_episodic AS
WITH waves AS (
    SELECT purchase_month FROM rpt_kpi_monthly WHERE breach_rate >= 0.12
),
by_state AS (
    SELECT customer_state,
           COUNT(*) AS delivered,
           COUNT(*) FILTER (is_late) AS late,
           AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) FILTER (w.purchase_month IS NOT NULL) AS wave_breach_rate,
           AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) FILTER (w.purchase_month IS NULL)     AS non_wave_breach_rate,
           COUNT(*) FILTER (is_late AND w.purchase_month IS NOT NULL) * 1.0
               / NULLIF(COUNT(*) FILTER (is_late), 0) AS wave_share_of_late
    FROM fct_orders f
    LEFT JOIN waves w USING (purchase_month)
    WHERE f.is_delivered
    GROUP BY customer_state
    HAVING COUNT(*) >= 300
)
SELECT *, late * 1.0 / delivered AS breach_rate,
       RANK() OVER (ORDER BY late * 1.0 / delivered DESC) AS overall_rank,
       RANK() OVER (ORDER BY non_wave_breach_rate DESC)   AS non_wave_rank
FROM by_state
ORDER BY overall_rank;

-- The biggest problem lane, month by month: does the promise respond to recent lateness?
CREATE OR REPLACE TABLE rpt_lane_sp_rj_monthly AS
SELECT purchase_month, COUNT(*) AS delivered,
       AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) AS breach_rate,
       AVG(promised_days) AS mean_promised_days,
       AVG(total_days)    AS mean_actual_days
FROM fct_orders
WHERE is_delivered AND lane = 'SP>RJ'
  AND purchase_month BETWEEN DATE '2017-01-01' AND DATE '2018-08-01'
GROUP BY purchase_month
ORDER BY purchase_month;
