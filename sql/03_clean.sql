-- =====================================================================
-- 03_clean.sql
-- Typed, standardised and de-duplicated copies of the raw extracts.
-- Every rule applied is logged in clean.dq_log so the client can see
-- exactly what was changed and why.
-- =====================================================================
DROP SCHEMA IF EXISTS clean CASCADE;
CREATE SCHEMA clean;

CREATE TABLE clean.dq_log (
    table_name  TEXT,
    rule        TEXT,
    rows_affected BIGINT,
    logged_at   TIMESTAMP DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
-- Dates arrive as YYYY-MM-DD, DD.MM.YYYY (Bulgarian locale) or DD/MM/YYYY
CREATE FUNCTION clean.parse_date(v TEXT) RETURNS DATE
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN v IS NULL OR btrim(v) = ''              THEN NULL
        WHEN v ~ '^\d{4}-\d{2}-\d{2}'                THEN to_date(left(v, 10), 'YYYY-MM-DD')
        WHEN v ~ '^\d{2}\.\d{2}\.\d{4}$'             THEN to_date(v, 'DD.MM.YYYY')
        WHEN v ~ '^\d{2}/\d{2}/\d{4}$'               THEN to_date(v, 'DD/MM/YYYY')
    END
$$;

-- Decimal numbers sometimes use a comma as separator
CREATE FUNCTION clean.parse_num(v TEXT) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
    SELECT NULLIF(replace(btrim(v), ',', '.'), '')::NUMERIC
$$;

-- ---------------------------------------------------------------------
-- Buildings: unify city spelling and asset_type casing
-- ---------------------------------------------------------------------
CREATE TABLE clean.buildings AS
SELECT
    building_id::INT                                   AS building_id,
    building_code,
    CASE lower(btrim(city))
        WHEN 'sofiya'  THEN 'Sofia'
        WHEN 'bourgas' THEN 'Burgas'
        ELSE initcap(btrim(city))
    END                                                AS city,
    initcap(btrim(asset_type))                         AS asset_type,
    upper(btrim(grade))                                AS grade,
    year_built::INT                                    AS year_built,
    floors::INT                                        AS floors,
    clean.parse_num(gla_sqm)                           AS gla_sqm,
    clean.parse_num(book_value_eur)                    AS book_value_eur
FROM raw.buildings;

INSERT INTO clean.dq_log(table_name, rule, rows_affected)
SELECT 'buildings', 'city spelling / whitespace / casing standardised', COUNT(*)
FROM raw.buildings r JOIN clean.buildings c ON c.building_id = r.building_id::INT
WHERE r.city <> c.city;

-- ---------------------------------------------------------------------
-- Units: comma decimals, zero / negative areas, unit_type casing
-- ---------------------------------------------------------------------
CREATE TABLE clean.units AS
SELECT
    unit_id,
    building_id::INT                                   AS building_id,
    unit_code,
    floor::INT                                         AS floor,
    initcap(btrim(unit_type))                          AS unit_type,
    CASE WHEN clean.parse_num(area_sqm) <= 0 THEN NULL
         ELSE clean.parse_num(area_sqm) END            AS area_sqm,
    abs(clean.parse_num(area_sqm)) <> clean.parse_num(area_sqm)
        OR clean.parse_num(area_sqm) = 0              AS area_fixed_flag,
    clean.parse_num(asking_rent_eur_sqm)               AS asking_rent_eur_sqm
FROM raw.units;

-- Negative areas are sign errors -> take the absolute value.
UPDATE clean.units u SET area_sqm = abs(clean.parse_num(r.area_sqm))
FROM raw.units r WHERE r.unit_id = u.unit_id AND clean.parse_num(r.area_sqm) < 0;

-- Zero areas: recover the area from the unit's own invoices (rent / rent per sqm)
-- is not possible without circularity, so impute from the building median of the
-- same unit type and flag the record for the client's asset team.
UPDATE clean.units u SET area_sqm = m.med
FROM (SELECT building_id, unit_type,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY area_sqm) AS med
      FROM clean.units WHERE area_sqm IS NOT NULL GROUP BY 1, 2) m
WHERE u.area_sqm IS NULL AND m.building_id = u.building_id AND m.unit_type = u.unit_type;

INSERT INTO clean.dq_log(table_name, rule, rows_affected)
SELECT 'units', 'comma decimal separator in area_sqm', COUNT(*) FROM raw.units WHERE area_sqm LIKE '%,%'
UNION ALL
SELECT 'units', 'negative area -> absolute value', COUNT(*) FROM raw.units WHERE clean.parse_num(area_sqm) < 0
UNION ALL
SELECT 'units', 'zero area -> imputed building/type median (flagged)', COUNT(*) FROM raw.units WHERE clean.parse_num(area_sqm) = 0
UNION ALL
SELECT 'units', 'unit_type casing / trailing spaces', COUNT(*) FROM raw.units WHERE unit_type <> initcap(btrim(unit_type));

ALTER TABLE clean.units ADD PRIMARY KEY (unit_id);

-- ---------------------------------------------------------------------
-- Tenants: duplicate tenant records, blank industry, trailing spaces
-- ---------------------------------------------------------------------
CREATE TABLE clean.tenants AS
SELECT DISTINCT ON (tenant_id)
    tenant_id,
    COALESCE(NULLIF(btrim(industry), ''), 'Unknown')   AS industry,
    CASE upper(btrim(segment)) WHEN 'SME' THEN 'SME' WHEN 'MID' THEN 'Mid' WHEN 'LARGE' THEN 'Large' END AS segment,
    clean.parse_date(first_seen)                       AS first_seen
FROM raw.tenants
ORDER BY tenant_id, industry DESC;

INSERT INTO clean.dq_log(table_name, rule, rows_affected)
SELECT 'tenants', 'duplicate tenant_id removed', (SELECT COUNT(*) FROM raw.tenants) - (SELECT COUNT(*) FROM clean.tenants)
UNION ALL
SELECT 'tenants', 'blank industry -> Unknown', COUNT(*) FROM raw.tenants WHERE btrim(COALESCE(industry, '')) = '';

ALTER TABLE clean.tenants ADD PRIMARY KEY (tenant_id);

-- ---------------------------------------------------------------------
-- Leases: mixed date formats, currency labels, BGN rents -> EUR
-- (fixed peg 1 EUR = 1.95583 BGN)
-- ---------------------------------------------------------------------
CREATE TABLE clean.leases AS
SELECT
    lease_id, unit_id, tenant_id,
    lease_type,
    NULLIF(renewal_of, '')                             AS renewal_of,
    clean.parse_date(start_date)                       AS start_date,
    clean.parse_date(end_date)                         AS end_date,
    term_months::INT                                   AS term_months,
    clean.parse_date(termination_date)                 AS termination_date,
    CASE WHEN upper(btrim(currency)) = 'BGN'
         THEN round(clean.parse_num(rent_per_sqm) / 1.95583, 2)
         ELSE clean.parse_num(rent_per_sqm) END        AS rent_eur_sqm,
    rent_free_months::INT                              AS rent_free_months,
    indexation,
    CASE lower(btrim(status))
        WHEN 'active'            THEN 'Active'
        WHEN 'expired - renewed' THEN 'Expired - renewed'
        WHEN 'expired - vacated' THEN 'Expired - vacated'
        WHEN 'terminated early'  THEN 'Terminated early'
    END                                                AS status
FROM raw.leases;

INSERT INTO clean.dq_log(table_name, rule, rows_affected)
SELECT 'leases', 'non-ISO date formats parsed (DD.MM.YYYY, DD/MM/YYYY)', COUNT(*)
FROM raw.leases WHERE start_date !~ '^\d{4}-' OR end_date !~ '^\d{4}-' OR (termination_date <> '' AND termination_date !~ '^\d{4}-')
UNION ALL
SELECT 'leases', 'rent recorded in BGN converted to EUR', COUNT(*) FROM raw.leases WHERE upper(btrim(currency)) = 'BGN'
UNION ALL
SELECT 'leases', 'currency label variants (eur, €) standardised', COUNT(*) FROM raw.leases WHERE currency IN ('eur', '€')
UNION ALL
SELECT 'leases', 'status casing standardised', COUNT(*) FROM raw.leases WHERE status = upper(status);

ALTER TABLE clean.leases ADD PRIMARY KEY (lease_id);

-- ---------------------------------------------------------------------
-- Invoice lines: exact duplicates, charge_code variants, comma decimals
-- ---------------------------------------------------------------------
CREATE TABLE clean.invoice_lines AS
SELECT DISTINCT ON (line_id::BIGINT)
    line_id::BIGINT                                    AS line_id,
    invoice_id, lease_id,
    billing_month::DATE                                AS billing_month,
    upper(btrim(charge_code))                          AS charge_code,
    clean.parse_num(amount_eur)                        AS amount_eur
FROM raw.invoice_lines
ORDER BY line_id::BIGINT;

INSERT INTO clean.dq_log(table_name, rule, rows_affected)
SELECT 'invoice_lines', 'exact duplicate lines removed', (SELECT COUNT(*) FROM raw.invoice_lines) - (SELECT COUNT(*) FROM clean.invoice_lines)
UNION ALL
SELECT 'invoice_lines', 'charge_code casing / whitespace', COUNT(*) FROM raw.invoice_lines WHERE charge_code <> upper(btrim(charge_code))
UNION ALL
SELECT 'invoice_lines', 'comma decimal separator in amount', COUNT(*) FROM raw.invoice_lines WHERE amount_eur LIKE '%,%';

ALTER TABLE clean.invoice_lines ADD PRIMARY KEY (line_id);
CREATE INDEX ON clean.invoice_lines (invoice_id);
CREATE INDEX ON clean.invoice_lines (lease_id, billing_month);

-- ---------------------------------------------------------------------
-- Payments: duplicate receipts (same payment_id imported twice)
-- ---------------------------------------------------------------------
CREATE TABLE clean.payments AS
SELECT DISTINCT ON (payment_id)
    payment_id, invoice_id, tenant_id,
    payment_date::DATE                                 AS payment_date,
    clean.parse_num(amount_eur)                        AS amount_eur,
    initcap(lower(btrim(method)))                      AS method
FROM raw.payments
ORDER BY payment_id;

UPDATE clean.payments SET method = 'SEPA' WHERE method = 'Sepa';

INSERT INTO clean.dq_log(table_name, rule, rows_affected)
SELECT 'payments', 'duplicate payment records removed', (SELECT COUNT(*) FROM raw.payments) - (SELECT COUNT(*) FROM clean.payments)
UNION ALL
SELECT 'payments', 'payment method casing', COUNT(*) FROM raw.payments WHERE method = upper(method) AND method <> 'SEPA';

ALTER TABLE clean.payments ADD PRIMARY KEY (payment_id);
CREATE INDEX ON clean.payments (invoice_id);

-- ---------------------------------------------------------------------
-- Maintenance tickets: category synonyms / blanks, priority casing,
-- resolved_at earlier than created_at (bad technician timestamp)
-- ---------------------------------------------------------------------
CREATE TABLE clean.maintenance_tickets AS
SELECT
    ticket_id, unit_id, tenant_id, lease_id,
    CASE
        WHEN category IS NULL OR btrim(category) = ''        THEN 'Uncategorised'
        WHEN lower(category) IN ('hvac', 'air conditioning') THEN 'HVAC'
        WHEN lower(category) = 'it & telecom'                THEN 'IT & Telecom'
        WHEN lower(category) = 'access & security'           THEN 'Access & Security'
        WHEN lower(category) = 'fit-out / carpentry'         THEN 'Fit-out / Carpentry'
        ELSE initcap(category)
    END                                                AS category,
    initcap(lower(priority))                           AS priority,
    created_at::TIMESTAMP                              AS created_at,
    CASE WHEN NULLIF(resolved_at, '')::TIMESTAMP < created_at::TIMESTAMP THEN NULL
         ELSE NULLIF(resolved_at, '')::TIMESTAMP END   AS resolved_at,
    (NULLIF(resolved_at, '')::TIMESTAMP < created_at::TIMESTAMP) IS TRUE AS bad_timestamp_flag,
    status,
    reopened::BOOLEAN                                  AS reopened,
    NULLIF(satisfaction, '')::INT                      AS satisfaction
FROM raw.maintenance_tickets;

INSERT INTO clean.dq_log(table_name, rule, rows_affected)
SELECT 'maintenance_tickets', 'blank category -> Uncategorised', COUNT(*) FROM raw.maintenance_tickets WHERE category IS NULL OR btrim(category) = ''
UNION ALL
SELECT 'maintenance_tickets', 'category synonyms / casing (e.g. Air conditioning -> HVAC)', COUNT(*)
FROM raw.maintenance_tickets WHERE category IS NOT NULL AND (category = 'Air conditioning' OR category = lower(category))
UNION ALL
SELECT 'maintenance_tickets', 'priority casing', COUNT(*) FROM raw.maintenance_tickets WHERE priority = upper(priority)
UNION ALL
SELECT 'maintenance_tickets', 'resolved_at before created_at -> set NULL (excluded from SLA)', COUNT(*)
FROM clean.maintenance_tickets WHERE bad_timestamp_flag;

ALTER TABLE clean.maintenance_tickets ADD PRIMARY KEY (ticket_id);

-- ---------------------------------------------------------------------
-- Market benchmark (reference data, already clean)
-- ---------------------------------------------------------------------
CREATE TABLE clean.market_rent_benchmark AS
SELECT unit_type, city, grade, benchmark_rent_eur_sqm::NUMERIC AS benchmark_rent_eur_sqm, source
FROM raw.market_rent_benchmark;

SELECT table_name, rule, rows_affected FROM clean.dq_log ORDER BY table_name, rule;
