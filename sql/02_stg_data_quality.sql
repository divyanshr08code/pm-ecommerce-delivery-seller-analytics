-- 02_stg_data_quality.sql
-- Question : What is wrong with the raw data, and how is each issue treated?
-- Grain    : each stg_* view states its own grain below.
--            rpt_dq_checks = one row per check.
-- Metrics  : affected_rows = rows matching the issue; treatment says what happens to them.
-- Rule     : orders are never deleted from the fact table. An issue either NULLs one
--            duration or removes the order from one metric's denominator, and that is logged.

-- ---------- Reusable helper ----------
-- Wilson score interval for a proportion (z = 1.96 gives about 95%). Used everywhere a rate is
-- compared across small groups, because the simple +/- formula misbehaves at low volume.
CREATE OR REPLACE MACRO wilson_low(k, n) AS
    CASE WHEN n = 0 THEN NULL ELSE
    ((k * 1.0 / n) + 1.96 * 1.96 / (2 * n)
       - 1.96 * sqrt((k * 1.0 / n) * (1 - k * 1.0 / n) / n + 1.96 * 1.96 / (4 * n * n)))
    / (1 + 1.96 * 1.96 / n) END;
CREATE OR REPLACE MACRO wilson_high(k, n) AS
    CASE WHEN n = 0 THEN NULL ELSE
    ((k * 1.0 / n) + 1.96 * 1.96 / (2 * n)
       + 1.96 * sqrt((k * 1.0 / n) * (1 - k * 1.0 / n) / n + 1.96 * 1.96 / (4 * n * n)))
    / (1 + 1.96 * 1.96 / n) END;

-- ---------- Staging views ----------
-- Grain: one row per order.
CREATE OR REPLACE VIEW stg_orders AS
SELECT * FROM raw_orders;

-- Grain: one row per customer_id. customer_id is per ORDER; customer_unique_id is the person.
CREATE OR REPLACE VIEW stg_customers AS
SELECT customer_id, customer_unique_id, customer_zip_code_prefix, customer_state
FROM raw_customers;

-- Grain: one row per order. Several reviews can exist for one order, and joining them directly
-- would duplicate the order. Keep the most recently answered review, as the customer's final
-- view. review_id breaks ties so the choice is the same on every run.
CREATE OR REPLACE VIEW stg_reviews AS
WITH ranked AS (
    SELECT order_id, review_score, review_creation_date, review_answer_timestamp,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_timestamp DESC, review_id) AS rn
    FROM raw_reviews
)
SELECT order_id, review_score, review_creation_date, review_answer_timestamp
FROM ranked
WHERE rn = 1;

-- Grain: one row per order and seller. This is the right grain for seller scorecards: a
-- two-seller order counts once per seller, not once per item.
CREATE OR REPLACE VIEW stg_seller_orders AS
SELECT order_id, seller_id,
       COUNT(*)                 AS items,
       SUM(price)               AS item_value,
       SUM(freight_value)       AS freight_value,
       MAX(shipping_limit_date) AS shipping_limit_ts
FROM raw_items
GROUP BY order_id, seller_id;

-- Grain: one row per product. LEFT JOIN keeps products with no translation or no category.
CREATE OR REPLACE VIEW stg_products AS
SELECT p.product_id,
       COALESCE(t.product_category_name_english, p.product_category_name, 'unknown') AS category
FROM raw_products p
LEFT JOIN raw_translation t USING (product_category_name);

-- Grain: one row per order. Collapses items so that joining to orders cannot fan out.
-- The "primary" seller and category come from the highest-value line of the order.
CREATE OR REPLACE VIEW stg_order_items AS
WITH totals AS (
    SELECT order_id,
           COUNT(*)                  AS item_count,
           COUNT(DISTINCT seller_id) AS seller_count,
           SUM(price)                AS item_value,
           SUM(freight_value)        AS freight_value,
           -- Lenient by design: a multi-seller order has one pickup timestamp, so judge it against
           -- the latest seller deadline.
           MAX(shipping_limit_date)  AS shipping_limit_ts
    FROM raw_items
    GROUP BY order_id
),
ranked_lines AS (
    SELECT i.order_id, i.seller_id, p.category,
           ROW_NUMBER() OVER (PARTITION BY i.order_id
                              ORDER BY i.price DESC, i.order_item_id) AS rn
    FROM raw_items i
    LEFT JOIN stg_products p USING (product_id)
)
SELECT t.*, r.seller_id AS primary_seller_id, r.category AS primary_category
FROM totals t
JOIN ranked_lines r ON r.order_id = t.order_id AND r.rn = 1;

-- Grain: one row per order.
CREATE OR REPLACE VIEW stg_payments AS
SELECT order_id, SUM(payment_value) AS payment_value
FROM raw_payments
GROUP BY order_id;

-- Grain: one row per zip prefix. The raw table has many points per prefix. The median resists
-- stray points, and the bounding box drops coordinates outside Brazil.
CREATE OR REPLACE VIEW stg_geolocation AS
SELECT geolocation_zip_code_prefix AS zip_prefix,
       MEDIAN(geolocation_lat) AS lat,
       MEDIAN(geolocation_lng) AS lng
FROM raw_geolocation
WHERE geolocation_lat BETWEEN -34 AND 6
  AND geolocation_lng BETWEEN -74 AND -34
GROUP BY geolocation_zip_code_prefix;

-- ---------- Data-quality report ----------
CREATE OR REPLACE TABLE rpt_dq_checks AS
WITH o AS (SELECT * FROM raw_orders)
          SELECT 'duplicate order_id rows' AS check_name,
                 (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM o) AS affected_rows,
                 'None found means no action; fct_orders asserts uniqueness' AS treatment
UNION ALL SELECT 'orders with no item rows (anti join)',
                 (SELECT COUNT(*) FROM o LEFT JOIN (SELECT DISTINCT order_id FROM raw_items) i
                    USING (order_id) WHERE i.order_id IS NULL),
                 'Kept in order counts; seller and category are NULL'
UNION ALL SELECT 'orders with no review (anti join)',
                 (SELECT COUNT(*) FROM o LEFT JOIN (SELECT DISTINCT order_id FROM raw_reviews) r
                    USING (order_id) WHERE r.order_id IS NULL),
                 'Kept; review_score NULL, so they cannot trigger the low-review defect'
UNION ALL SELECT 'orders with no payment row (anti join)',
                 (SELECT COUNT(*) FROM o LEFT JOIN (SELECT DISTINCT order_id FROM raw_payments) p
                    USING (order_id) WHERE p.order_id IS NULL),
                 'Kept; payment_value NULL'
UNION ALL SELECT 'extra review rows beyond one per order',
                 (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM raw_reviews),
                 'Latest answered review kept per order'
UNION ALL SELECT 'review_id values shared by more than one row',
                 (SELECT COUNT(*) - COUNT(DISTINCT review_id) FROM raw_reviews),
                 'review_id is not a key; never used as a join key'
UNION ALL SELECT 'orders with more than one item line',
                 (SELECT COUNT(*) FROM (SELECT order_id FROM raw_items GROUP BY 1 HAVING COUNT(*) > 1)),
                 'Collapsed to one row per order in stg_order_items'
UNION ALL SELECT 'orders with more than one seller',
                 (SELECT COUNT(*) FROM (SELECT order_id FROM raw_items GROUP BY 1 HAVING COUNT(DISTINCT seller_id) > 1)),
                 'Primary seller = highest-value line; seller scorecard counts the order for each seller'
UNION ALL SELECT 'status delivered but delivered date missing',
                 (SELECT COUNT(*) FROM o WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL),
                 'Excluded from delivered population: lateness cannot be measured'
UNION ALL SELECT 'status canceled but delivered date present',
                 (SELECT COUNT(*) FROM o WHERE order_status = 'canceled' AND order_delivered_customer_date IS NOT NULL),
                 'Treated as canceled; excluded from delivered population'
UNION ALL SELECT 'status delivered, approval timestamp missing',
                 (SELECT COUNT(*) FROM o WHERE order_status = 'delivered' AND order_approved_at IS NULL),
                 'Kept for breach metrics; approval lag and seller handoff NULL'
UNION ALL SELECT 'status delivered, carrier date missing',
                 (SELECT COUNT(*) FROM o WHERE order_status = 'delivered' AND order_delivered_carrier_date IS NULL),
                 'Kept for breach metrics; handoff and transit NULL; unattributable in root cause'
UNION ALL SELECT 'delivered before purchase',
                 (SELECT COUNT(*) FROM o WHERE order_delivered_customer_date < order_purchase_timestamp),
                 'None found means no action; assertion in 03'
UNION ALL SELECT 'approved before purchase',
                 (SELECT COUNT(*) FROM o WHERE order_approved_at < order_purchase_timestamp),
                 'None found means no action'
UNION ALL SELECT 'carrier pickup before approval (negative handoff)',
                 (SELECT COUNT(*) FROM o WHERE order_delivered_carrier_date < order_approved_at),
                 'Kept for breach metrics; seller handoff duration NULL'
UNION ALL SELECT 'carrier pickup before purchase',
                 (SELECT COUNT(*) FROM o WHERE order_delivered_carrier_date < order_purchase_timestamp),
                 'Subset of negative handoff; same treatment'
UNION ALL SELECT 'delivered to customer before carrier pickup (negative transit)',
                 (SELECT COUNT(*) FROM o WHERE order_delivered_customer_date < order_delivered_carrier_date),
                 'Kept for breach metrics; transit NULL; unattributable in root cause'
UNION ALL SELECT 'estimated date with a non-midnight time',
                 (SELECT COUNT(*) FROM o WHERE CAST(order_estimated_delivery_date AS TIME) <> TIME '00:00:00'),
                 'Zero rows: estimates are date-only, hence date-level lateness (see METRICS.md)'
UNION ALL SELECT 'products with no category',
                 (SELECT COUNT(*) FROM raw_products WHERE product_category_name IS NULL),
                 'Labelled unknown'
UNION ALL SELECT 'geolocation rows outside Brazil bounding box',
                 (SELECT COUNT(*) FROM raw_geolocation
                   WHERE NOT (geolocation_lat BETWEEN -34 AND 6 AND geolocation_lng BETWEEN -74 AND -34)),
                 'Dropped before taking the median per prefix'
UNION ALL SELECT 'geolocation rows beyond one per zip prefix',
                 (SELECT COUNT(*) - COUNT(DISTINCT geolocation_zip_code_prefix) FROM raw_geolocation),
                 'Collapsed to one median point per prefix';

-- Set operation as a second check on the anti join above: both must find the same orders.
CREATE OR REPLACE TABLE rpt_orders_without_items_check AS
SELECT
  (SELECT COUNT(*) FROM (SELECT order_id FROM raw_orders EXCEPT SELECT order_id FROM raw_items)) AS by_except,
  (SELECT affected_rows FROM rpt_dq_checks WHERE check_name LIKE 'orders with no item%')         AS by_anti_join;

-- Population waterfall: from all orders to the group whose lateness can be measured.
CREATE OR REPLACE TABLE rpt_population_waterfall AS
          SELECT 1 AS step, 'All orders' AS population, COUNT(*) AS orders FROM raw_orders
UNION ALL SELECT 2, 'Status delivered', COUNT(*) FROM raw_orders WHERE order_status = 'delivered'
UNION ALL SELECT 3, 'Status delivered with delivered date (the breach denominator)', COUNT(*)
          FROM raw_orders WHERE order_status = 'delivered' AND order_delivered_customer_date IS NOT NULL
ORDER BY step;
