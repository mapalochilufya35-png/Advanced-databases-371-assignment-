-- =====================================================================
-- ICT371 Advanced Database - Question 4: Clinic Appointment Scheduling
-- Student Number: <YOUR NUMBER>      Student Name: <YOUR NAME>
-- DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Safe to re-run: it drops and rebuilds everything.
-- =====================================================================

DROP VIEW  IF EXISTS v_today_appointments;
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INT         NOT NULL REFERENCES patients(patient_id),
    doctor_id       INT         NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
    CONSTRAINT ck_slot   CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL DEFAULT 0,
    attended_count  INT NOT NULL DEFAULT 0,
    cancelled_count INT NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES
    ('Esther Kapambwe'), ('Francis Sakala'), ('Hope Mulenga');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Ngoma'), ('Dr. Siwale'), ('Dr. Kasonde');

-- ---------------------------------------------------------------------
-- (d) Trigger (created BEFORE the seed rows so they are checked too)
-- Rejects a clash with another NON-cancelled appointment for the same
-- doctor + date + slot. On UPDATE the row being changed is excluded.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_appointment_clash()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        -- Serialise bookings per doctor so two sessions cannot both pass the check
        PERFORM 1 FROM doctors WHERE doctor_id = NEW.doctor_id FOR UPDATE;

        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              AND a.appointment_id IS DISTINCT FROM NEW.appointment_id  -- exclude the row being changed
        ) THEN
            RAISE EXCEPTION 'Clash: doctor % already has an appointment on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_appointment_clash ON appointments;
CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointment_clash();

-- Six appointments (no slot-rule violations)
-- Note: the CANCELLED row shares doctor/day/slot with a later ATTENDED row - allowed,
-- because cancelled appointments do not occupy the slot.
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE - 1, '11:00', 'ATTENDED'),
    (2, 3, CURRENT_DATE - 1, '09:00', 'CANCELLED'),
    (3, 3, CURRENT_DATE - 1, '09:00', 'ATTENDED');

-- ---------------------------------------------------------------------
-- (b) Function: fn_daily_load
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT AS $$
DECLARE
    v_count INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count          -- COUNT(*) returns 0 when no rows match
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_book_appointment
-- The clash rule itself is enforced by the trigger in (d).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT,
    p_doctor_id  INT,
    p_day        DATE,
    p_slot       TIME)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or NULL', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- Tests
CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, '12:00');     -- valid
DO $$ BEGIN CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, '12:00'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- clash (trigger)
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- past date
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- bad slot
DO $$ BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, '09:00'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$; -- unknown patient

-- UPDATE test: moving an appointment onto an occupied slot is rejected,
-- while updating a row without changing its slot is NOT treated as a clash with itself.
DO $$ BEGIN UPDATE appointments SET slot_time = '10:00' WHERE appointment_id = 1;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;     -- clashes with appointment 2
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 1;          -- allowed

SELECT * FROM appointments ORDER BY appointment_id;
SELECT fn_daily_load(1, CURRENT_DATE) AS dr_ngoma_today,        -- 2
       fn_daily_load(3, CURRENT_DATE) AS dr_kasonde_today;      -- 0 (no bookings -> zero)

-- ---------------------------------------------------------------------
-- (e) View: today's BOOKED appointments (no patient_id, no other patient data)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time, doctor_name;

-- ---------------------------------------------------------------------
-- (f) Non-unique index
-- Justification: lookups are "this day for this doctor". Both columns are
-- tested with equality, so the composite (appointment_day, doctor_id) lets
-- PostgreSQL go straight to the matching entries. It is NOT unique because
-- one doctor legitimately has several appointments on the same day.
-- ---------------------------------------------------------------------
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;   -- tiny tables: force the planner to show the index
EXPLAIN
SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;     -- replace on rerun
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun replaces the row
SELECT * FROM clinic_summary ORDER BY summary_date;  -- yesterday: 0 booked, 2 attended, 1 cancelled

-- Daily at 01:00 for the previous day (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_clinic_summary_daily',
    '0 1 * * *',
    $cron$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$cron$
);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_clinic_summary_daily';
