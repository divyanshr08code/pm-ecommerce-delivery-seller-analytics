-- 07_seller_category_scorecard.sql
-- Question : Which sellers and categories fail most, once small-sample noise is removed?
-- Grain    : stg_seller_order_facts = one row per order x seller.
--            rpt_seller_scorecard = one row per seller with >= 30 delivered orders.
--            rpt_seller_tiers = one row per volume tier. rpt_category_scorecard = one row per category.
-- Metrics  : breach_rate, avg delay (days late when late), defect proxy, dispatch_miss_rate
--            (carrier pickup after this seller's shipping_limit).
-- Filter   : minimum 30 delivered orders. One late order out of 3 is 33% and means nothing.
--            Ranking uses the Wilson lower bound, so a seller only ranks badly when the data
--            is strong enough to rule out a good true rate.
-- An order with two sellers counts for both, because the data cannot say which caused the delay.

CREATE OR REPLACE TABLE stg_seller_order_facts AS
SELECT so.seller_id, so.order_id, so.items, so.item_value, so.shipping_limit_ts,
       f.is_delivered, f.is_late, f.days_late, f.is_defect_proxy, f.seller_handoff_days,
       f.carrier_ts, f.purchase_month, f.customer_state, f.is_same_state, f.lane, f.total_days,
       f.carrier_ts > so.shipping_limit_ts AS missed_dispatch
FROM stg_seller_orders so
JOIN fct_orders f USING (order_id);

CREATE OR REPLACE TABLE rpt_seller_scorecard AS
WITH network AS (
    SELECT AVG(CASE WHEN is_late THEN 1.0 ELSE 0 END) AS network_breach
    FROM stg_seller_order_facts WHERE is_delivered
),
seller AS (
    SELECT seller_id,
           COUNT(*)                                     AS orders,
           COUNT(*) FILTER (is_delivered)               AS delivered,
           COUNT(*) FILTER (is_delivered AND is_late)   AS late,
           AVG(days_late) FILTER (is_delivered AND is_late) AS avg_days_late,
           AVG(seller_handoff_days) FILTER (is_delivered)   AS mean_handoff_days,
           AVG(CASE WHEN missed_dispatch THEN 1.0 ELSE 0 END) FILTER (is_delivered) AS dispatch_miss_rate,
           AVG(CASE WHEN is_defect_proxy THEN 1.0 ELSE 0 END) AS defect_rate,
           SUM(item_value)                              AS item_value
    FROM stg_seller_order_facts
    GROUP BY seller_id
    HAVING COUNT(*) FILTER (is_delivered) >= 30
)
SELECT s.*, r.seller_state,
       late * 1.0 / delivered                AS breach_rate,
       wilson_low(late, delivered)           AS breach_ci_low,
       wilson_high(late, delivered)          AS breach_ci_high,
       -- Late orders beyond what this seller would have had at the network rate.
       late - delivered * n.network_breach   AS excess_late_orders,
       RANK() OVER (ORDER BY wilson_low(late, delivered) DESC) AS worst_rank,
       NTILE(4) OVER (ORDER BY delivered DESC)  AS volume_quartile
FROM seller s
CROSS JOIN network n
JOIN raw_sellers r USING (seller_id)
ORDER BY worst_rank;

-- Volume tiers across ALL sellers, including those below the minimum-volume filter.
CREATE OR REPLACE TABLE rpt_seller_tiers AS
WITH seller AS (
    SELECT seller_id,
           COUNT(*) AS delivered,
           COUNT(*) FILTER (is_late) AS late,
           COUNT(*) FILTER (missed_dispatch) AS missed_dispatch
    FROM stg_seller_order_facts
    WHERE is_delivered
    GROUP BY seller_id
),
tiered AS (
    SELECT *, CASE WHEN delivered >= 500 THEN '1 500+ orders'
                   WHEN delivered >= 100 THEN '2 100-499'
                   WHEN delivered >= 30  THEN '3 30-99'
                   ELSE '4 under 30' END AS tier
    FROM seller
)
SELECT tier, COUNT(*) AS sellers, SUM(delivered) AS delivered, SUM(late) AS late,
       SUM(late) * 1.0 / SUM(delivered) AS breach_rate,
       SUM(missed_dispatch) * 1.0 / SUM(delivered) AS dispatch_miss_rate,
       SUM(delivered) * 1.0 / SUM(SUM(delivered)) OVER () AS share_of_delivered,
       SUM(late) * 1.0 / SUM(SUM(late)) OVER ()           AS share_of_late
FROM tiered
GROUP BY tier
ORDER BY tier;

-- Simpson's paradox check. Overall, big sellers may look better or worse than small ones, but they
-- ship a different mix of same-state and interstate orders. Compare overall and within each mix.
CREATE OR REPLACE TABLE rpt_simpson_tier_lane AS
WITH seller AS (
    SELECT seller_id, COUNT(*) AS seller_delivered
    FROM stg_seller_order_facts WHERE is_delivered GROUP BY seller_id
),
facts AS (
    SELECT f.*, CASE WHEN s.seller_delivered >= 500 THEN 'large (500+)' ELSE 'smaller (<500)' END AS tier,
           CASE WHEN f.is_same_state THEN 'same state' ELSE 'interstate' END AS lane_type
    FROM stg_seller_order_facts f JOIN seller s USING (seller_id)
    WHERE f.is_delivered AND f.is_same_state IS NOT NULL
)
SELECT tier, lane_type, COUNT(*) AS delivered, COUNT(*) FILTER (is_late) AS late,
       COUNT(*) FILTER (is_late) * 1.0 / COUNT(*) AS breach_rate
FROM facts GROUP BY tier, lane_type
UNION ALL
SELECT tier, 'ALL', COUNT(*), COUNT(*) FILTER (is_late), COUNT(*) FILTER (is_late) * 1.0 / COUNT(*)
FROM facts GROUP BY tier
ORDER BY tier, lane_type;

-- Concentration: how much of the excess late volume sits in the worst 10% of scored sellers?
CREATE OR REPLACE TABLE rpt_seller_concentration AS
WITH ordered AS (
    SELECT *, NTILE(10) OVER (ORDER BY excess_late_orders DESC) AS excess_decile
    FROM rpt_seller_scorecard
)
SELECT COUNT(*) AS scored_sellers,
       (SELECT COUNT(DISTINCT seller_id) FROM stg_seller_order_facts WHERE is_delivered) AS all_sellers,
       SUM(delivered) AS scored_delivered,
       SUM(late) AS scored_late,
       COUNT(*) FILTER (excess_decile = 1)                     AS worst_decile_sellers,
       SUM(delivered) FILTER (excess_decile = 1) * 1.0 / SUM(delivered) AS worst_decile_share_of_delivered,
       SUM(late) FILTER (excess_decile = 1) * 1.0 / SUM(late)  AS worst_decile_share_of_late,
       SUM(late) FILTER (excess_decile = 1) * 1.0 / SUM(delivered) FILTER (excess_decile = 1) AS worst_decile_breach_rate,
       SUM(late) FILTER (excess_decile > 1) * 1.0 / SUM(delivered) FILTER (excess_decile > 1) AS other_breach_rate,
       SUM(excess_late_orders) FILTER (excess_decile = 1)      AS worst_decile_excess_late
FROM ordered;

-- Are the sellers who miss dispatch also the ones whose customers get late orders?
CREATE OR REPLACE TABLE rpt_dispatch_vs_breach AS
SELECT CASE WHEN carrier_ts IS NULL THEN 'no pickup date'
            WHEN missed_dispatch THEN 'missed dispatch deadline'
            ELSE 'met dispatch deadline' END AS dispatch_outcome,
       COUNT(*) AS delivered,
       COUNT(*) FILTER (is_late) AS late,
       COUNT(*) FILTER (is_late) * 1.0 / COUNT(*) AS breach_rate
FROM stg_seller_order_facts
WHERE is_delivered
GROUP BY 1
ORDER BY 1;

-- Category grain: distinct order x category, so that 3 identical items count as one order.
CREATE OR REPLACE TABLE rpt_category_scorecard AS
WITH order_cat AS (
    SELECT DISTINCT i.order_id, p.category
    FROM raw_items i
    LEFT JOIN stg_products p USING (product_id)
)
SELECT oc.category,
       COUNT(*)                                             AS orders,
       COUNT(*) FILTER (f.is_delivered)                     AS delivered,
       COUNT(*) FILTER (f.is_delivered AND f.is_late)       AS late,
       COUNT(*) FILTER (f.is_delivered AND f.is_late) * 1.0
           / NULLIF(COUNT(*) FILTER (f.is_delivered), 0)    AS breach_rate,
       AVG(CASE WHEN f.is_defect_proxy THEN 1.0 ELSE 0 END) AS defect_rate,
       wilson_low(COUNT(*) FILTER (f.is_defect_proxy), COUNT(*))  AS defect_ci_low,
       wilson_high(COUNT(*) FILTER (f.is_defect_proxy), COUNT(*)) AS defect_ci_high,
       AVG(f.review_score)                                  AS mean_review,
       AVG(f.total_days) FILTER (f.is_delivered)            AS mean_delivery_days,
       AVG(f.promised_days) FILTER (f.is_delivered)         AS mean_promised_days,
       -- Defects on orders that arrived on time cannot be blamed on delivery timing.
       COUNT(*) FILTER (f.is_defect_proxy AND f.is_delivered AND NOT f.is_late) * 1.0
           / NULLIF(COUNT(*) FILTER (f.is_delivered AND NOT f.is_late), 0) AS defect_rate_when_on_time
FROM order_cat oc
JOIN fct_orders f USING (order_id)
GROUP BY oc.category
HAVING COUNT(*) >= 100
ORDER BY defect_ci_low DESC;

-- A real Simpson's reversal, on mean delivery days, at order grain (primary seller).
-- Overall, Sao Paulo sellers look faster. Inside each lane type they are slower or tied. The overall
-- figure flips because Sao Paulo sellers ship far more same-state orders, and those are quick.
CREATE OR REPLACE TABLE rpt_simpson_sp_sellers AS
WITH facts AS (
    SELECT CASE WHEN seller_state = 'SP' THEN 'SP sellers' ELSE 'other sellers' END AS seller_group,
           CASE WHEN is_same_state THEN 'same state' ELSE 'interstate' END AS lane_type,
           total_days
    FROM fct_orders
    WHERE is_delivered AND is_same_state IS NOT NULL
)
SELECT seller_group, lane_type, COUNT(*) AS delivered, AVG(total_days) AS mean_delivery_days,
       COUNT(*) * 1.0 / SUM(COUNT(*)) OVER (PARTITION BY seller_group) AS share_of_group
FROM facts GROUP BY seller_group, lane_type
UNION ALL
SELECT seller_group, 'ALL', COUNT(*), AVG(total_days), 1.0
FROM facts GROUP BY seller_group
ORDER BY seller_group, lane_type;
