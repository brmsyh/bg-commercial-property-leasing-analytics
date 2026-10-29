-- =====================================================================
-- 05_tableau_views.sql
-- Flat, denormalised views that feed the Tableau workbook.
-- (Tableau Public cannot connect to PostgreSQL, so src/export_tableau.py
--  writes each view to tableau/data/*.csv)
-- =====================================================================
DROP SCHEMA IF EXISTS tableau CASCADE;
CREATE SCHEMA tableau;

-- 1. Occupancy & income: unit x month
CREATE VIEW tableau.unit_month AS
SELECT f.month_start, m.year, f.unit_id, u.unit_code, u.unit_type, u.size_band,
       b.building_code, b.city, b.asset_type, b.grade,
       f.area_sqm, f.is_occupied::INT AS is_occupied,
       CASE WHEN f.is_occupied THEN f.area_sqm ELSE 0 END AS occupied_sqm,
       f.tenant_id, f.net_rent_eur, f.gross_rent_eur
FROM mart.fact_unit_month f
JOIN mart.dim_month m USING (month_start)
JOIN mart.dim_unit u USING (unit_id)
JOIN mart.dim_building b ON b.building_id = f.building_id;

-- 2. Building scorecard (one row per building)
CREATE VIEW tableau.building_scorecard AS
WITH occ AS (
    SELECT building_id,
           SUM(area_sqm) FILTER (WHERE is_occupied AND month_start = '2025-12-01')
         / SUM(area_sqm) FILTER (WHERE month_start = '2025-12-01')            AS occupancy_dec25,
           SUM(net_rent_eur) FILTER (WHERE month_start >= '2025-01-01')       AS net_rent_2025
    FROM mart.fact_unit_month GROUP BY 1
),
tk AS (
    SELECT building_id, COUNT(*) AS tickets, AVG(sla_breach::INT) AS sla_breach_rate,
           AVG(satisfaction) AS avg_satisfaction
    FROM mart.fact_ticket GROUP BY 1
),
ren AS (
    SELECT building_id, COUNT(*) AS expiries, AVG(renewed) AS renewal_rate
    FROM mart.fact_lease_expiry GROUP BY 1
),
ar AS (
    SELECT building_id,
           SUM(open_eur) FILTER (WHERE aging_bucket = '180+ days') AS ar_180_plus,
           SUM(open_eur) FILTER (WHERE aging_bucket NOT IN ('Settled', 'Not yet due')) AS ar_overdue
    FROM mart.fact_receivable GROUP BY 1
),
px AS (
    SELECT building_id, AVG(asking_vs_market) AS asking_vs_market FROM mart.dim_unit GROUP BY 1
)
SELECT b.building_code, b.city, b.asset_type, b.grade, b.year_built, b.gla_sqm, b.book_value_eur,
       round(occ.occupancy_dec25, 4)                       AS occupancy_dec25,
       round(occ.net_rent_2025)                            AS net_rent_2025_eur,
       round(occ.net_rent_2025 / b.book_value_eur, 4)      AS gross_yield,
       round(px.asking_vs_market, 4)                       AS asking_vs_market,
       tk.tickets, round(tk.sla_breach_rate, 4)            AS sla_breach_rate,
       round(tk.avg_satisfaction, 2)                       AS avg_satisfaction,
       ren.expiries, round(ren.renewal_rate, 4)            AS renewal_rate,
       round(ar.ar_overdue)                                AS ar_overdue_eur,
       round(ar.ar_180_plus)                               AS ar_180_plus_eur
FROM mart.dim_building b
JOIN occ USING (building_id) JOIN tk USING (building_id) JOIN ren USING (building_id)
JOIN ar USING (building_id) JOIN px USING (building_id);

-- 3. Maintenance tickets
CREATE VIEW tableau.tickets AS
SELECT t.ticket_id, t.created_month, t.created_at, t.resolved_at, t.category, t.priority,
       t.sla_hours, t.resolution_hours, t.sla_breach::INT AS sla_breach, t.reopened::INT AS reopened,
       t.satisfaction, t.status, b.building_code, b.city, b.asset_type, b.grade, t.tenant_id, t.lease_id
FROM mart.fact_ticket t JOIN mart.dim_building b USING (building_id);

-- 4. Lease expiries & renewal outcome
CREATE VIEW tableau.lease_expiry AS
SELECT e.lease_id, e.tenant_id, e.end_date, EXTRACT(YEAR FROM e.end_date)::INT AS expiry_year,
       e.outcome, e.renewed, e.segment, e.industry, e.area_sqm,
       e.tickets_12m, e.sla_breaches_12m, e.hvac_tickets_12m, e.avg_satisfaction_12m, e.complaint_band,
       b.building_code, b.city, b.asset_type, b.grade, l.contract_rent_pa_eur
FROM mart.fact_lease_expiry e
JOIN mart.fact_lease l USING (lease_id)
JOIN mart.dim_building b ON b.building_id = e.building_id;

-- 5. Receivables (invoice level, as of 31-Dec-2025)
CREATE VIEW tableau.receivables AS
SELECT r.invoice_id, r.billing_month, r.due_date, r.total_eur, r.paid_eur, r.open_eur,
       COALESCE(r.sc_recon_eur, 0) AS sc_recon_eur, r.days_past_due, r.aging_bucket,
       r.tenant_id, t.segment, t.industry, b.building_code, b.city, b.asset_type
FROM mart.fact_receivable r
JOIN mart.dim_tenant t USING (tenant_id)
JOIN mart.dim_building b USING (building_id);

-- 6. Vacancy spells with pricing
CREATE VIEW tableau.vacancy_spells AS
WITH um AS (
    SELECT unit_id, month_start, is_occupied,
           ROW_NUMBER() OVER (PARTITION BY unit_id ORDER BY month_start)
         - ROW_NUMBER() OVER (PARTITION BY unit_id, is_occupied ORDER BY month_start) AS grp
    FROM mart.fact_unit_month
)
SELECT um.unit_id, u.unit_code, u.building_code, u.city, u.grade, u.unit_type, u.area_sqm,
       u.asking_rent_eur_sqm, u.benchmark_rent_eur_sqm, u.asking_vs_market,
       MIN(um.month_start) AS vacant_from, MAX(um.month_start) AS vacant_to, COUNT(*) AS months_vacant,
       (MAX(um.month_start) < '2025-12-01' AND MIN(um.month_start) > '2021-01-01')::INT AS is_complete_spell
FROM um JOIN mart.dim_unit u USING (unit_id)
WHERE NOT um.is_occupied
GROUP BY um.unit_id, um.grp, u.unit_code, u.building_code, u.city, u.grade, u.unit_type, u.area_sqm,
         u.asking_rent_eur_sqm, u.benchmark_rent_eur_sqm, u.asking_vs_market;

-- 7. 2026 retention watch-list (proactive deliverable for the leasing team)
CREATE VIEW tableau.retention_watchlist AS
SELECT l.lease_id, l.tenant_id, b.building_code, u.unit_code, l.area_sqm, t.segment, t.industry,
       l.end_date, round(l.contract_rent_pa_eur) AS contract_rent_pa_eur,
       COUNT(tk.ticket_id) AS tickets_12m,
       COUNT(tk.ticket_id) FILTER (WHERE tk.sla_breach) AS sla_breaches_12m,
       CASE WHEN COUNT(tk.ticket_id) FILTER (WHERE tk.sla_breach) >= 3 THEN 'High'
            WHEN COUNT(tk.ticket_id) FILTER (WHERE tk.sla_breach) >= 1 THEN 'Medium'
            ELSE 'Low' END AS churn_risk
FROM mart.fact_lease l
JOIN mart.dim_unit u USING (unit_id)
JOIN mart.dim_building b ON b.building_id = l.building_id
JOIN mart.dim_tenant t USING (tenant_id)
LEFT JOIN mart.fact_ticket tk ON tk.lease_id = l.lease_id AND tk.created_at >= '2025-01-01'
WHERE l.outcome = 'Active' AND l.end_date BETWEEN '2026-01-01' AND '2026-12-31'
GROUP BY l.lease_id, l.tenant_id, b.building_code, u.unit_code, l.area_sqm, t.segment, t.industry,
         l.end_date, l.contract_rent_pa_eur;
