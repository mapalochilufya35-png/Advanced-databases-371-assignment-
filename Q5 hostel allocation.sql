-- =====================================================================
-- ICT371 Advanced Database - Question 5: Hostel Room Allocation
-- Student Number: <YOUR NUMBER>      Student Name: <YOUR NAME>
-- DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Safe to re-run: it drops and rebuilds everything.
-- =====================================================================

DROP VIEW  IF EXISTS v_room_occupancy;
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INT         NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INT         NOT NULL REFERENCES students(student_id),
    room_id       INT         NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    -- ACTIVE requires released_on NULL; ENDED requires a release date
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT  NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT  NOT NULL,
    free_beds     INT  NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- Extra safety net (race conditions): one ACTIVE allocation per student, enforced by the engine
CREATE UNIQUE INDEX uq_one_active_per_student ON allocations (student_id) WHERE status = 'ACTIVE';

INSERT INTO students (student_number, full_name) VALUES
    ('H001', 'Agnes Mutale'),
    ('H002', 'Brian Kunda'),
    ('H003', 'Cynthia Musonda'),
    ('H004', 'David Simfukwe'),
    ('H005', 'Evelyn Chilufya'),
    ('H006', 'Felix Bwalya');         -- never allocated

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),    -- will be FULL
    ('R102', 3),    -- will be PARTLY occupied
    ('R103', 2);    -- will be EMPTY (history only)

-- ---------------------------------------------------------------------
-- (b) Function: fn_free_beds
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT AS $$
DECLARE
    v_capacity INT;
    v_active   INT;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active           -- ENDED rows are not counted
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- (d) Trigger: enforce capacity and one ACTIVE allocation per student
-- for ANY insert/update, including direct SQL.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER AS $$
DECLARE
    v_capacity INT;
    v_others   INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- Lock the room row so concurrent allocations are checked one at a time
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        -- One ACTIVE allocation per student (exclude the row being updated)
        IF EXISTS (
            SELECT 1 FROM allocations a
            WHERE a.student_id = NEW.student_id
              AND a.status = 'ACTIVE'
              AND a.allocation_id IS DISTINCT FROM NEW.allocation_id
        ) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        -- Capacity: other ACTIVE allocations in this room (exclude the row being updated)
        SELECT COUNT(*) INTO v_others
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND a.allocation_id IS DISTINCT FROM NEW.allocation_id;

        IF v_others >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_allocation_rules ON allocations;
CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_allocate_room
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INT,
    p_room_id      INT,
    p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date must not be NULL';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- Seed allocations
-- R101 full (2/2), R102 partly (2/3), R103 empty (only history)
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 28);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);
CALL pr_allocate_room(5, 2, CURRENT_DATE - 15);

-- History: David lived in R103 before and left (ENDED, does not occupy a bed)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 40, 'ENDED');

-- Tests: every one of these must be rejected
DO $$ BEGIN CALL pr_allocate_room(6, 1, CURRENT_DATE);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- room full
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- already active
DO $$ BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- unknown student
DO $$ BEGIN CALL pr_allocate_room(6, 99, CURRENT_DATE); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- unknown room
-- Direct SQL must be caught by the trigger too
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (6, 1, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct SQL): %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (1, 3, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct SQL): %', SQLERRM; END $$;

-- An UPDATE that must not count the row against itself
UPDATE allocations SET allocated_on = allocated_on + 0 WHERE allocation_id = 1;   -- OK: row excluded from its own count

SELECT * FROM allocations ORDER BY allocation_id;
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;

-- ---------------------------------------------------------------------
-- (e) View: every room, including rooms with no allocations
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id
      AND a.status = 'ACTIVE'               -- condition in ON keeps rooms with no active rows
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- ---------------------------------------------------------------------
-- (f) Index for ACTIVE allocations by room
-- A PARTIAL index holds only ACTIVE rows, so ENDED history never bloats it
-- and the capacity check in the function/trigger reads only live data.
-- ---------------------------------------------------------------------
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = off;   -- tiny tables: force the planner to show the index
EXPLAIN
SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: one row per (date, room); rerun replaces values
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- rerun: still one row per room for today
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;

-- Daily at 23:55 (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_occupancy_daily',
    '55 23 * * *',
    $cron$CALL pr_refresh_occupancy()$cron$
);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_occupancy_daily';
