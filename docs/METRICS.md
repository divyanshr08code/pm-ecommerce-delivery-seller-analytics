# Metric definitions

All durations are in days and computed from timestamps (seconds / 86400). The source column for each
metric is in `sql/03_fct_orders.sql`. Report P50 and P90 beside the mean, because delivery time has
a long right tail: overall, the mean is 12.6 days, the P50 is 10.2 and the P90 is 23.1.

## Populations

| Name | Definition |
|---|---|
| All orders | Every row in the orders file |
| Delivered | `order_status = 'delivered'` and a delivered date exists. This is the denominator for every breach metric |
| Reviewed | Delivered orders with a review |

## Journey stages

| Metric | Definition | NULL when |
|---|---|---|
| Purchase-to-delivery days | delivered timestamp minus purchase timestamp | Not delivered |
| Approval lag | approved minus purchase | Missing or negative |
| Seller handoff time | carrier pickup minus approved | Missing or negative |
| Carrier transit time | delivered minus carrier pickup | Missing or negative |
| Promised days | estimated date minus purchase date | Never |

## Promise metrics

| Metric | Definition |
|---|---|
| Late (SLA breach) | Delivered calendar date is after estimated calendar date |
| SLA-breach rate | Late / delivered |
| Promise accuracy | 1 minus SLA-breach rate |
| Days late | Delivered date minus estimated date, for late orders; otherwise 0 |
| Days versus promise | Same difference, signed. Negative means early |
| Seller dispatch miss | Carrier pickup is after `shipping_limit_date` |
| On-time rate by state | 1 minus breach rate, grouped by customer state |

Why date rather than timestamp: every estimate is stored at exactly midnight. A timestamp test would
call a delivery at 10:00 on the promised day late. The timestamp version is used only as a
robustness test.

## Quality metrics

| Metric | Definition |
|---|---|
| Cancellation rate | Status canceled or unavailable / all orders |
| Low review | Review score of 2 or below |
| Order defect proxy | Canceled or unavailable, OR low review, / all orders |

**The defect proxy is a proxy.** This dataset has no complaint, return or damage log. A low review can
reflect price or expectations rather than a defect, and a real defect may get no review.

## Root-cause classes

Each late order is tested by changing its stages and asking if it would then have arrived on time.
A lane is seller state > customer state. Normal transit is the lane's P75; lanes with fewer than 30
orders use the customer state's P75.

| Class | Rule |
|---|---|
| Promise | Still late with an on-deadline seller AND normal transit |
| Seller | Fixing the seller alone rescues it; fixing the carrier alone does not |
| Carrier | Fixing the carrier alone rescues it; fixing the seller alone does not |
| Either | Either fix alone rescues it |
| Compound | Only fixing both rescues it |
| Unattributable | A needed timestamp is missing or invalid |

Execution means seller + carrier + either + compound. "Carrier" means the pickup-to-customer stage. The data
has no carrier name, so no company can be blamed from it.

## Statistical helpers

| Item | Definition |
|---|---|
| Wilson interval | About 95% interval for a rate; better than the simple formula at small volume |
| Anomaly z-score | (Rate - mean of prior 6 eligible months) / max(stddev of those months, 0.01) |
| Excess late orders | Seller's late orders minus delivered x network breach rate |
| Wave month | Month with national breach rate of 12% or more |
