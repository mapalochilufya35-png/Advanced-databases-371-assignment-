-- =====================================================================
-- ICT371 Advanced Database - Question 1: Pharmacy Stock and Daily Sales
-- Student Number: <YOUR NUMBER>      Student Name: <YOUR NAME>
-- DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Safe to re-run: it drops and rebuilds everything.
-- =====================================================================

DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;
DROP VIEW  IF EXISTS v_low_stock;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INT           NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INT           NOT NULL REFERENCES medicines(medicine_id),
    quantity    INT           NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INT       NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INT       NOT NULL,
    new_qty     INT       NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INT           NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Seed medicines (three)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 50),
    ('Amoxicillin 250mg', 8.00, 30),
    ('Ibuprofen 200mg',   3.75, 12);

-- ---------------------------------------------------------------------
-- (b) Function: fn_sale_value
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC AS $$
DECLARE
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_record_sale
-- One CALL = one transaction. Any RAISE rolls back everything, so an
-- invalid sale leaves medicines and sales unchanged.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity    INT,
    p_sold_on     DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    -- Lock the row so two concurrent sales cannot oversell
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: available %, requested %',
                        p_medicine_id, v_stock, p_quantity;
    END IF;

    -- Store the CURRENT price in the sale
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- Deduct stock exactly once
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: audit stock changes (only when stock_qty really changes)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_stock_audit ON medicines;
CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_stock_audit();

-- ---------------------------------------------------------------------
-- (a, continued) Six valid sales loaded THROUGH the procedure
-- ---------------------------------------------------------------------
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(2, 10, CURRENT_DATE - 1);
CALL pr_record_sale(3,  5, CURRENT_DATE - 1);
CALL pr_record_sale(1,  5, CURRENT_DATE);
CALL pr_record_sale(2,  8, CURRENT_DATE);
CALL pr_record_sale(3,  4, CURRENT_DATE);

-- Invalid sales must change nothing
DO $$
BEGIN
    CALL pr_record_sale(3, 999);          -- more than stock
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;

DO $$
BEGIN
    CALL pr_record_sale(99, 1);           -- unknown medicine
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;       -- exactly 6 rows
SELECT * FROM stock_audit ORDER BY audit_id; -- exactly 6 rows (one per stock change)
SELECT fn_sale_value(2, 3) AS value_of_3_amoxicillin;  -- 24.00

-- ---------------------------------------------------------------------
-- (e) View: v_low_stock (stock below 10)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id,
       medicine_name,
       unit_price,
       stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- Query the view after a sale
CALL pr_record_sale(2, 10, CURRENT_DATE);   -- Amoxicillin: 12 -> 2
SELECT * FROM v_low_stock ORDER BY medicine_id;  -- Ibuprofen (3) and Amoxicillin (2)

-- ---------------------------------------------------------------------
-- (f) Index
-- Justification: the query filters on ONE medicine (equality) and a
-- sold_on RANGE. A composite index (medicine_id, sold_on) puts the
-- equality column first, then the range column, so PostgreSQL jumps to
-- that medicine's section of the B-tree and reads only the matching
-- date range, already sorted. Without it, the whole sales table is scanned.
-- ---------------------------------------------------------------------
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

SET enable_seqscan = off;   -- the tables are tiny; this just forces the planner to show the index
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job
-- Replacing (not adding) makes reruns safe: the UPSERT overwrites the
-- row for that day with totals recalculated from the sales table.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);   -- rerun: still ONE row, same totals
SELECT * FROM daily_sales ORDER BY sales_date;

-- Schedule daily at 00:15 for the previous day (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_sales_daily',
    '15 0 * * *',
    $cron$CALL pr_refresh_sales(CURRENT_DATE - 1)$cron$
);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_sales_daily';
