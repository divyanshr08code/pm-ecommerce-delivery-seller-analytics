-- 08_customer_impact.sql
-- Question : How much does lateness hurt customers, measured by review score?
-- Grain    : rpt_review_by_lateness = one row per lateness bucket. rpt_low_review_split = one row.
-- Metrics  : mean review and low-review rate (score <= 2) among delivered orders with a review.
-- Caution  : this is ASSOCIATION, not causation. Late orders may differ in other ways (distance,
--            category, seller quality), and reviews come from customers who chose to leave one.

CREATE OR REPLACE TABLE rpt_review_by_lateness AS
SELECT SUBSTR(lateness_bucket, 3)                AS bucket,
       lateness_bucket                           AS bucket_sort,
       COUNT(*)                                  AS reviewed_orders,
       AVG(review_score)                         AS mean_review,
       COUNT(*) FILTER (is_low_review)           AS low_reviews,
       COUNT(*) FILTER (is_low_review) * 1.0 / COUNT(*) AS low_review_rate,
       wilson_low(COUNT(*) FILTER (is_low_review), COUNT(*))  AS low_review_ci_low,
       wilson_high(COUNT(*) FILTER (is_low_review), COUNT(*)) AS low_review_ci_high
FROM fct_orders
WHERE is_delivered AND review_score IS NOT NULL
GROUP BY lateness_bucket
ORDER BY lateness_bucket;

CREATE OR REPLACE TABLE rpt_low_review_split AS
SELECT COUNT(*) FILTER (is_low_review)                        AS low_reviews_delivered,
       COUNT(*) FILTER (is_low_review AND is_late)            AS low_reviews_late,
       COUNT(*) FILTER (is_low_review AND NOT is_late)        AS low_reviews_on_time,
       COUNT(*) FILTER (is_low_review AND is_late) * 1.0
           / COUNT(*) FILTER (is_low_review)                  AS share_low_reviews_late,
       COUNT(*) FILTER (is_low_review AND NOT is_late) * 1.0
           / COUNT(*) FILTER (is_low_review)                  AS share_low_reviews_on_time,
       COUNT(*) FILTER (is_late) * 1.0 / COUNT(*)             AS share_reviewed_orders_late,
       COUNT(*) FILTER (is_low_review AND is_late) * 1.0 / COUNT(*) FILTER (is_late)     AS low_rate_late,
       COUNT(*) FILTER (is_low_review AND NOT is_late) * 1.0 / COUNT(*) FILTER (NOT is_late) AS low_rate_on_time,
       -- Relative risk: how many times more often late orders get a low review.
       (COUNT(*) FILTER (is_low_review AND is_late) * 1.0 / COUNT(*) FILTER (is_late))
         / (COUNT(*) FILTER (is_low_review AND NOT is_late) * 1.0 / COUNT(*) FILTER (NOT is_late)) AS relative_risk
FROM fct_orders
WHERE is_delivered AND review_score IS NOT NULL;

-- What else goes with low reviews on ON-TIME orders? Multi-item and multi-seller orders are a
-- candidate: part of the order can arrive separately or be missing.
CREATE OR REPLACE TABLE rpt_on_time_low_review_drivers AS
SELECT CASE WHEN seller_count > 1 THEN '3 multi-seller'
            WHEN item_count > 1 THEN '2 multi-item, one seller'
            ELSE '1 single item' END AS order_shape,
       COUNT(*)                                  AS reviewed_on_time_orders,
       AVG(review_score)                         AS mean_review,
       COUNT(*) FILTER (is_low_review) * 1.0 / COUNT(*) AS low_review_rate,
       COUNT(*) * 1.0 / SUM(COUNT(*)) OVER ()    AS share_of_on_time_reviewed,
       COUNT(*) FILTER (is_low_review) * 1.0 / SUM(COUNT(*) FILTER (is_low_review)) OVER () AS share_of_on_time_low
FROM fct_orders
WHERE is_delivered AND NOT is_late AND review_score IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- Does the review penalty for lateness survive within a state? A crude control for geography:
-- compare late and on-time inside each state, then average weighted by the state's late orders.
CREATE OR REPLACE TABLE rpt_lateness_penalty_within_state AS
WITH by_state AS (
    SELECT customer_state,
           COUNT(*) FILTER (is_late) AS late_n,
           AVG(review_score) FILTER (is_late)     AS late_review,
           AVG(review_score) FILTER (NOT is_late) AS on_time_review
    FROM fct_orders
    WHERE is_delivered AND review_score IS NOT NULL
    GROUP BY customer_state
    HAVING COUNT(*) FILTER (is_late) >= 30
)
SELECT COUNT(*) AS states_compared,
       SUM((on_time_review - late_review) * late_n) / SUM(late_n) AS weighted_review_gap,
       COUNT(*) FILTER (late_review < on_time_review) AS states_where_late_scores_lower
FROM by_state;
