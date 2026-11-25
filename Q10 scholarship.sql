-- =====================================================================
-- ICT371 Advanced Database - Question 10: Scholarship Application Assessment
-- Student Number: <YOUR NUMBER>      Student Name: <YOUR NAME>
-- DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Safe to re-run: it drops and rebuilds everything.
-- Eligibility: age 18-25 inclusive AND monthly income <= K3,000 AND average mark >= 70.
-- =====================================================================

DROP VIEW  IF EXISTS v_approved_applicants;
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INT           NOT NULL REFERENCES students(student_id),
    age_at_application INT           NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT         NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('SC001', 'Mercy Kalaba'),
    ('SC002', 'Kelvin Mwenya'),
    ('SC003', 'Naomi Chibuye');

-- Six PENDING applications: qualifying, non-qualifying and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 22, 2500.00, 75.00, CURRENT_DATE - 10, 'PENDING'),   -- 1 clearly qualifies
    (2, 18, 3000.00, 70.00, CURRENT_DATE -  9, 'PENDING'),   -- 2 boundary: min age, max income, min mark -> qualifies
    (3, 25, 1000.00, 90.00, CURRENT_DATE -  8, 'PENDING'),   -- 3 boundary: max age -> qualifies
    (1, 17,  500.00, 80.00, CURRENT_DATE -  7, 'PENDING'),   -- 4 too young -> rejected
    (2, 20, 3000.01, 85.00, CURRENT_DATE -  6, 'PENDING'),   -- 5 income just above K3,000 -> rejected
    (3, 21, 1500.00, 69.99, CURRENT_DATE -  5, 'PENDING');   -- 6 mark just below 70 -> rejected

-- ---------------------------------------------------------------------
-- (b) Function: fn_scholarship_eligible
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark   >= 70;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_assess_application
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_app applications%ROWTYPE;
BEGIN
    -- FOR UPDATE: two sessions cannot assess the same application at once
    SELECT * INTO v_app
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;
    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)',
                        p_application_id, v_app.status;
    END IF;

    UPDATE applications
    SET status = CASE
                    WHEN fn_scholarship_eligible(v_app.age_at_application,
                                                 v_app.monthly_income,
                                                 v_app.average_mark)
                    THEN 'APPROVED' ELSE 'REJECTED'
                 END
    WHERE application_id = p_application_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: audit actual status changes (OLD vs NEW)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (OLD.application_id, OLD.status, NEW.status, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_decision_audit ON applications;
CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- ---------------------------------------------------------------------
-- Function and procedure tests
-- ---------------------------------------------------------------------
SELECT fn_scholarship_eligible(18, 3000, 70)   AS lower_boundary_true,
       fn_scholarship_eligible(25, 3000, 70)   AS upper_age_true,
       fn_scholarship_eligible(26, 1000, 90)   AS age_26_false,
       fn_scholarship_eligible(20, 3000.01, 90) AS income_over_false,
       fn_scholarship_eligible(20, 1000, 69.99) AS mark_under_false;

DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1, 1);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 50);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 100, 50);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_assess_application(1);                                  -- PENDING -> APPROVED
DO $$ BEGIN CALL pr_assess_application(1);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- already assessed
DO $$ BEGIN CALL pr_assess_application(99); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- unknown

-- An UPDATE that does not change status creates NO audit entry
UPDATE applications SET average_mark = average_mark WHERE application_id = 1;
SELECT * FROM decision_audit ORDER BY audit_id;                 -- exactly 1 row (application 1)

-- ---------------------------------------------------------------------
-- (g) Procedure: pr_assess_pending (query FOR loop, PENDING rows only)
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'          -- completed applications are never touched
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();     -- assesses applications 2..6
CALL pr_assess_pending();     -- rerun: no PENDING rows left, so nothing changes

SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;
-- expected: 1,2,3 APPROVED; 4,5,6 REJECTED
SELECT * FROM decision_audit ORDER BY audit_id;     -- exactly 6 rows, no duplicates

-- ---------------------------------------------------------------------
-- (e) View: approved applicants only, income omitted
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants ORDER BY student_number;

-- ---------------------------------------------------------------------
-- (f) Index: status within a submitted_on date range
-- Equality column (status) first, range column (submitted_on) second, so
-- "all PENDING applications from date X to Y" is one contiguous index slice.
-- ---------------------------------------------------------------------
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;   -- tiny tables: force the planner to show the index
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'APPROVED'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g, continued) Schedule every Monday at 08:00 (requires pg_cron)
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'assess_pending_weekly',
    '0 8 * * 1',
    $cron$CALL pr_assess_pending()$cron$
);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'assess_pending_weekly';
