# Dashboard build guide

**Status: not built.** Tableau is not installed on the build machine and publishing needs your own account. All the data is
ready. The steps below are the manual part. The formulas here were not tested in Tableau, so check them against the tile values below.

## What is already generated

| File | Use |
|---|---|
| `outputs/tables/dash_fact.csv` | Main source: month x state x category, additive counts |
| `outputs/tables/dash_seller_scorecard.csv` | Seller table |
| `outputs/tables/rpt_*.csv` | Every other metric table, for Google Sheets or Looker Studio |
| `outputs/charts/*.png` | Static versions of the main charts |

`dash_fact` covers Jan 2017 to Aug 2018 and has no order or customer ids. It has 11,807 rows.

## What you must do yourself

1. Install Tableau Public (free) and create an account.
2. Build the sheets below.
3. Publish, take screenshots to `dashboard/`, and add the link to the README.

## Step by step

### 1. Connect

Open Tableau Public, then Text file, and pick `dash_fact.csv`. Then Data > New Data Source and pick `dash_seller_scorecard.csv`. Do not
join them: they have different grains. Check `purchase_month` is a Date. Set `state_name` to Geographic Role > State/Province. If the map
shows unknown locations, use Map > Edit Locations and set the country to Brazil.

### 2. Calculated fields (on `dash_fact`)

```text
Promise Accuracy   = 1 - SUM([late]) / SUM([delivered])
Breach Rate        = SUM([late]) / SUM([delivered])
Avg Delivery Days  = SUM([sum_delivery_days]) / SUM([delivered])
Avg Promised Days  = SUM([sum_promised_days]) / SUM([delivered])
Avg Days Late      = SUM([sum_days_late]) / SUM([late])
Defect Proxy       = SUM([defects]) / SUM([orders])
Cancellation Rate  = SUM([canceled_unavailable]) / SUM([orders])
Carrier Share      = SUM([late_carrier]) / SUM([late])
Seller Share       = SUM([late_seller]) / SUM([late])
Promise Share      = SUM([late_promise]) / SUM([late])
Multiple Share     = SUM([late_multiple]) / SUM([late])
```

Always divide two SUMs. Never average a pre-computed rate: that would give a small state the same weight as SP.

Rolling 3-month breach rate, computed along `purchase_month`:

```text
Rolling Breach 3M = WINDOW_SUM(SUM([late]), -2, 0) / WINDOW_SUM(SUM([delivered]), -2, 0)
```

### 3. Sheets

| Sheet | Build |
|---|---|
| KPI tiles | One text sheet each: SUM(orders), Promise Accuracy, Avg Delivery Days, Defect Proxy |
| Monthly trend | `purchase_month` (continuous month) on Columns; Breach Rate and Rolling Breach 3M on Rows, shared axis (dual lines, one scale) |
| State heatmap | `state_name` on Detail of a filled map, Breach Rate as colour, one-hue sequential. Tooltip: delivered, late. Small states are noisy, so show `delivered` |
| Stage contribution | `customer_state` on Rows; Measure Names on Colour with the four shares; stacked bars. Sort by SUM(late); show the top 10 |
| Seller scorecard | From `dash_seller_scorecard`: table of id, state, delivered, breach rate, Wilson low, dispatch miss, avg days late, defect rate, excess late. Sort by `worst_rank` |

### 4. Dashboard

1. New Dashboard, fixed 1200 x 900. Place tiles along the top, trend and map in the middle, stage chart and seller table below.
2. Add filters for `purchase_month`, `customer_state` and `category`. Use "Apply to Worksheets > All Using This Data Source".
3. The seller table has a separate source, so these filters do not apply to it. Add its own `seller_state` filter, and say so in a caption.
4. Add a caption: "Late = delivered date after promised date. Defect = proxy. Carrier = pickup-to-customer stage. Causes are a counterfactual attribution."

### 5. Check your tiles against these values

With no filters on, tiles must show:

| Tile | Value |
|---|---|
| Orders | 99,092 |
| Promise accuracy | 93.2% |
| Avg delivery days | 12.5 |
| Defect proxy | 14.8% |

These are from the dashboard window, so they can differ slightly from the full-data headline (all listed in `docs/RESULTS.md`). If a tile differs, a formula is wrong.

### 6. Publish

File > Save to Tableau Public. Tableau Public makes the workbook and its data public. The extract holds only aggregated counts, and the seller
table has shortened anonymised ids. Keep the licence credit in the caption: "Data: Brazilian E-Commerce Public Dataset by Olist, CC BY-NC-SA 4.0."

## Google Sheets or Looker Studio

Import the same CSVs. In Looker Studio create the same ratios as calculated fields, for example `SUM(late) / SUM(delivered)`. In Sheets use a pivot
table on `dash_fact`, with a calculated field `= late / delivered`.

## Reading the dashboard

- Start at the trend, and see whether a change is a national wave or local.
- Use the map for where, and the stage chart for why. Check `delivered` before reacting to a small state.
- The seller table is for action lists. Rank by Wilson low for reliable underperformers, and by excess late for the sellers with the largest effect.
