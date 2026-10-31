-- 11_dashboard_exports.sql
-- Question : What flat tables does the dashboard need?
-- Grain    : dash_fact = one row per purchase month x customer state x primary category.
--            dash_seller_scorecard = one row per scored seller.
-- Metrics  : additive counts and sums only. A BI tool can filter and re-aggregate these correctly
--            (SUM(late) / SUM(delivered)). Percentiles do not add up, so P50 and P90 are given
--            only in the rpt_* tables, unfiltered. No order or customer ids are exported.

CREATE OR REPLACE TABLE dash_fact AS
WITH state_names AS (
    -- Full names let Tableau place states on a map without guessing at two-letter codes.
    SELECT * FROM (VALUES
        ('AC','Acre'),('AL','Alagoas'),('AM','Amazonas'),('AP','Amapa'),('BA','Bahia'),('CE','Ceara'),
        ('DF','Distrito Federal'),('ES','Espirito Santo'),('GO','Goias'),('MA','Maranhao'),
        ('MG','Minas Gerais'),('MS','Mato Grosso do Sul'),('MT','Mato Grosso'),('PA','Para'),
        ('PB','Paraiba'),('PE','Pernambuco'),('PI','Piaui'),('PR','Parana'),('RJ','Rio de Janeiro'),
        ('RN','Rio Grande do Norte'),('RO','Rondonia'),('RR','Roraima'),('RS','Rio Grande do Sul'),
        ('SC','Santa Catarina'),('SE','Sergipe'),('SP','Sao Paulo'),('TO','Tocantins')
    ) AS t(customer_state, state_name)
)
SELECT f.purchase_month, f.customer_state, n.state_name,
       COALESCE(f.primary_category, 'no items') AS category,
       COUNT(*)                                          AS orders,
       COUNT(*) FILTER (f.is_delivered)                  AS delivered,
       COUNT(*) FILTER (f.is_delivered AND f.is_late)    AS late,
       COUNT(*) FILTER (f.is_defect_proxy)               AS defects,
       COUNT(*) FILTER (f.is_canceled_unavailable)       AS canceled_unavailable,
       SUM(f.total_days) FILTER (f.is_delivered)         AS sum_delivery_days,
       SUM(f.promised_days) FILTER (f.is_delivered)      AS sum_promised_days,
       SUM(f.days_late) FILTER (f.is_delivered AND f.is_late) AS sum_days_late,
       COUNT(*) FILTER (a.root_cause = 'carrier')        AS late_carrier,
       COUNT(*) FILTER (a.root_cause = 'seller')         AS late_seller,
       COUNT(*) FILTER (a.root_cause = 'promise')        AS late_promise,
       COUNT(*) FILTER (a.root_cause IN ('either', 'compound')) AS late_multiple,
       COUNT(*) FILTER (a.root_cause = 'unattributable') AS late_unattributable
FROM fct_orders f
LEFT JOIN stg_late_attributed a USING (order_id)
LEFT JOIN state_names n ON n.customer_state = f.customer_state
WHERE f.purchase_month BETWEEN DATE '2017-01-01' AND DATE '2018-08-01'
GROUP BY ALL
ORDER BY 1, 2, 4;

CREATE OR REPLACE TABLE dash_seller_scorecard AS
SELECT substr(seller_id, 1, 8) AS seller_short_id, seller_state, delivered, late, breach_rate,
       breach_ci_low, breach_ci_high, avg_days_late, dispatch_miss_rate, defect_rate,
       excess_late_orders, worst_rank, volume_quartile
FROM rpt_seller_scorecard
ORDER BY worst_rank;

-- The extract must add back to the fact table within its window.
SELECT CASE WHEN (SELECT SUM(late) FROM dash_fact)
              <> (SELECT SUM(late) FROM rpt_kpi_monthly)
            THEN error('dash_fact late orders do not reconcile with rpt_kpi_monthly') END;
