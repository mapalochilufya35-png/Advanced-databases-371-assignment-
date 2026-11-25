-- =====================================================================
-- ICT371 Advanced Database - Question 7: Water Meter Readings and Billing
-- Student Number: <YOUR NUMBER>      Student Name: <YOUR NAME>
-- DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Safe to re-run: it drops and rebuilds everything.
-- Tariff: first 10 units K5 each, units above 10 K8 each, zero units = K0.
-- =====================================================================

DROP VIEW  IF EXISTS v_overdue_bills;
DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INT           NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT ck_reading_month_first CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INT           NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(10,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(10,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------
-- (d) Trigger: reject current_reading < previous_reading
-- Installed before the seed data so even direct SQL imports are checked.
-- An exception aborts the statement, so the bad row is never stored.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_check_reading()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading (%) cannot be below previous reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_reading ON readings;
CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_reading();

INSERT INTO customers (full_name) VALUES
    ('Ruth Mukuka'), ('Samuel Nkonde'), ('Tabitha Yamba');

-- Six readings: zero units, exactly 10 units, and above 10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100.00, 100.00),   -- 0 units    -> K0
    (1, DATE '2026-10-01', 100.00, 110.00),   -- 10 units   -> K50
    (2, DATE '2026-09-01',  50.00,  65.00),   -- 15 units   -> 50 + 5*8   = K90
    (2, DATE '2026-10-01',  65.00,  70.00),   -- 5 units    -> K25
    (3, DATE '2026-09-01', 200.00, 212.50),   -- 12.5 units -> 50 + 2.5*8 = K70
    (3, DATE '2026-10-01', 212.50, 230.00);   -- 17.5 units -> 50 + 7.5*8 = K110

-- Invalid readings must be rejected and not stored
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, DATE '2026-11-01', 110, 100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN UPDATE readings SET current_reading = 1 WHERE reading_id = 2;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_should_still_be_6 FROM readings;

-- ---------------------------------------------------------------------
-- (b) Function: fn_water_charge
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(10,2) AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: % (must not be NULL or negative)', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;

    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_generate_bill
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev  NUMERIC;
    v_curr  NUMERIC;
    v_units NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_units := v_curr - v_prev;          -- derived consumption

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END;
$$;

-- Generate bills: September bills are already past due, October bills are not yet due
CALL pr_generate_bill(1, CURRENT_DATE - 30);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(5, CURRENT_DATE - 30);
CALL pr_generate_bill(2, CURRENT_DATE + 15);
CALL pr_generate_bill(4, CURRENT_DATE + 15);
CALL pr_generate_bill(6, CURRENT_DATE + 15);

-- Payments: reading 3 part-paid, reading 5 fully paid
UPDATE bills SET amount_paid = 40 WHERE reading_id = 3;                 -- K90 charge, K50 outstanding
UPDATE bills SET amount_paid = charge WHERE reading_id = 5;             -- settled

-- Tests
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- already billed
DO $$ BEGIN CALL pr_generate_bill(99, CURRENT_DATE); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- unknown
DO $$ BEGIN PERFORM fn_water_charge(NULL);           EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);             EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT fn_water_charge(0) AS u0, fn_water_charge(10) AS u10, fn_water_charge(15) AS u15, fn_water_charge(12.5) AS u12_5;

SELECT b.bill_id, b.reading_id, b.charge, b.amount_paid, b.due_on FROM bills b ORDER BY b.bill_id;

-- ---------------------------------------------------------------------
-- (e) View: overdue, not fully paid bills
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on, full_name;   -- only the part-paid K50 bill (zero-charge bill is "fully paid")

-- ---------------------------------------------------------------------
-- (f) Index for date-based searches on overdue (unpaid) bills
-- PARTIAL index: it contains only bills that are not fully paid, keyed by
-- due_on. "due_on < today" becomes a range scan over a small, shrinking
-- set, and paid bills (the majority over time) are not indexed at all.
-- ---------------------------------------------------------------------
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;   -- tiny tables: force the planner to show the index
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: today's total of unpaid balances, replaced on rerun
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;      -- replace, never add
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();     -- rerun: same single row for today
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;   -- 50 (reading 2) + 50 (reading 3) + 25 + 110 = K235

-- Daily at 00:30 (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_receivables_daily',
    '30 0 * * *',
    $cron$CALL pr_refresh_receivables()$cron$
);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_receivables_daily';
