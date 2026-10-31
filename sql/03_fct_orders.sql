-- 03_fct_orders.sql
-- Question : What does one complete order look like, with every stage duration and flag?
-- Grain    : fct_orders = exactly one row per order_id (asserted at the end of this file).
-- Metrics  : see docs/METRICS.md. Durations are in days. A negative duration becomes NULL
--            (a bad timestamp order tells us nothing about real speed).

CREATE OR REPLACE TABLE fct_orders AS
WITH joined AS (
    -- Every right-hand side is already one row per order, so LEFT JOINs cannot fan out.
    SELECT o.*,
           c.customer_unique_id, c.customer_state, c.customer_zip_code_prefix,
           i.item_count, i.seller_count, i.item_value, i.freight_value, i.shipping_limit_ts,
           i.primary_seller_id, i.primary_category,
           s.seller_state, s.seller_zip_code_prefix,
           r.review_score, p.payment_value
    FROM stg_orders o
    LEFT JOIN stg_customers   c USING (customer_id)
    LEFT JOIN stg_order_items i USING (order_id)
    LEFT JOIN raw_sellers     s ON s.seller_id = i.primary_seller_id
    LEFT JOIN stg_reviews     r USING (order_id)
    LEFT JOIN stg_payments    p USING (order_id)
),
with_distance AS (
    -- Straight-line (haversine) km between seller and customer zip prefixes. 6371 = Earth's radius.
    SELECT j.*,
           2 * 6371 * asin(sqrt(
               pow(sin(radians(gc.lat - gs.lat) / 2), 2)
             + cos(radians(gs.lat)) * cos(radians(gc.lat))
               * pow(sin(radians(gc.lng - gs.lng) / 2), 2))) AS distance_km
    FROM joined j
    LEFT JOIN stg_geolocation gc ON gc.zip_prefix = j.customer_zip_code_prefix
    LEFT JOIN stg_geolocation gs ON gs.zip_prefix = j.seller_zip_code_prefix
),
durations AS (
    SELECT *,
           date_diff('second', order_purchase_timestamp, order_delivered_customer_date) / 86400.0 AS raw_total,
           date_diff('second', order_purchase_timestamp, order_approved_at) / 86400.0            AS raw_approval,
           date_diff('second', order_approved_at, order_delivered_carrier_date) / 86400.0        AS raw_handoff,
           date_diff('second', order_delivered_carrier_date, order_delivered_customer_date) / 86400.0 AS raw_transit,
           CAST(order_delivered_customer_date AS DATE) AS delivered_date,
           CAST(order_estimated_delivery_date AS DATE) AS estimated_date
    FROM with_distance
)
SELECT
    order_id, customer_id, customer_unique_id, order_status,
    customer_state, seller_state, primary_seller_id, primary_category,
    customer_state = seller_state                        AS is_same_state,
    seller_state || '>' || customer_state                AS lane,
    distance_km,
    item_count, seller_count, item_value, freight_value, payment_value, review_score,
    order_purchase_timestamp  AS purchase_ts,
    order_approved_at         AS approved_ts,
    order_delivered_carrier_date  AS carrier_ts,
    order_delivered_customer_date AS delivered_ts,
    order_estimated_delivery_date AS estimated_ts,
    shipping_limit_ts, delivered_date, estimated_date,
    CAST(date_trunc('month', order_purchase_timestamp) AS DATE) AS purchase_month,

    -- Population flags. NULL-safe on purpose: COALESCE keeps these TRUE/FALSE, never NULL.
    COALESCE(order_status = 'delivered' AND order_delivered_customer_date IS NOT NULL, FALSE) AS is_delivered,
    order_status IN ('canceled', 'unavailable')          AS is_canceled_unavailable,

    -- Stage durations; negative values become NULL.
    raw_total                                            AS total_days,
    CASE WHEN raw_approval >= 0 THEN raw_approval END    AS approval_lag_days,
    CASE WHEN raw_handoff  >= 0 THEN raw_handoff  END    AS seller_handoff_days,
    CASE WHEN raw_transit  >= 0 THEN raw_transit  END    AS carrier_transit_days,
    date_diff('day', CAST(order_purchase_timestamp AS DATE), estimated_date) AS promised_days,

    -- Promise metrics. Primary definition is by date, because every estimate is at midnight.
    -- A timestamp comparison would call a delivery at 10:00 on the promised day late.
    CASE WHEN delivered_date IS NOT NULL THEN delivered_date >  estimated_date END AS is_late,
    CASE WHEN delivered_date IS NOT NULL THEN order_delivered_customer_date > order_estimated_delivery_date END AS is_late_by_timestamp,
    date_diff('day', estimated_date, delivered_date)     AS days_vs_promise,
    CASE WHEN delivered_date > estimated_date
         THEN date_diff('day', estimated_date, delivered_date) ELSE 0 END AS days_late,

    -- Did the seller hand over by the seller's own deadline?
    CASE WHEN order_delivered_carrier_date IS NOT NULL AND shipping_limit_ts IS NOT NULL
         THEN order_delivered_carrier_date > shipping_limit_ts END AS is_seller_dispatch_late,

    -- Defect proxy: an order-level stand-in, not a real defect log.
    review_score <= 2                                    AS is_low_review,
    COALESCE(order_status IN ('canceled', 'unavailable') OR review_score <= 2, FALSE) AS is_defect_proxy,

    -- Lateness bucket used in the customer-impact and dashboard tables.
    CASE WHEN delivered_date IS NULL                 THEN NULL
         WHEN delivered_date <= estimated_date       THEN '0 on time'
         WHEN date_diff('day', estimated_date, delivered_date) <= 3 THEN '1 1-3 days late'
         WHEN date_diff('day', estimated_date, delivered_date) <= 7 THEN '2 4-7 days late'
         ELSE '3 8+ days late' END                       AS lateness_bucket
FROM durations;

-- ---------- Assertions: the build fails loudly if any of these is violated ----------
SELECT CASE WHEN COUNT(*) <> COUNT(DISTINCT order_id)
            THEN error('fct_orders is not one row per order') END FROM fct_orders;
SELECT CASE WHEN (SELECT COUNT(*) FROM fct_orders) <> (SELECT COUNT(*) FROM raw_orders)
            THEN error('fct_orders lost or gained orders compared with raw_orders') END;
SELECT CASE WHEN COUNT(*) > 0 THEN error('an order was delivered before purchase') END
FROM fct_orders WHERE total_days < 0;
SELECT CASE WHEN COUNT(*) > 0 THEN error('a delivered order has a NULL is_late flag') END
FROM fct_orders WHERE is_delivered AND is_late IS NULL;
-- Reconcile money to item-level totals: fan-out would inflate this sum.
SELECT CASE WHEN abs((SELECT SUM(item_value) FROM fct_orders) - (SELECT SUM(price) FROM raw_items)) > 0.01
            THEN error('item value does not reconcile: possible join fan-out') END;
