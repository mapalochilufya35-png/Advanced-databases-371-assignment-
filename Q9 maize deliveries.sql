-- =====================================================================
-- ICT371 Advanced Database - Question 9: Farmer Cooperative Maize Deliveries
-- Student Number: <YOUR NUMBER>      Student Name: <YOUR NAME>
-- DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Safe to re-run: it drops and rebuilds everything.
-- Rates: grade A = K5/kg, grade B = K4/kg, grade C = K3/kg.
-- =====================================================================

DROP VIEW  IF EXISTS v_farmer_amount_due;
DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- ---------------------------------------------------------------------
-- (a) Database
-- ---------------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INT           NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,            -- filled in by the trigger
    total_value  NUMERIC(12,2) NOT NULL,            -- filled in by the trigger
    delivered_on DATE          NOT NULL DEFAULT CURRENT_DATE,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Joseph Mwamba'),
    ('F002', 'Memory Chibwe'),
    ('F003', 'Patrick Sinkala');

-- ---------------------------------------------------------------------
-- (b) Function: fn_maize_rate
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    CASE p_grade
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END CASE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ---------------------------------------------------------------------
-- (d) Trigger: one pricing rule for every insert/update, including direct SQL
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_price_delivery()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);              -- also rejects NULL/unsupported grade
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_price_delivery ON deliveries;
CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_receive_delivery
-- Inserts only the basic fields with is_paid = FALSE; the trigger prices it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INT,
    p_grade     VARCHAR,
    p_weight    NUMERIC,
    p_date      DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid grade: %', p_grade;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight: %', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date must not be NULL';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- (a, continued) Six deliveries, loaded AFTER the trigger exists.
-- unit_rate and total_value are NOT supplied: the trigger calculates them.
-- All three grades and both payment states are covered.
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 100.00, CURRENT_DATE - 2, FALSE),   -- K500 unpaid
    (1, 'B',  80.50, CURRENT_DATE - 2, TRUE),    -- K322 paid
    (2, 'C', 200.00, CURRENT_DATE - 1, FALSE),   -- K600 unpaid
    (2, 'A',  50.00, CURRENT_DATE - 1, TRUE),    -- K250 paid
    (2, 'B',  75.25, CURRENT_DATE - 1, FALSE),   -- K301 unpaid
    (3, 'C', 120.00, CURRENT_DATE - 1, TRUE);    -- K360 paid (farmer 3 owes nothing)

-- Through the procedure as well
CALL pr_receive_delivery(3, 'A', 60, CURRENT_DATE);     -- K300 unpaid

-- Tests
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- unknown farmer
DO $$ BEGIN CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- bad grade
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- bad weight
DO $$ BEGIN PERFORM fn_maize_rate(NULL);                          EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on) VALUES (1, 'A', -5, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct SQL): %', SQLERRM; END $$;

-- Direct SQL that tries to set its own price: the trigger overrides it
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (1, 'C', 10, 99, 9999, CURRENT_DATE, TRUE);                 -- stored as rate 3, value 30
-- Changing weight/grade by UPDATE re-prices the row
UPDATE deliveries SET weight_kg = 20 WHERE delivery_id = (SELECT MAX(delivery_id) FROM deliveries);  -- value becomes 60
SELECT * FROM deliveries ORDER BY delivery_id;

-- ---------------------------------------------------------------------
-- (e) View: unpaid value per farmer (farmers with none show 0)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0) AS total_unpaid_value
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- Farmer with no unpaid deliveries shows zero (demonstration)
UPDATE deliveries SET is_paid = TRUE WHERE farmer_id = 3;
SELECT * FROM v_farmer_amount_due WHERE farmer_number = 'F003';   -- 0.00

-- ---------------------------------------------------------------------
-- (f) Composite index: a farmer's deliveries between two dates
-- Equality column (farmer_id) first, range column (delivered_on) second,
-- so one farmer's rows are read as a single contiguous, date-ordered slice.
-- ---------------------------------------------------------------------
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;   -- tiny tables: force the planner to show the index
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 2
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: totals are recalculated from deliveries and REPLACE
-- the stored row, so repeated runs never double-count.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);    -- rerun: same values, not doubled
SELECT * FROM daily_purchases ORDER BY purchase_date;   -- 445.25 kg, K1511 for yesterday

-- Daily at 01:30 for the previous day (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_purchases_daily',
    '30 1 * * *',
    $cron$CALL pr_refresh_purchases(CURRENT_DATE - 1)$cron$
);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_purchases_daily';
