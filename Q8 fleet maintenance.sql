-- =====================================================================
-- ICT371 Advanced Database - Question 8: Transport Fleet Maintenance
-- Student Number: <YOUR NUMBER>      Student Name: <YOUR NAME>
-- DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Safe to re-run: it drops and rebuilds everything.
-- Service rule: a vehicle is due when current_odometer - last_service_odometer >= 5000.
-- =====================================================================

DROP VIEW  IF EXISTS v_service_due;
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT  NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT  NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT  NOT NULL CHECK (end_odometer   >= 0),
    CONSTRAINT ck_trip_distance CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT  NOT NULL,
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1001', 12000, 10000),    -- 2000 km since service (fine now)
    ('ABC 1002', 30000, 24000),    -- 6000 km since service (already due)
    ('ABC 1003',  6000,  2000);    -- 4000 km; will reach exactly 5000 after its trips

-- ---------------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT on trips
-- Checks the start value, rejects bad mileage, and moves the vehicle's
-- odometer to the trip end exactly once (the procedure does NOT do this).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER AS $$
DECLARE
    v_current INT;
BEGIN
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
       OR NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end % (end must be greater than start, both non-negative)',
                        NEW.start_odometer, NEW.end_odometer;
    END IF;

    -- Lock the vehicle row so two trips cannot start from the same odometer value
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer (%), but start was %',
                        v_current, NEW.start_odometer;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_trip_odometer ON trips;
CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- ---------------------------------------------------------------------
-- (b) Function: fn_service_due
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN AS $$
DECLARE
    v_current INT;
    v_last    INT;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_record_trip
-- Only inserts the trip; the trigger updates the vehicle odometer.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INT,
    p_trip_on    DATE,
    p_start      INT,
    p_end        INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date must not be NULL';
    END IF;
    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (a, continued) Six trips, added THROUGH the procedure after the trigger exists
CALL pr_record_trip(1, CURRENT_DATE - 5, 12000, 12300);
CALL pr_record_trip(1, CURRENT_DATE - 3, 12300, 12800);
CALL pr_record_trip(2, CURRENT_DATE - 4, 30000, 30400);
CALL pr_record_trip(2, CURRENT_DATE - 2, 30400, 31000);
CALL pr_record_trip(3, CURRENT_DATE - 3,  6000,  6500);
CALL pr_record_trip(3, CURRENT_DATE - 1,  6500,  7000);

-- Tests: all must be rejected, and odometers must stay as they are
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12000, 12100); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- wrong start
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12800, 12800); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- end not > start
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;  -- unknown vehicle
-- Direct SQL is protected by the trigger as well
DO $$ BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer) VALUES (1, CURRENT_DATE, 5, 50);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (direct SQL): %', SQLERRM; END $$;

SELECT * FROM vehicles ORDER BY vehicle_id;   -- 12800 / 31000 / 7000
SELECT * FROM trips ORDER BY trip_id;          -- 6 rows
SELECT vehicle_id, fn_service_due(vehicle_id) AS service_due FROM vehicles ORDER BY vehicle_id;
-- expected: vehicle 1 = false (2800 km), vehicle 2 = true (7000 km), vehicle 3 = true (exactly 5000 km)

-- ---------------------------------------------------------------------
-- (e) View: vehicles that currently meet the threshold
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;

-- ---------------------------------------------------------------------
-- (f) Index: one vehicle's trips in a trip_on date range
-- Justification: equality on vehicle_id, range on trip_on. With vehicle_id
-- first, PostgreSQL jumps to that vehicle's entries, which are already
-- ordered by trip_on, so the date range is one contiguous slice of the index.
-- ---------------------------------------------------------------------
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;   -- tiny tables: force the planner to show the index
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job: keep service_alerts in step with the 5000 km rule
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- 1) Insert a new alert, or update the existing one, for every due vehicle
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           current_odometer - last_service_odometer,
           CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;   -- flagged_on keeps the original date

    -- 2) Remove alerts for vehicles that are no longer due (e.g. after servicing)
    DELETE FROM service_alerts sa
    USING vehicles v
    WHERE v.vehicle_id = sa.vehicle_id
      AND v.current_odometer - v.last_service_odometer < 5000;
END;
$$;

CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();        -- rerun: still one alert per due vehicle
SELECT * FROM service_alerts ORDER BY vehicle_id;      -- vehicles 2 and 3

-- Service vehicle 2, refresh again: its alert must disappear
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;      -- only vehicle 3 remains

-- Every Monday at 06:00 (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_service_alerts_weekly',
    '0 6 * * 1',
    $cron$CALL pr_refresh_service_alerts()$cron$
);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_service_alerts_weekly';
