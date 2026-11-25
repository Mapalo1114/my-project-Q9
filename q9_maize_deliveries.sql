-- ICT371 Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL)
DROP SCHEMA IF EXISTS q9 CASCADE;
CREATE SCHEMA q9;
SET search_path TO q9, public;

-- (a) TABLES -------------------------------------------------------------
CREATE TABLE farmers (
  farmer_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
  delivery_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
  grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
  weight_kg    NUMERIC(10,2) NOT NULL,
  unit_rate    NUMERIC(10,2) NOT NULL,     -- filled in by the trigger
  total_value  NUMERIC(14,2) NOT NULL,     -- filled in by the trigger
  delivered_on DATE NOT NULL,
  is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMERIC(14,2) NOT NULL DEFAULT 0,
  total_value   NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- (b) FUNCTION -----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC AS $$
BEGIN
  IF p_grade IS NULL THEN
    RAISE EXCEPTION 'Grade is required';
  ELSIF p_grade = 'A' THEN
    RETURN 5.00;
  ELSIF p_grade = 'B' THEN
    RETURN 4.00;
  ELSIF p_grade = 'C' THEN
    RETURN 3.00;
  END IF;
  RAISE EXCEPTION 'Unsupported grade: %', p_grade;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (d) TRIGGER (sets the price for every insert/update, including direct SQL)
CREATE OR REPLACE FUNCTION trg_fn_price_delivery() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
  END IF;

  NEW.unit_rate   := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

-- (c) PROCEDURE ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
AS $$
BEGIN
  PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown farmer: %', p_farmer_id;
  END IF;

  IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
    RAISE EXCEPTION 'Invalid grade: %', p_grade;
  END IF;
  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'Invalid weight: %', p_weight;
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Delivery date is required';
  END IF;

  -- only basic fields; the trigger supplies unit_rate and total_value
  INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$ LANGUAGE plpgsql;

-- (g) PROCEDURE: daily purchases -----------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
AS $$
BEGIN
  INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,     -- replace, never add
        total_value  = EXCLUDED.total_value;
END;
$$ LANGUAGE plpgsql;

-- (a) SEED DATA (loaded after the trigger exists) ------------------------
INSERT INTO farmers (farmer_number, full_name) VALUES
  ('F001', 'Joseph Mwanza'), ('F002', 'Agnes Phiri'), ('F003', 'Patrick Zulu');

-- Direct SQL: the trigger still prices these rows
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid) VALUES
  (1, 'A', 100, 0, 0, DATE '2026-11-20', TRUE),     -- rate/value are overwritten by the trigger
  (1, 'B', 250, 0, 0, DATE '2026-11-20', FALSE),
  (2, 'C', 400, 0, 0, DATE '2026-11-21', TRUE);

CALL pr_receive_delivery(2, 'A', 150, DATE '2026-11-21');
CALL pr_receive_delivery(1, 'C', 300, DATE '2026-11-22');
CALL pr_receive_delivery(2, 'B',  80, DATE '2026-11-22');

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id = 4;   -- mix of paid and unpaid

SELECT * FROM deliveries ORDER BY delivery_id;

-- tests (each should raise an error)
-- SELECT fn_maize_rate('A');                     -- 5.00
-- SELECT fn_maize_rate('D');                     -- Unsupported grade
-- SELECT fn_maize_rate(NULL);                    -- Grade is required
-- CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);   -- unknown farmer
-- CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);    -- invalid weight
-- UPDATE deliveries SET weight_kg = 200 WHERE delivery_id = 1;   -- trigger re-prices to 1000.00

-- (e) VIEW ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name, COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;   -- F003 shows 0

-- (f) INDEX --------------------------------------------------------------
-- Equality on farmer_id first, range on delivered_on second.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

ANALYZE deliveries;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-22';
RESET enable_seqscan;

-- (g) TEST AND SCHEDULE --------------------------------------------------
CALL pr_refresh_purchases(DATE '2026-11-21');
CALL pr_refresh_purchases(DATE '2026-11-21');   -- rerun: same totals
SELECT * FROM daily_purchases;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q9_refresh_purchases', '30 1 * * *',
  $$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$$);
