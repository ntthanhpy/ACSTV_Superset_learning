/*
Dataset: ds_demographic_age_month_v1
Source: analytics.v__consumption
Grain: one row per month + range_age.

CORE METRICS (nine charts from this one virtual dataset):
                           Count / Value                         Share %                       Growth %
Purchasing Members         current_purchasing_member_count      purchasing_member_share       purchasing_member_growth
Net Sales                  current_net_sales_ex_non_promo       net_sales_ex_non_promo_share  net_sales_ex_non_promo_growth
Transactions               current_transaction_count            transaction_share             transaction_growth

Explore: Time column = month; Time grain = Month; Dimension = range_age.
At exactly this grain, use MAX(metric_column) for each precomputed metric.
Count/Value formats: ,d for members/transactions, ,.0f for net sales.
Share/Growth format: .2% (the stored value is a ratio, not ratio * 100).
Keep month in each chart's grouping. Do not SUM shares or growth percentages.
Monthly distinct member counts cannot be summed into a whole-period distinct KPI.

BUSINESS SEMANTICS:
- Counts follow the supplied reference: distinct IDs from all filtered source
  transactions. No Sale-only predicate is introduced. If the view contains
  returns, a return-only member can therefore be counted in Purchasing Members.
- Net sales are summed as supplied by the view, including its return signs.
- Age bands come from range_age; no new age-band mapping is introduced.
- Purchasing Member Share uses the sum of per-age-band distinct counts for the
  same month. For a disjoint composition, each member must have one age band
  per month. Otherwise this is a share of member-band memberships.
- Comparison labels use the age band at the original comparison transaction.
- Share denominators include all source age bands after OU/store/tenant filters.
  Filtering range_age only in the outer chart does not rebase these shares.

TIME AND COMPARISON:
- month is the Current calendar axis, represented by its first day as Date.
- The macro consumes the virtual dataset's temporal column month; WHERE clauses
  apply the selected boundaries to the source transaction_dt before aggregation.
- All intervals use [start, end): start inclusive, end exclusive.
- Fallback is the full day 2026-06-15: [2026-06-15, 2026-06-16).
  Select a bounded range spanning several months to see a multi-month trend.
- Last Period: immediately preceding interval with the same elapsed duration.
- MoM / YoY: shift both boundaries by one calendar month / year; month-end and
  leap-day clipping follow ClickHouse's addMonths / addYears behavior.
- Comparison dates are shifted forward to the Current month axis. For Last
  Period, one aligned month can include portions of two original source months.
- UNION ALL lets a row contribute once to each period if the windows overlap.
- A month/age group absent from both periods is not generated as a zero row.
- Growth compares period values in the same aligned month; it is not growth
  in share (percentage-point change). Partial months compare partial windows.
- Zero-denominator share/growth is NULL. Net-sales growth requires a positive
  comparison net-sales value; it is NULL for zero or negative baselines.

Select exactly one comparison_type: Last Period, MoM, or YoY.
Native operationunit_name/store_name/tenant_name filters below support IN.
SQL templates must be enabled in Superset. Save as a Virtual Dataset, not a
ClickHouse CREATE VIEW containing Jinja. Actual source schema/execution must
be validated on the user's ClickHouse instance.

Reference: https://superset.apache.org/user-docs/using-superset/sql-templating/
*/

-- 01. FETCH DASHBOARD PARAMETERS
{% set selected_compare = (
    filter_values('comparison_type', remove_filter=True) | first
) or 'Last Period' %}
{% if selected_compare not in ['Last Period', 'MoM', 'YoY'] %}
    {% set selected_compare = 'Last Period' %}
{% endif %}

-- month is the exposed temporal column; source filtering uses transaction_dt.
{% set time_filter = get_time_filter(
    'month', target_type='DATETIME', remove_filter=True
) %}
{% set start_date = time_filter.from_expr or "'2026-06-15 00:00:00'" %}
{% set end_date = time_filter.to_expr or "'2026-06-16 00:00:00'" %}

{% set selected_ou = filter_values('operationunit_name', remove_filter=True) %}
{% set selected_store = filter_values('store_name', remove_filter=True) %}
{% set selected_tenant = filter_values('tenant_name', remove_filter=True) %}

WITH
-- 02. CURRENT PERIOD: [START, END)
current_period AS (
    SELECT
        toDateTime({{ start_date }}) AS curr_s,
        toDateTime({{ end_date }}) AS curr_e
),

-- 03. DEFINE COMPARISON PERIOD
time_config AS (
    SELECT
        curr_s,
        curr_e,
        dateDiff('second', curr_s, curr_e) AS period_seconds,
        {% if selected_compare == 'YoY' %}
            addYears(curr_s, -1) AS prev_s,
            addYears(curr_e, -1) AS prev_e
        {% elif selected_compare == 'MoM' %}
            addMonths(curr_s, -1) AS prev_s,
            addMonths(curr_e, -1) AS prev_e
        {% else %}
            addSeconds(curr_s, -period_seconds) AS prev_s,
            curr_s AS prev_e
        {% endif %}
    FROM current_period
),

-- 04. ALIGN CURRENT AND COMPARISON ROWS
period_rows AS (
    SELECT
        c.transaction_dt AS aligned_transaction_dt,
        c.range_age,
        c.hk_member_consumption,
        c.hk_member,
        c.net_sales_ex_non_promo,
        1 AS is_current,
        0 AS is_compare
    FROM analytics.v__consumption AS c
    CROSS JOIN time_config AS t
    WHERE c.transaction_dt >= t.curr_s
      AND c.transaction_dt < t.curr_e
    {% if selected_ou %}
        AND c.operationunit_name IN {{ selected_ou | where_in }}
    {% endif %}
    {% if selected_store %}
        AND c.store_name IN {{ selected_store | where_in }}
    {% endif %}
    {% if selected_tenant %}
        AND c.tenant_name IN {{ selected_tenant | where_in }}
    {% endif %}

    UNION ALL

    SELECT
        {% if selected_compare == 'YoY' %}
            addYears(c.transaction_dt, 1)
        {% elif selected_compare == 'MoM' %}
            addMonths(c.transaction_dt, 1)
        {% else %}
            addSeconds(c.transaction_dt, t.period_seconds)
        {% endif %} AS aligned_transaction_dt,
        c.range_age,
        c.hk_member_consumption,
        c.hk_member,
        c.net_sales_ex_non_promo,
        0 AS is_current,
        1 AS is_compare
    FROM analytics.v__consumption AS c
    CROSS JOIN time_config AS t
    WHERE c.transaction_dt >= t.prev_s
      AND c.transaction_dt < t.prev_e
    {% if selected_ou %}
        AND c.operationunit_name IN {{ selected_ou | where_in }}
    {% endif %}
    {% if selected_store %}
        AND c.store_name IN {{ selected_store | where_in }}
    {% endif %}
    {% if selected_tenant %}
        AND c.tenant_name IN {{ selected_tenant | where_in }}
    {% endif %}
),

-- 05. AGGREGATE BY AGE BAND AND ALIGNED MONTH
aggregated_data AS (
    SELECT
        range_age,
        toStartOfMonth(toDate(aligned_transaction_dt)) AS month,

        toInt64(uniqExactIf(
            hk_member_consumption, is_current = 1
        )) AS current_transaction_count,
        toInt64(uniqExactIf(
            hk_member_consumption, is_compare = 1
        )) AS compare_transaction_count,

        toInt64(uniqExactIf(
            hk_member, is_current = 1
        )) AS current_purchasing_member_count,
        toInt64(uniqExactIf(
            hk_member, is_compare = 1
        )) AS compare_purchasing_member_count,

        sumIf(
            net_sales_ex_non_promo, is_current = 1
        ) AS current_net_sales_ex_non_promo,
        sumIf(
            net_sales_ex_non_promo, is_compare = 1
        ) AS compare_net_sales_ex_non_promo
    FROM period_rows
    GROUP BY range_age, month
)

-- 06. COUNT/VALUE, SHARE, CHANGE, IMPACT AND GROWTH
SELECT
    range_age,
    month,

    -- Transactions
    current_transaction_count,
    compare_transaction_count,
    round(
        toFloat64(current_transaction_count)
        / nullIf(toFloat64(
            SUM(current_transaction_count) OVER (PARTITION BY month)
        ), 0.0),
        6
    ) AS transaction_share,
    current_transaction_count - compare_transaction_count
        AS transaction_absolute_change,
    ABS(current_transaction_count - compare_transaction_count)
        AS transaction_impact,
    round(
        toFloat64(current_transaction_count - compare_transaction_count)
        / nullIf(toFloat64(compare_transaction_count), 0.0),
        6
    ) AS transaction_growth,

    -- Purchasing Members
    current_purchasing_member_count,
    compare_purchasing_member_count,
    round(
        toFloat64(current_purchasing_member_count)
        / nullIf(toFloat64(
            SUM(current_purchasing_member_count) OVER (PARTITION BY month)
        ), 0.0),
        6
    ) AS purchasing_member_share,
    current_purchasing_member_count - compare_purchasing_member_count
        AS purchasing_member_absolute_change,
    ABS(current_purchasing_member_count - compare_purchasing_member_count)
        AS purchasing_member_impact,
    round(
        toFloat64(current_purchasing_member_count - compare_purchasing_member_count)
        / nullIf(toFloat64(compare_purchasing_member_count), 0.0),
        6
    ) AS purchasing_member_growth,

    -- Net Sales (excluding non-promo)
    current_net_sales_ex_non_promo,
    compare_net_sales_ex_non_promo,
    round(
        toFloat64(current_net_sales_ex_non_promo)
        / nullIf(toFloat64(
            SUM(current_net_sales_ex_non_promo) OVER (PARTITION BY month)
        ), 0.0),
        6
    ) AS net_sales_ex_non_promo_share,
    current_net_sales_ex_non_promo - compare_net_sales_ex_non_promo
        AS net_sales_ex_non_promo_absolute_change,
    ABS(current_net_sales_ex_non_promo - compare_net_sales_ex_non_promo)
        AS net_sales_ex_non_promo_impact,
    round(
        if(
            compare_net_sales_ex_non_promo > 0,
            toFloat64(current_net_sales_ex_non_promo - compare_net_sales_ex_non_promo)
            / nullIf(toFloat64(compare_net_sales_ex_non_promo), 0.0),
            NULL
        ),
        6
    ) AS net_sales_ex_non_promo_growth
FROM aggregated_data
ORDER BY month ASC, range_age ASC
