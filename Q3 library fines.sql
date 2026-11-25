-- =====================================================================
-- ICT371 Advanced Database - Question 3: Library Returns and Overdue Fines
-- Student Number: <YOUR NUMBER>      Student Name: <YOUR NAME>
-- DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Safe to re-run: it drops and rebuilds everything.
-- =====================================================================

DROP VIEW  IF EXISTS v_overdue_loans;
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT           NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE          NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INT       NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE      NULL,
    new_returned_on  DATE      NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT           NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Operating System Concepts');

-- Six loans, all inserted OPEN. Two are returned later through the procedure
-- (after the trigger exists) so the audit trail is shown working.
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Mary Banda',    CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open OVERDUE (16 days late)
    (2, 'John Tembo',    CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- 2 open, ON TIME
    (3, 'Peter Mumba',   CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 3 will be RETURNED late
    (1, 'Grace Lungu',   CURRENT_DATE - 10, CURRENT_DATE + 4),   -- 4 open, on time
    (2, 'Chola Mwale',   CURRENT_DATE - 12, CURRENT_DATE - 2),   -- 5 open OVERDUE (2 days late)
    (3, 'Mutale Chanda', CURRENT_DATE - 40, CURRENT_DATE - 26);  -- 6 will be RETURNED on due date

-- ---------------------------------------------------------------------
-- (b) Function: fn_loan_fine
-- fine = K2 * days late; never below zero; stops counting at return date.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- earlier of p_as_of and returned_on (if there is a return date)
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    -- date - date = integer days; GREATEST gives the minimum of zero
    RETURN 2 * GREATEST(v_end - v_due, 0);
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_return_loan
-- Return date and final fine are stored in ONE UPDATE statement.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before the borrowed date %', p_returned_on, v_borrowed;
    END IF;

    -- Final fine is calculated as at the return date itself
    v_fine := 2 * GREATEST(p_returned_on - (SELECT due_on FROM loans WHERE loan_id = p_loan_id), 0);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: log changes of returned_on (OLD vs NEW)
-- The WHEN clause plus the IF both ensure no row when the date is unchanged.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_loan_audit ON loans;
CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- Returned loans (through the procedure)
CALL pr_return_loan(3, CURRENT_DATE - 3);    -- due 6 days ago, returned 3 days ago -> 3 days late -> K6
CALL pr_return_loan(6, CURRENT_DATE - 26);   -- returned exactly on the due date -> K0

-- Tests
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- already returned
DO $$ BEGIN CALL pr_return_loan(99, CURRENT_DATE);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- unknown
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 60); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$; -- before borrowed_on

-- An UPDATE that does not change returned_on creates NO audit row
UPDATE loans SET borrower_name = borrower_name WHERE loan_id = 3;

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;       -- exactly 2 rows (loans 3 and 6)
SELECT fn_loan_fine(1, CURRENT_DATE) AS fine_loan_1_today,   -- 32
       fn_loan_fine(2, CURRENT_DATE) AS fine_loan_2_today,   -- 0
       fn_loan_fine(3, CURRENT_DATE) AS fine_loan_3_today,   -- 6 (stops at return date)
       fn_loan_fine(5, CURRENT_DATE) AS fine_loan_5_today;   -- 4

-- ---------------------------------------------------------------------
-- (e) View: loans unreturned and due before today, with fine as of today
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY loan_id;     -- loans 1 and 5 only

-- ---------------------------------------------------------------------
-- (f) Index for "a given book's unreturned loans"
-- A PARTIAL index only contains open loans (returned_on IS NULL), so it
-- stays small as returned loans pile up, and it matches the query exactly.
-- ---------------------------------------------------------------------
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;   -- tiny tables: force the planner to show the index
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job
-- "Unreturned as of p_as_of": borrowed on/before that date and either never
-- returned, or returned AFTER that date. Fines are calculated as of that date.
-- The UPSERT replaces the row for the same snapshot_date on a rerun.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(l.loan_id, p_as_of)), 0)
    FROM loans l
    WHERE l.borrowed_on <= p_as_of
      AND (l.returned_on IS NULL OR l.returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);     -- rerun: same single row, same values
SELECT * FROM overdue_summary ORDER BY snapshot_date;

-- Daily at 00:10 for CURRENT_DATE (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_overdue_daily',
    '10 0 * * *',
    $cron$CALL pr_refresh_overdue(CURRENT_DATE)$cron$
);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_overdue_daily';
