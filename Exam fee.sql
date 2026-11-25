Q2: University Fee Payments
DROP SCHEMA IF EXISTS q2_fees CASCADE;
CREATE SCHEMA q2_fees;
SET search_path TO q2_fees;

(a) Tables and seed data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(10,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL
);
CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(10,2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INT NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
('S001', 'Chanda Mwila', 5000),
('S002', 'Mary Banda',   3000),
('S003', 'Joseph Phiri', 1500);   -- no payments

(b) Function: fee balance
CREATE FUNCTION fn_fee_balance(p_student_id INT) RETURNS NUMERIC AS $$
DECLARE v_fee NUMERIC;
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student';
    END IF;
    RETURN v_fee - (SELECT COALESCE(SUM(amount), 0)
                    FROM payments WHERE student_id = p_student_id);
END;
$$ LANGUAGE plpgsql;

(c) Procedure: receive payment
CREATE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be positive';
    END IF;
    IF p_amount > fn_fee_balance(p_student_id) THEN
        RAISE EXCEPTION 'Amount is above the outstanding balance';
    END IF;
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

(d) Trigger: audit every new payment
CREATE FUNCTION trg_payment_audit_fn() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit_fn();

(a) continued: load 6 payments through the procedure
CALL pr_receive_payment(1, 1000, '2026-11-20');
CALL pr_receive_payment(1, 1500, '2026-11-21');
CALL pr_receive_payment(1,  500, '2026-11-22');
CALL pr_receive_payment(2, 1000, '2026-11-20');
CALL pr_receive_payment(2, 1000, '2026-11-21');
CALL pr_receive_payment(2, 1000, '2026-11-22');

SELECT * FROM payments;
SELECT * FROM payment_audit;                  -- 6 rows
SELECT fn_fee_balance(3);                     -- 1500 (no payments)
CALL pr_receive_payment(1, 99999, CURRENT_DATE);   -- error test

(e) View: students who still owe
CREATE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;                 -- Mary is not shown

--(f) Index: student + date range
-- Justification: the query tests student_id (equal) and paid_on (range),
-- so one index on both columns finds the rows without reading the whole table.
CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);

SET enable_seqscan = off;                     -- table is tiny
EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN '2026-11-20' AND '2026-11-30';
SET enable_seqscan = on;

(g) Scheduled job: daily collection report
CREATE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections('2026-11-21');
CALL pr_refresh_collections('2026-11-21');    -- rerun: still one row
SELECT * FROM daily_collections;              -- count 2, total 2500

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_collections', '0 1 * * *',
    $$CALL q2_fees.pr_refresh_collections(CURRENT_DATE - 1)$$);
SELECT * FROM cron.job;