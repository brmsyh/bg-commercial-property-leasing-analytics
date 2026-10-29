-- Q: What does the portfolio look like at 31-Dec-2025? (headline KPIs for leadership)
WITH dec AS (
    SELECT SUM(area_sqm) AS gla,
           SUM(area_sqm) FILTER (WHERE is_occupied) AS occupied_sqm
    FROM mart.fact_unit_month WHERE month_start = '2025-12-01'
),
rent25 AS (
    SELECT SUM(net_rent_eur) AS net_rent_2025, SUM(gross_rent_eur) AS gross_rent_2025
    FROM mart.fact_invoice WHERE billing_month BETWEEN '2025-01-01' AND '2025-12-01'
),
coll AS (   -- cash collected on 2025 invoices / billed 2025 (invoices due before 30-Nov)
    SELECT SUM(paid_eur) / SUM(total_eur) AS collection_rate
    FROM mart.fact_receivable WHERE billing_month BETWEEN '2025-01-01' AND '2025-11-01'
),
wault AS (  -- weighted average unexpired lease term, weighted by contract rent
    SELECT SUM(contract_rent_pa_eur * (effective_end - DATE '2025-12-31') / 365.25)
           / SUM(contract_rent_pa_eur) AS wault_years
    FROM mart.fact_lease WHERE outcome = 'Active' AND effective_end > '2025-12-31'
)
SELECT
    (SELECT COUNT(*) FROM mart.dim_building)                       AS buildings,
    (SELECT COUNT(*) FROM mart.dim_unit)                           AS units,
    round(dec.gla)                                                 AS gla_sqm,
    round(100 * dec.occupied_sqm / dec.gla, 1)                     AS occupancy_pct_dec25,
    round(rent25.net_rent_2025)                                    AS net_rent_2025_eur,
    round(100 * (1 - rent25.net_rent_2025 / rent25.gross_rent_2025), 1) AS rent_free_leakage_pct,
    round(100 * coll.collection_rate, 1)                           AS collection_rate_2025_pct,
    round(wault.wault_years, 2)                                    AS wault_years,
    round(100 * rent25.net_rent_2025 / (SELECT SUM(book_value_eur) FROM mart.dim_building), 2) AS gross_yield_pct
FROM dec, rent25, coll, wault;
