-- =====================================================================
-- SOAL 1.2 - DDL PostgreSQL: General Ledger (header-line) + integritas
-- =====================================================================

-- 1) Daftar akun ------------------------------------------------------
CREATE TABLE chart_of_accounts (
    account_id     SERIAL        PRIMARY KEY,
    account_code   VARCHAR(10)   NOT NULL UNIQUE,
    account_name   VARCHAR(100)  NOT NULL,
    normal_balance CHAR(1)       NOT NULL,
    report_class   VARCHAR(10)   NOT NULL,
    is_cash        BOOLEAN       NOT NULL DEFAULT FALSE,  -- kas/bank/setara kas (dipakai Soal 3)
    CONSTRAINT chk_normal_balance CHECK (normal_balance IN ('D','K')),
    CONSTRAINT chk_report_class   CHECK (report_class   IN ('NERACA','LABA_RUGI'))
);

-- 2) Header jurnal (satu baris per bukti/transaksi) -------------------
CREATE TABLE journal_headers (
    header_id      BIGSERIAL     PRIMARY KEY,
    trx_date       DATE          NOT NULL,
    ref_no         VARCHAR(30)   NOT NULL UNIQUE,
    description    TEXT,
    posting_status VARCHAR(10)   NOT NULL DEFAULT 'DRAFT',
    CONSTRAINT chk_posting_status CHECK (posting_status IN ('DRAFT','POSTED','REVERSED'))
);

-- 3) Baris jurnal (satu baris per akun yang terpengaruh) --------------
CREATE TABLE journal_lines (
    line_id        BIGSERIAL     PRIMARY KEY,
    header_id      BIGINT        NOT NULL
                   REFERENCES journal_headers(header_id)  ON DELETE RESTRICT,
    account_id     INT           NOT NULL
                   REFERENCES chart_of_accounts(account_id) ON DELETE RESTRICT,
    debit          NUMERIC(18,2) NOT NULL DEFAULT 0,
    credit         NUMERIC(18,2) NOT NULL DEFAULT 0,
    CONSTRAINT chk_debit_nonneg   CHECK (debit  >= 0),
    CONSTRAINT chk_credit_nonneg  CHECK (credit >= 0),
    CONSTRAINT chk_not_both_zero  CHECK (NOT (debit = 0 AND credit = 0)),
    -- tambahan: satu baris hanya boleh satu sisi (debit ATAU kredit)
    CONSTRAINT chk_one_side_only  CHECK (debit = 0 OR credit = 0)
);

CREATE INDEX idx_lines_header  ON journal_lines(header_id);
CREATE INDEX idx_lines_account ON journal_lines(account_id);

-- =====================================================================
-- PENEGAKAN ASAS BERPASANGAN DI LEVEL DATABASE
-- CHECK biasa hanya melihat 1 baris, sedangkan keseimbangan adalah sifat
-- SEKUMPULAN baris. Maka dipakai CONSTRAINT TRIGGER yang DITUNDA sampai
-- COMMIT: baris boleh dimasukkan satu per satu, tetapi saat COMMIT total
-- debit harus = total kredit, kalau tidak seluruh transaksi di-rollback.
-- Karena ada di database, API/Postman/script apa pun tidak bisa lolos.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_assert_journal_balanced()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_ids BIGINT[];
    v_id  BIGINT;
    v_d   NUMERIC;
    v_k   NUMERIC;
    v_n   INT;
BEGIN
    IF TG_TABLE_NAME = 'journal_headers' THEN
        v_ids := ARRAY[NEW.header_id];
    ELSIF TG_OP = 'DELETE' THEN
        v_ids := ARRAY[OLD.header_id];
    ELSIF TG_OP = 'UPDATE' THEN
        v_ids := ARRAY[OLD.header_id, NEW.header_id];
    ELSE
        v_ids := ARRAY[NEW.header_id];
    END IF;

    FOREACH v_id IN ARRAY v_ids LOOP
        -- header sudah tidak ada (mis. dibatalkan) -> tidak perlu dicek
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM journal_headers WHERE header_id = v_id);

        SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0), COUNT(*)
          INTO v_d, v_k, v_n
          FROM journal_lines WHERE header_id = v_id;

        IF v_n < 2 THEN
            RAISE EXCEPTION 'Jurnal % harus punya minimal 2 baris (ditemukan %)', v_id, v_n
                USING ERRCODE = 'check_violation';
        END IF;
        IF v_d <> v_k THEN
            RAISE EXCEPTION 'Jurnal % tidak seimbang: debit=% kredit=% selisih=%',
                            v_id, v_d, v_k, v_d - v_k
                USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;
    RETURN NULL;   -- AFTER trigger: nilai return diabaikan
END;
$$;

CREATE CONSTRAINT TRIGGER trg_lines_balanced
    AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_assert_journal_balanced();

-- header tanpa baris sama sekali juga ditolak saat COMMIT
CREATE CONSTRAINT TRIGGER trg_header_has_lines
    AFTER INSERT ON journal_headers
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION fn_assert_journal_balanced();

-- =====================================================================
-- DATA CONTOH (akun) + PENGUJIAN
-- =====================================================================
INSERT INTO chart_of_accounts (account_code, account_name, normal_balance, report_class, is_cash) VALUES
 ('1-1100','Kas',                    'D','NERACA',   TRUE),
 ('1-1200','Bank',                   'D','NERACA',   TRUE),
 ('1-1300','Persediaan Barang Dagang','D','NERACA',  FALSE),
 ('2-1100','Utang Usaha',            'K','NERACA',   FALSE),
 ('4-1100','Penjualan',              'K','LABA_RUGI',FALSE),
 ('5-1100','Beban Pokok Pendapatan (HPP)','D','LABA_RUGI',FALSE),
 ('5-2100','Beban Listrik',          'D','LABA_RUGI',FALSE),
 ('5-2200','Beban Gaji',             'D','LABA_RUGI',FALSE);

-- Uji 1: jurnal SEIMBANG -> berhasil
BEGIN;
INSERT INTO journal_headers (trx_date, ref_no, description)
VALUES (CURRENT_DATE, 'BKK-2026-001', 'Bayar listrik bulan Oktober');
INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES
 ((SELECT header_id FROM journal_headers WHERE ref_no='BKK-2026-001'),
  (SELECT account_id FROM chart_of_accounts WHERE account_code='5-2100'), 500000, 0),
 ((SELECT header_id FROM journal_headers WHERE ref_no='BKK-2026-001'),
  (SELECT account_id FROM chart_of_accounts WHERE account_code='1-1100'), 0, 500000);
COMMIT;   -- OK

-- Uji 2: jurnal TIDAK SEIMBANG -> COMMIT ditolak (ERROR: Jurnal ... tidak seimbang)
-- BEGIN;
-- INSERT INTO journal_headers (trx_date, ref_no, description)
-- VALUES (CURRENT_DATE, 'BKK-2026-002', 'Sengaja tidak seimbang');
-- INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES
--  ((SELECT header_id FROM journal_headers WHERE ref_no='BKK-2026-002'),
--   (SELECT account_id FROM chart_of_accounts WHERE account_code='5-2100'), 500000, 0),
--  ((SELECT header_id FROM journal_headers WHERE ref_no='BKK-2026-002'),
--   (SELECT account_id FROM chart_of_accounts WHERE account_code='1-1100'), 0, 400000);
-- COMMIT;   -- ERROR

-- Uji 3: nilai negatif / nol-nol -> ditolak CHECK saat INSERT
-- INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES (1, 1, -5, 0);   -- chk_debit_nonneg
-- INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES (1, 1, 0, 0);    -- chk_not_both_zero

-- Uji 4: hapus akun/header yang sudah dipakai -> ditolak ON DELETE RESTRICT
-- DELETE FROM chart_of_accounts WHERE account_code = '5-2100';
