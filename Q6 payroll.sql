-- =====================================================================
-- ICT371 Advanced Database - Question 6: Monthly Payroll Processing
-- Student Number: <YOUR NUMBER>      Student Name: <YOUR NAME>
-- DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Safe to re-run: it drops and rebuilds everything.
-- =====================================================================

DROP VIEW  IF EXISTS v_payroll_report;
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance    >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction    >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    -- pay_month must be the first day of a month
    CONSTRAINT ck_pay_month_first_day CHECK (EXTRACT(DAY FROM pay_month) = 1),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INT           NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- (d) Trigger: log an actual basic_salary change (OLD vs NEW)
-- Installed before seeding so every change is covered.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_salary_audit ON employees;
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- Employees: four active and one inactive from the start
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Anna Mwila',      8000.00, 1500.00, 1200.00, TRUE),
    ('Boniface Zimba',  6500.00, 1000.00,  900.00, TRUE),
    ('Catherine Lupiya',7200.00,  800.00, 1000.00, TRUE),
    ('Dennis Chisanga', 5000.00,  500.00,  700.00, TRUE),    -- becomes inactive later
    ('Eliza Mapulanga', 4000.00,  300.00,  500.00, FALSE);   -- inactive from the start

-- ---------------------------------------------------------------------
-- (b) Function: fn_net_pay
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC AS $$
DECLARE
    v_basic NUMERIC;
    v_allow NUMERIC;
    v_ded   NUMERIC;
    v_net   NUMERIC;
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allow, v_ded
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allow) - v_ded;      -- gross minus fixed deduction
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_process_payroll (query FOR loop)
-- All-or-nothing: if fn_net_pay raises for any employee, the whole CALL
-- is rolled back, so no partial payroll run is left behind.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    r       RECORD;
    v_net   NUMERIC;
    v_gross NUMERIC;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Month must be a month-start date (first day of the month), got %', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id
    LOOP
        v_net   := fn_net_pay(r.employee_id);          -- raises on an invalid calculation
        v_gross := r.basic_salary + r.allowance;

        -- Missing row is inserted; an existing employee/month row is left unchanged
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- Two payroll months (active employees only)
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- Dennis leaves: his historical payroll rows must remain
UPDATE employees SET active = FALSE WHERE employee_id = 4;
CALL pr_process_payroll(DATE '2026-10-01');            -- rerun: nothing duplicated or changed
CALL pr_process_payroll(DATE '2026-11-01');            -- Dennis and Eliza are skipped

-- Invalid calls
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-12-15'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- not month-start
DO $$ BEGIN CALL pr_process_payroll(NULL);              EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- Whole-call failure: make a deduction bigger than gross, run, and confirm nothing was inserted
UPDATE employees SET deduction = 99999 WHERE employee_id = 2;
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-12-01'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS december_rows_should_be_zero FROM payroll WHERE pay_month = DATE '2026-12-01';
UPDATE employees SET deduction = 900 WHERE employee_id = 2;      -- restore

SELECT fn_net_pay(1) AS anna_net;   -- 8000 + 1500 - 1200 = 8300
DO $$ BEGIN PERFORM fn_net_pay(99); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Trigger demonstration
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- logs one audit row
UPDATE employees SET allowance = 1600   WHERE employee_id = 1;    -- salary unchanged: NO audit row
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- same value again: NO audit row
SELECT * FROM salary_audit ORDER BY audit_id;                      -- exactly 1 row (8000 -> 8500)

-- ---------------------------------------------------------------------
-- (e) View: payroll joined to employee names (inner join on employees,
-- NOT filtered by active, so ex-employees' history stays visible)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;   -- Dennis appears for Sep and Oct

-- ---------------------------------------------------------------------
-- (f) Index for "all employees for one pay_month"
-- The existing UNIQUE (employee_id, pay_month) index starts with
-- employee_id, so it cannot efficiently find rows by pay_month alone.
-- This index is on pay_month only, so it does NOT duplicate that one.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = off;   -- tiny tables: force the planner to show the index
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: 02:00 on the 1st of every month, for the PREVIOUS month
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'process_payroll_monthly',
    '0 2 1 * *',
    $cron$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$cron$
);

-- Inspect the job definition
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'process_payroll_monthly';

-- Inspect the run history (status, message, start/end time)
SELECT d.runid, d.jobid, j.jobname, d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobname = 'process_payroll_monthly'
ORDER BY d.start_time DESC
LIMIT 20;

-- To remove the job if needed:
-- SELECT cron.unschedule('process_payroll_monthly');
