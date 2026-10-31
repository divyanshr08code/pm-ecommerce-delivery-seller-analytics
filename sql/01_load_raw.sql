-- 01_load_raw.sql
-- Question : Did every raw CSV load completely, and how big is each table?
-- Grain    : raw_* = one row per CSV row (grain differs by table; see docs/LEARN.md section 3).
--            rpt_row_counts = one row per table.
-- Metrics  : row counts only.
-- Why sample_size=-1: DuckDB scans the whole file to infer types instead of guessing
-- from the first rows, so a late odd value cannot silently break a column type.
-- Zip prefixes stay VARCHAR because a leading zero is meaningful in a zip code.

CREATE OR REPLACE TABLE raw_orders       AS SELECT * FROM read_csv('data/raw/olist_orders_dataset.csv', sample_size=-1);
CREATE OR REPLACE TABLE raw_items        AS SELECT * FROM read_csv('data/raw/olist_order_items_dataset.csv', sample_size=-1);
CREATE OR REPLACE TABLE raw_payments     AS SELECT * FROM read_csv('data/raw/olist_order_payments_dataset.csv', sample_size=-1);
CREATE OR REPLACE TABLE raw_reviews      AS SELECT * FROM read_csv('data/raw/olist_order_reviews_dataset.csv', sample_size=-1);
CREATE OR REPLACE TABLE raw_customers    AS SELECT * FROM read_csv('data/raw/olist_customers_dataset.csv', sample_size=-1);
CREATE OR REPLACE TABLE raw_sellers      AS SELECT * FROM read_csv('data/raw/olist_sellers_dataset.csv', sample_size=-1);
CREATE OR REPLACE TABLE raw_products     AS SELECT * FROM read_csv('data/raw/olist_products_dataset.csv', sample_size=-1);
CREATE OR REPLACE TABLE raw_translation  AS SELECT * FROM read_csv('data/raw/product_category_name_translation.csv', sample_size=-1);
CREATE OR REPLACE TABLE raw_geolocation  AS SELECT * FROM read_csv('data/raw/olist_geolocation_dataset.csv', sample_size=-1);

-- UNION ALL (a set operation): stack one count per table into a single report.
CREATE OR REPLACE TABLE rpt_row_counts AS
          SELECT 'orders'      AS table_name, COUNT(*) AS row_count FROM raw_orders
UNION ALL SELECT 'items',       COUNT(*) FROM raw_items
UNION ALL SELECT 'payments',    COUNT(*) FROM raw_payments
UNION ALL SELECT 'reviews',     COUNT(*) FROM raw_reviews
UNION ALL SELECT 'customers',   COUNT(*) FROM raw_customers
UNION ALL SELECT 'sellers',     COUNT(*) FROM raw_sellers
UNION ALL SELECT 'products',    COUNT(*) FROM raw_products
UNION ALL SELECT 'translation', COUNT(*) FROM raw_translation
UNION ALL SELECT 'geolocation', COUNT(*) FROM raw_geolocation;
