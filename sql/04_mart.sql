-- =====================================================================
-- 04_mart.sql
-- Star schema used by the analysis queries and the Tableau dashboards.
-- Reporting window: Jan-2021 .. Dec-2025, as-of date 31-Dec-2025.
-- =====================================================================
DROP SCHEMA IF EXISTS mart CASCADE;
CREATE SCHEMA mart;

-- ---------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------
CREATE TABLE mart.dim_month AS
SELECT
    d::DATE                                   AS month_start,
    (d + INTERVAL '1 month - 1 day')::DATE    AS month_end,
    EXTRACT(YEAR FROM d)::INT                 AS year,
    EXTRACT(QUARTER FROM d)::INT              AS quarter,
    EXTRACT(MONTH FROM d)::INT                AS month,
    to_char(d, 'YYYY-MM')                     AS year_month
FROM generate_series('2021-01-01'::DATE, '2025-12-01'::DATE, INTERVAL '1 month') AS d;
ALTER TABLE mart.dim_month ADD PRIMARY KEY (month_start);

CREATE TABLE mart.dim_building AS
SELECT b.*,
       2025 - b.year_built AS building_age,
       (SELECT COUNT(*) FROM clean.units u WHERE u.building_id = b.building_id) AS n_units
FROM clean.buildings b;
ALTER TABLE mart.dim_building ADD PRIMARY KEY (building_id);

CREATE TABLE mart.dim_unit AS
SELECT u.unit_id, u.unit_code, u.building_id, b.building_code, b.city, b.asset_type, b.grade,
       u.floor, u.unit_type, u.area_sqm, u.area_fixed_flag, u.asking_rent_eur_sqm,
       mb.benchmark_rent_eur_sqm,
       round(u.asking_rent_eur_sqm / mb.benchmark_rent_eur_sqm - 1, 4) AS asking_vs_market,
       CASE WHEN u.area_sqm < 100 THEN '< 100 sqm'
            WHEN u.area_sqm < 300 THEN '100-299 sqm'
            WHEN u.area_sqm < 800 THEN '300-799 sqm'
            ELSE '800+ sqm' END AS size_band
FROM clean.units u
JOIN clean.buildings b USING (building_id)
LEFT JOIN clean.market_rent_benchmark mb
       ON mb.unit_type = u.unit_type AND mb.city = b.city AND mb.grade = b.grade;
ALTER TABLE mart.dim_unit ADD PRIMARY KEY (unit_id);

CREATE TABLE mart.dim_tenant AS SELECT * FROM clean.tenants;
ALTER TABLE mart.dim_tenant ADD PRIMARY KEY (tenant_id);

-- ---------------------------------------------------------------------
-- Leases (one row per lease contract)
-- ---------------------------------------------------------------------
CREATE TABLE mart.fact_lease AS
SELECT
    l.*,
    COALESCE(l.termination_date, l.end_date)             AS effective_end,
    u.building_id, u.area_sqm,
    round(l.rent_eur_sqm * u.area_sqm * 12, 2)           AS contract_rent_pa_eur,
    CASE
        WHEN l.status = 'Expired - renewed' THEN 'Renewed'
        WHEN l.status = 'Expired - vacated' THEN 'Vacated'
        WHEN l.status = 'Terminated early'  THEN 'Terminated early'
        ELSE 'Active'
    END                                                  AS outcome
FROM clean.leases l
JOIN clean.units u USING (unit_id);
ALTER TABLE mart.fact_lease ADD PRIMARY KEY (lease_id);
CREATE INDEX ON mart.fact_lease (unit_id, start_date, effective_end);

-- ---------------------------------------------------------------------
-- Invoices: header (lease-month) + lines
-- ---------------------------------------------------------------------
CREATE TABLE mart.fact_invoice_line AS
SELECT il.line_id, il.invoice_id, il.lease_id, l.tenant_id, l.unit_id, l.building_id,
       il.billing_month, il.charge_code, il.amount_eur
FROM clean.invoice_lines il
JOIN mart.fact_lease l USING (lease_id);
ALTER TABLE mart.fact_invoice_line ADD PRIMARY KEY (line_id);

CREATE TABLE mart.fact_invoice AS
SELECT
    invoice_id, lease_id, tenant_id, unit_id, building_id, billing_month,
    (billing_month + 14)                                                      AS due_date,
    SUM(amount_eur) FILTER (WHERE charge_code IN ('RENT', 'RENT_FREE'))       AS net_rent_eur,
    SUM(amount_eur) FILTER (WHERE charge_code = 'RENT')                       AS gross_rent_eur,
    -SUM(amount_eur) FILTER (WHERE charge_code = 'RENT_FREE')                 AS rent_free_eur,
    SUM(amount_eur) FILTER (WHERE charge_code = 'SERVICE_CHARGE')             AS service_charge_eur,
    SUM(amount_eur) FILTER (WHERE charge_code = 'SC_RECONCILIATION')          AS sc_recon_eur,
    SUM(amount_eur) FILTER (WHERE charge_code IN ('UTILITIES', 'PARKING', 'MARKETING_LEVY')) AS other_eur,
    SUM(amount_eur)                                                           AS total_eur
FROM mart.fact_invoice_line
GROUP BY 1, 2, 3, 4, 5, 6;
ALTER TABLE mart.fact_invoice ADD PRIMARY KEY (invoice_id);

CREATE TABLE mart.fact_payment AS
SELECT p.payment_id, p.invoice_id, i.tenant_id, i.building_id, p.payment_date, p.amount_eur, p.method,
       p.payment_date - i.due_date AS days_after_due
FROM clean.payments p
JOIN mart.fact_invoice i USING (invoice_id);
ALTER TABLE mart.fact_payment ADD PRIMARY KEY (payment_id);

-- Invoice settlement status as of 31-Dec-2025
CREATE TABLE mart.fact_receivable AS
WITH paid AS (
    SELECT invoice_id, SUM(amount_eur) AS paid_eur, MAX(payment_date) AS last_payment_date
    FROM clean.payments GROUP BY 1
)
SELECT i.invoice_id, i.lease_id, i.tenant_id, i.unit_id, i.building_id, i.billing_month, i.due_date,
       i.total_eur, i.sc_recon_eur,
       COALESCE(p.paid_eur, 0)                                  AS paid_eur,
       GREATEST(i.total_eur - COALESCE(p.paid_eur, 0), 0)       AS open_eur,
       ('2025-12-31'::DATE - i.due_date)                        AS days_past_due,
       CASE
           WHEN i.total_eur - COALESCE(p.paid_eur, 0) <= 0.01 THEN 'Settled'
           WHEN '2025-12-31'::DATE - i.due_date <= 0   THEN 'Not yet due'
           WHEN '2025-12-31'::DATE - i.due_date <= 30  THEN '1-30 days'
           WHEN '2025-12-31'::DATE - i.due_date <= 90  THEN '31-90 days'
           WHEN '2025-12-31'::DATE - i.due_date <= 180 THEN '91-180 days'
           ELSE '180+ days'
       END                                                      AS aging_bucket
FROM mart.fact_invoice i
LEFT JOIN paid p USING (invoice_id)
WHERE i.total_eur > 0;
ALTER TABLE mart.fact_receivable ADD PRIMARY KEY (invoice_id);

-- ---------------------------------------------------------------------
-- Unit x month occupancy grain (the backbone of occupancy & income KPIs)
-- ---------------------------------------------------------------------
CREATE TABLE mart.fact_unit_month AS
SELECT
    u.unit_id, u.building_id, m.month_start,
    u.area_sqm,
    l.lease_id, l.tenant_id,
    (l.lease_id IS NOT NULL)                         AS is_occupied,
    COALESCE(i.net_rent_eur, 0)                      AS net_rent_eur,
    COALESCE(i.gross_rent_eur, 0)                    AS gross_rent_eur
FROM mart.dim_unit u
CROSS JOIN mart.dim_month m
LEFT JOIN LATERAL (
    SELECT fl.lease_id, fl.tenant_id
    FROM mart.fact_lease fl
    WHERE fl.unit_id = u.unit_id
      AND fl.start_date   <= m.month_end
      AND fl.effective_end >= m.month_start
    ORDER BY fl.start_date DESC
    LIMIT 1
) l ON TRUE
LEFT JOIN mart.fact_invoice i ON i.lease_id = l.lease_id AND i.billing_month = m.month_start;
ALTER TABLE mart.fact_unit_month ADD PRIMARY KEY (unit_id, month_start);

-- ---------------------------------------------------------------------
-- Maintenance tickets with SLA logic
-- ---------------------------------------------------------------------
CREATE TABLE mart.fact_ticket AS
SELECT
    t.*,
    u.building_id,
    CASE t.priority WHEN 'Critical' THEN 4 WHEN 'High' THEN 24 WHEN 'Medium' THEN 72 ELSE 168 END AS sla_hours,
    round((EXTRACT(EPOCH FROM (t.resolved_at - t.created_at)) / 3600)::NUMERIC, 1)               AS resolution_hours,
    date_trunc('month', t.created_at)::DATE AS created_month
FROM clean.maintenance_tickets t
JOIN clean.units u USING (unit_id);
ALTER TABLE mart.fact_ticket ADD COLUMN sla_breach BOOLEAN;
UPDATE mart.fact_ticket SET sla_breach = resolution_hours > sla_hours WHERE resolution_hours IS NOT NULL;
ALTER TABLE mart.fact_ticket ADD PRIMARY KEY (ticket_id);
CREATE INDEX ON mart.fact_ticket (lease_id, created_at);

-- ---------------------------------------------------------------------
-- Lease expiries inside the window + service experience in the
-- 12 months before expiry (input for the renewal analysis)
-- ---------------------------------------------------------------------
CREATE TABLE mart.fact_lease_expiry AS
SELECT
    l.lease_id, l.unit_id, l.tenant_id, l.building_id, l.end_date, l.area_sqm,
    l.outcome, (l.outcome = 'Renewed')::INT AS renewed,
    t.segment, t.industry,
    COUNT(tk.ticket_id)                                          AS tickets_12m,
    COUNT(tk.ticket_id) FILTER (WHERE tk.sla_breach)             AS sla_breaches_12m,
    COUNT(tk.ticket_id) FILTER (WHERE tk.category = 'HVAC')      AS hvac_tickets_12m,
    COUNT(tk.ticket_id) FILTER (WHERE tk.reopened)               AS reopened_12m,
    round(AVG(tk.satisfaction), 2)                               AS avg_satisfaction_12m
FROM mart.fact_lease l
JOIN mart.dim_tenant t USING (tenant_id)
LEFT JOIN mart.fact_ticket tk
       ON tk.lease_id = l.lease_id
      AND tk.created_at >= l.end_date - INTERVAL '12 months'
      AND tk.created_at <= l.end_date
WHERE l.outcome IN ('Renewed', 'Vacated')
  AND l.end_date BETWEEN '2021-01-01' AND '2025-12-31'
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10;
ALTER TABLE mart.fact_lease_expiry ADD COLUMN complaint_band TEXT;
UPDATE mart.fact_lease_expiry SET complaint_band =
    CASE WHEN sla_breaches_12m = 0 THEN '0 SLA breaches'
         WHEN sla_breaches_12m = 1 THEN '1 SLA breach'
         WHEN sla_breaches_12m = 2 THEN '2 SLA breaches'
         ELSE '3+ SLA breaches' END;

ANALYZE;

SELECT 'fact_unit_month' AS tbl, COUNT(*) FROM mart.fact_unit_month UNION ALL
SELECT 'fact_invoice_line', COUNT(*) FROM mart.fact_invoice_line UNION ALL
SELECT 'fact_invoice', COUNT(*) FROM mart.fact_invoice UNION ALL
SELECT 'fact_payment', COUNT(*) FROM mart.fact_payment UNION ALL
SELECT 'fact_ticket', COUNT(*) FROM mart.fact_ticket UNION ALL
SELECT 'fact_lease', COUNT(*) FROM mart.fact_lease UNION ALL
SELECT 'fact_lease_expiry', COUNT(*) FROM mart.fact_lease_expiry;
