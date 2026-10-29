-- Q: Did the 2022 energy shock flow through to tenants, and was it collected?
SELECT
    EXTRACT(YEAR FROM i.billing_month)::INT - 1                     AS service_year,
    b.asset_type,
    round(SUM(i.sc_recon_eur))                                      AS reconciliation_billed_eur,
    COALESCE(round(SUM(r.open_eur) FILTER (WHERE i.sc_recon_eur > 0)), 0) AS still_open_eur,
    COUNT(*) FILTER (WHERE r.open_eur > 0.01 AND i.sc_recon_eur > 0) AS invoices_open
FROM mart.fact_invoice i
JOIN mart.dim_building b USING (building_id)
LEFT JOIN mart.fact_receivable r USING (invoice_id)
WHERE i.sc_recon_eur IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2;
