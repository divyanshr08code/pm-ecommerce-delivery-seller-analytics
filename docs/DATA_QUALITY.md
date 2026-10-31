# Data quality log

Source of every count: `rpt_dq_checks` in `sql/02_stg_data_quality.sql`. No order is ever deleted from
`fct_orders`. An issue either NULLs one duration or removes the order from one metric's denominator.

## Population waterfall

| Step | Orders | Removed | Why |
|---|---|---|---|
| All orders | 99,441 | | |
| Status delivered | 96,478 | 2,963 | Other statuses have no final delivery result |
| With a delivered date | 96,470 | 8 | Lateness cannot be measured |

## Issues and treatment

| Issue | Rows | Treatment |
|---|---|---|
| Duplicate order ids | 0 | Uniqueness asserted in `sql/03_fct_orders.sql` |
| Orders with no item rows | 775 | Kept; seller and category NULL. Confirmed by anti join and EXCEPT |
| Orders with no review | 768 | Kept; cannot trigger the low-review defect |
| Orders with no payment row | 1 | Kept; payment value NULL |
| Extra review rows beyond one per order | 551 | Latest answered review kept |
| Review rows sharing a `review_id` | 814 | `review_id` is not a key and is not used in joins |
| Orders with more than one item line | 9,803 | Collapsed to order grain before joining |
| Orders with more than one seller | 1,278 | Primary seller at order grain; counted for each seller on the scorecard |
| Status delivered, delivered date missing | 8 | Excluded from delivered population |
| Status canceled, delivered date present | 6 | Treated as canceled |
| Status delivered, approval missing | 14 | Approval lag and handoff NULL; still in breach metrics |
| Status delivered, carrier date missing | 2 | Handoff and transit NULL; still in breach metrics |
| Carrier pickup before approval | 1,359 | Handoff NULL; still in breach metrics |
| Carrier pickup before purchase | 166 | Subset of the row above |
| Delivered before carrier pickup | 23 | Transit NULL; root cause unattributable if late |
| Delivered before purchase | 0 | Asserted |
| Approved before purchase | 0 | Checked |
| Estimates with a non-midnight time | 0 | Reason for measuring lateness by date |
| Products with no category | 610 | Labelled `unknown` |
| Geolocation rows outside Brazil box | 42 | Dropped before the median |
| Geolocation rows beyond one per prefix | 981,148 | One median point per prefix |

## Known traps and how they are handled

- **Join fan-out.** Items, reviews and payments are all collapsed to one row per order before joining. A
  test confirms that item and payment totals on `fct_orders` equal the raw totals.
- **`customer_id` is per order.** It is the same size as the orders table. `customer_unique_id` identifies the
  person and is the only valid way to count people.
- **Survivorship.** Only delivered orders have a delivered date. 1,737 open orders were past their promise at the
  end of the data. Counting them all as late raises the breach rate from 6.8% to 8.4%.
- **Partial months.** Sep and Oct 2018 have almost no orders, and 2016 is sparse. Trend tables start in Jan 2017 and
  end in Aug 2018.
