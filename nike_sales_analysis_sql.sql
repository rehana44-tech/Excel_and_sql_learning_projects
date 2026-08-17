-- =====================================================================
-- NIKE SALES DATA CLEANING & ANALYSIS PROJECT
-- postgresql | data analyst portfolio project
-- =====================================================================
-- dataset: nike_sales_uncleaned.csv (2,500 rows, 13 columns)
-- source columns: order_id, gender_category, product_line, product_name,
--                 size_product, units_sold, mrp, discount_applied,
--                 total_revenue, order_date, sales_channel, region, profit
-- =====================================================================


-- =====================================================================
-- 0. table setup
-- =====================================================================
-- raw data is loaded as-is. order_date is loaded as text because the
-- source file mixes two different date formats (see section 2), so it
-- cannot be safely cast to a date type at load time.

drop table if exists nike_sales_raw;

create table nike_sales_raw (
    order_id            int,
    gender_category     text,
    product_line        text,
    product_name         text,
    size_product        text,
    units_sold           numeric,
    mrp                   numeric,
    discount_applied      numeric,
    total_revenue          numeric,
    order_date            text,
    sales_channel          text,
    region                  text,
    profit                   numeric
);

-- load the csv (run this line from psql, adjust the path as needed)
-- \copy nike_sales_raw from 'Nike_Sales_Uncleaned.csv' with (format csv, header true, null '');

-- add a surrogate key: order_id is not a reliable primary key in this
-- dataset (see section 2), so a row-level id is used for all downstream
-- joins/aggregations instead.
alter table nike_sales_raw add column row_id serial primary key;


-- =====================================================================
-- 1. data overview
-- =====================================================================

-- row count and a first look at the data
select count(*) as total_rows from nike_sales_raw;

select *
from nike_sales_raw
limit 10;

-- column-level snapshot: data types as loaded
select column_name, data_type
from information_schema.columns
where table_name = 'nike_sales_raw'
order by ordinal_position;

-- distinct values for every categorical column, to see the raw
-- (uncleaned) category labels before any standardization
select 'gender_category' as column_name, gender_category as value, count(*) as row_count
from nike_sales_raw group by gender_category
union all
select 'product_line', product_line, count(*)
from nike_sales_raw group by product_line
union all
select 'sales_channel', sales_channel, count(*)
from nike_sales_raw group by sales_channel
union all
select 'region', region, count(*)
from nike_sales_raw group by region
order by column_name, row_count desc;

-- numeric column ranges, to spot impossible values (negatives, outliers)
select
    min(units_sold)        as min_units_sold,
    max(units_sold)        as max_units_sold,
    min(mrp)                as min_mrp,
    max(mrp)                as max_mrp,
    min(discount_applied)   as min_discount,
    max(discount_applied)   as max_discount,
    min(total_revenue)       as min_revenue,
    max(total_revenue)       as max_revenue,
    min(profit)                as min_profit,
    max(profit)                as max_profit
from nike_sales_raw;


-- =====================================================================
-- 2. data quality checks
-- =====================================================================

-- 2.1 missing values per column
select
    count(*) filter (where gender_category is null)  as missing_gender,
    count(*) filter (where product_line is null)      as missing_product_line,
    count(*) filter (where product_name is null)      as missing_product_name,
    count(*) filter (where size_product is null)      as missing_size,
    count(*) filter (where units_sold is null)        as missing_units_sold,
    count(*) filter (where mrp is null)                as missing_mrp,
    count(*) filter (where discount_applied is null)   as missing_discount,
    count(*) filter (where order_date is null)          as missing_order_date,
    count(*) filter (where sales_channel is null)        as missing_sales_channel,
    count(*) filter (where region is null)                as missing_region
from nike_sales_raw;

-- 2.2 duplicate order_id check
-- order_id would normally be expected to be unique per transaction.
-- this checks whether that assumption holds in this dataset.
select order_id, count(*) as occurrences
from nike_sales_raw
group by order_id
having count(*) > 1
order by occurrences desc;

-- 2.3 full row duplicates (every column identical)
select row_id
from (
    select row_id,
           row_number() over (
               partition by order_id, gender_category, product_line, product_name,
                             size_product, units_sold, mrp, discount_applied,
                             total_revenue, order_date, sales_channel, region, profit
               order by row_id
           ) as rn
    from nike_sales_raw
) d
where rn > 1;

-- 2.4 invalid units_sold: quantities cannot be negative
select row_id, units_sold
from nike_sales_raw
where units_sold < 0;

-- 2.5 invalid discount_applied: a discount rate should fall between 0 and 1
-- (0%-100%). anything above 1 is not a valid discount rate.
select row_id, discount_applied
from nike_sales_raw
where discount_applied > 1;

-- 2.6 inconsistent region spelling/capitalization
select distinct region
from nike_sales_raw
order by region;
-- finding: "bengaluru" and "Bangalore" refer to the same city, and
-- "Hyd" / "hyderbad" / "Hyderabad" all refer to the same city.

-- 2.7 order_date format inconsistency
-- the raw text mixes "m/d/yyyy" (slash-separated) and "dd-mm-yyyy"
-- (dash-separated) formats within the same column.
select
    count(*) filter (where order_date like '%/%')                as slash_format_rows,
    count(*) filter (where order_date like '%-%')                 as dash_format_rows,
    count(*) filter (where order_date is null)                     as missing_rows
from nike_sales_raw;

-- 2.8 total_revenue reliability check
-- total_revenue is 0 whenever discount_applied is null, even when
-- units_sold and mrp are present. this indicates total_revenue is a
-- placeholder/derived value that was never (re)calculated for those
-- rows, rather than a genuine $0 sale.
select
    count(*) filter (where total_revenue = 0 and discount_applied is null)  as zero_revenue_with_missing_discount,
    count(*) filter (where total_revenue = 0)                                 as zero_revenue_total
from nike_sales_raw;


-- =====================================================================
-- 3. data cleaning
-- =====================================================================
-- this section builds a single cleaned, analysis-ready table.
-- cleaning decisions are explained in the accompanying write-up.

drop table if exists nike_sales_clean;

create table nike_sales_clean as
with parsed as (
    select
        row_id,
        order_id,

        -- standardize categorical text: trim whitespace, fix casing
        initcap(trim(gender_category)) as gender_category,
        initcap(trim(product_line))     as product_line,
        trim(product_name)               as product_name,
        upper(trim(size_product))         as size_product,
        initcap(trim(sales_channel))       as sales_channel,

        -- standardize region names: fix inconsistent city spelling/casing
        case
            when lower(trim(region)) in ('bangalore', 'bengaluru') then 'Bangalore'
            when lower(trim(region)) in ('hyderabad', 'hyd', 'hyderbad') then 'Hyderabad'
            else initcap(trim(region))
        end as region,

        -- units_sold: negative quantities are invalid, treat as unknown
        case when units_sold >= 0 then units_sold else null end as units_sold_clean,

        mrp,

        -- discount_applied: a valid discount rate is between 0 and 1.
        -- values above 1 (e.g. 1.25) are data-entry errors and are
        -- treated as unknown rather than guessed at.
        case when discount_applied between 0 and 1 then discount_applied else null end as discount_clean,

        -- parse order_date from its two mixed formats:
        -- rows containing '/' are m/d/yyyy, rows containing '-' are dd-mm-yyyy
        case
            when order_date like '%/%' then to_date(order_date, 'MM/DD/YYYY')
            when order_date like '%-%' then to_date(order_date, 'DD-MM-YYYY')
            else null
        end as order_date_clean,

        profit,
        total_revenue as total_revenue_raw

    from nike_sales_raw
)
select
    row_id,
    order_id,
    gender_category,
    product_line,
    product_name,
    size_product,
    units_sold_clean                                                   as units_sold,
    mrp,
    discount_clean                                                       as discount_applied,
    -- recalculated revenue: units_sold * mrp * (1 - discount).
    -- confirmed against the rows where the source total_revenue was
    -- non-zero: the formula matches the original data exactly, so it
    -- is used to fill in the revenue for every row consistently
    -- (missing/invalid discount is treated as 0% for this calculation).
    round(units_sold_clean * mrp * (1 - coalesce(discount_clean, 0)), 2) as revenue_calculated,
    total_revenue_raw,
    order_date_clean                                                    as order_date,
    extract(year from order_date_clean)                                  as order_year,
    to_char(order_date_clean, 'YYYY-MM')                                  as order_month,
    sales_channel,
    region,
    profit,
    -- profit margin: profit as a percentage of recalculated revenue
    -- (only meaningful where revenue is a positive, non-zero number)
    case
        when revenue_flag.revenue > 0 then round((profit / revenue_flag.revenue) * 100, 2)
        else null
    end as profit_margin_pct
from parsed
cross join lateral (
    select round(units_sold_clean * mrp * (1 - coalesce(discount_clean, 0)), 2) as revenue
) as revenue_flag;

-- indexes to support the analysis queries below
create index idx_clean_product_line on nike_sales_clean (product_line);
create index idx_clean_region on nike_sales_clean (region);
create index idx_clean_order_month on nike_sales_clean (order_month);


-- =====================================================================
-- 4. validation checks (post-cleaning)
-- =====================================================================

-- 4.1 row count should match the raw table (no rows were dropped;
-- invalid values were nulled, not removed)
select
    (select count(*) from nike_sales_raw)   as raw_row_count,
    (select count(*) from nike_sales_clean) as clean_row_count;

-- 4.2 confirm no negative units_sold or out-of-range discounts remain
select
    count(*) filter (where units_sold < 0)             as remaining_negative_units,
    count(*) filter (where discount_applied > 1)         as remaining_invalid_discount
from nike_sales_clean;

-- 4.3 confirm region values are now standardized
select distinct region from nike_sales_clean order by region;

-- 4.4 confirm date parsing succeeded (should be 0 rows with an
-- original date string but a null parsed date)
select r.row_id, r.order_date
from nike_sales_raw r
join nike_sales_clean c on c.row_id = r.row_id
where r.order_date is not null and c.order_date is null;

-- 4.5 sanity check: recalculated revenue should never be negative
-- once invalid discounts have been nulled out
select count(*) as negative_revenue_rows
from nike_sales_clean
where revenue_calculated < 0;


-- =====================================================================
-- 5. exploratory data analysis
-- =====================================================================

-- 5.1 orders and revenue by product line
select
    product_line,
    count(*)                                    as order_count,
    sum(units_sold)                              as total_units_sold,
    round(sum(revenue_calculated), 2)             as total_revenue,
    round(avg(revenue_calculated), 2)              as avg_revenue_per_order
from nike_sales_clean
group by product_line
order by total_revenue desc;

-- 5.2 orders by gender category
select
    gender_category,
    count(*)                        as order_count,
    round(sum(revenue_calculated), 2) as total_revenue,
    round(sum(profit), 2)              as total_profit
from nike_sales_clean
group by gender_category
order by total_revenue desc;

-- 5.3 sales channel comparison (online vs retail)
select
    sales_channel,
    count(*)                          as order_count,
    round(sum(revenue_calculated), 2)  as total_revenue,
    round(avg(revenue_calculated), 2)   as avg_revenue_per_order,
    round(sum(profit), 2)                as total_profit
from nike_sales_clean
group by sales_channel
order by total_revenue desc;

-- 5.4 revenue and profit by region
select
    region,
    count(*)                          as order_count,
    round(sum(revenue_calculated), 2)  as total_revenue,
    round(sum(profit), 2)               as total_profit
from nike_sales_clean
group by region
order by total_revenue desc;

-- 5.5 monthly order/revenue trend
select
    order_month,
    count(*)                          as order_count,
    round(sum(revenue_calculated), 2)  as total_revenue
from nike_sales_clean
where order_month is not null
group by order_month
order by order_month;

-- 5.6 discount usage: how often are discounts actually applied
select
    count(*) filter (where discount_applied is not null and discount_applied > 0) as discounted_orders,
    count(*) filter (where discount_applied = 0)                                    as zero_discount_orders,
    count(*) filter (where discount_applied is null)                                  as unknown_discount_orders,
    round(avg(discount_applied) filter (where discount_applied > 0), 3)                 as avg_discount_rate
from nike_sales_clean;


-- =====================================================================
-- 6. business analysis
-- =====================================================================

-- 6.1 top 5 best-selling products by units sold
select
    product_name,
    product_line,
    sum(units_sold)                    as total_units_sold,
    round(sum(revenue_calculated), 2)   as total_revenue
from nike_sales_clean
where units_sold is not null
group by product_name, product_line
order by total_units_sold desc
limit 5;

-- 6.2 top 5 most profitable products
select
    product_name,
    product_line,
    round(sum(profit), 2)     as total_profit,
    round(avg(profit), 2)      as avg_profit_per_order,
    count(*)                     as order_count
from nike_sales_clean
group by product_name, product_line
order by total_profit desc
limit 5;

-- 6.3 ranking product lines by profit within each region
select
    region,
    product_line,
    round(sum(profit), 2) as total_profit,
    rank() over (partition by region order by sum(profit) desc) as profit_rank
from nike_sales_clean
group by region, product_line
order by region, profit_rank;

-- 6.4 does a higher discount rate correlate with lower profit margin?
select
    case
        when discount_applied is null then 'unknown'
        when discount_applied = 0 then '0% (no discount)'
        when discount_applied <= 0.25 then '1-25%'
        when discount_applied <= 0.50 then '26-50%'
        when discount_applied <= 0.75 then '51-75%'
        else '76-100%'
    end as discount_band,
    count(*)                          as order_count,
    round(avg(profit_margin_pct), 2)   as avg_profit_margin_pct
from nike_sales_clean
group by discount_band
order by discount_band;

-- 6.5 size distribution by gender category (apparel/shoe sizing mix)
select
    gender_category,
    size_product,
    count(*) as order_count
from nike_sales_clean
where size_product is not null
group by gender_category, size_product
order by gender_category, order_count desc;

-- 6.6 orders with missing critical fields (units_sold or mrp), flagged
-- for follow-up rather than dropped, since profit is still recorded
-- for these rows and remains usable for profit-based analysis
select
    count(*) as incomplete_orders,
    round(sum(profit), 2) as profit_from_incomplete_orders
from nike_sales_clean
where units_sold is null or mrp is null;


-- =====================================================================
-- 7. key metrics summary
-- =====================================================================

select
    count(*)                                                            as total_orders,
    count(distinct order_id)                                             as distinct_order_ids,
    sum(units_sold)                                                       as total_units_sold,
    round(sum(revenue_calculated), 2)                                      as total_revenue,
    round(sum(profit), 2)                                                   as total_profit,
    round(avg(revenue_calculated), 2)                                        as avg_revenue_per_order,
    round(avg(profit), 2)                                                     as avg_profit_per_order,
    round(sum(profit) / nullif(sum(revenue_calculated), 0) * 100, 2)          as overall_profit_margin_pct
from nike_sales_clean;
