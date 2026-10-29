-- =====================================================================
-- 01_raw_schema.sql
-- Landing zone: every column as TEXT, exactly as exported from the
-- client's ERP (billing, receipts) and CAFM (maintenance) systems.
-- Nothing is cast here so that a bad value never blocks the load.
-- =====================================================================
DROP SCHEMA IF EXISTS raw CASCADE;
CREATE SCHEMA raw;

CREATE TABLE raw.buildings (
    building_id     TEXT, building_code TEXT, city TEXT, asset_type TEXT, grade TEXT,
    year_built      TEXT, floors TEXT, gla_sqm TEXT, book_value_eur TEXT
);

CREATE TABLE raw.units (
    unit_id TEXT, building_id TEXT, unit_code TEXT, floor TEXT, unit_type TEXT,
    area_sqm TEXT, asking_rent_eur_sqm TEXT
);

CREATE TABLE raw.tenants (
    tenant_id TEXT, industry TEXT, segment TEXT, first_seen TEXT
);

CREATE TABLE raw.leases (
    lease_id TEXT, unit_id TEXT, tenant_id TEXT, lease_type TEXT, renewal_of TEXT,
    start_date TEXT, end_date TEXT, term_months TEXT, termination_date TEXT,
    rent_per_sqm TEXT, currency TEXT, rent_free_months TEXT, indexation TEXT, status TEXT
);

CREATE TABLE raw.invoice_lines (
    line_id TEXT, invoice_id TEXT, lease_id TEXT, billing_month TEXT,
    charge_code TEXT, amount_eur TEXT
);

CREATE TABLE raw.payments (
    payment_id TEXT, invoice_id TEXT, tenant_id TEXT, payment_date TEXT,
    amount_eur TEXT, method TEXT
);

CREATE TABLE raw.maintenance_tickets (
    ticket_id TEXT, unit_id TEXT, tenant_id TEXT, lease_id TEXT, category TEXT,
    priority TEXT, created_at TEXT, resolved_at TEXT, status TEXT,
    reopened TEXT, satisfaction TEXT
);

-- External reference: broker market-rent benchmark (Q4-2025)
CREATE TABLE raw.market_rent_benchmark (
    unit_type TEXT, city TEXT, grade TEXT, benchmark_rent_eur_sqm TEXT, source TEXT
);
