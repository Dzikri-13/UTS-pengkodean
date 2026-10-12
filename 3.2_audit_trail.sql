-- =====================================================================
-- SOAL 3.2 - Audit trail, immutability, jurnal pembalik (Supabase RPC)
-- Prasyarat: Soal 1.2. Dijalankan di Supabase SQL Editor (PostgreSQL 15).
-- Di sandbox PostgreSQL biasa, buat stub dulu:
--   CREATE SCHEMA IF NOT EXISTS auth;
--   CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT NULL::uuid $$;
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- a) Kolom audit ------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS journal_post_seq;

ALTER TABLE journal_headers
    ADD COLUMN created_by    UUID        DEFAULT auth.uid(),   -- dari JWT, bukan dari frontend
    ADD COLUMN created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),-- waktu server
    ADD COLUMN posted_at     TIMESTAMPTZ,
    ADD COLUMN posted_seq    BIGINT UNIQUE,                     -- urutan rantai hash
    ADD COLUMN hash_checksum CHAR(64),                          -- SHA-256 isi jurnal
    ADD COLUMN prev_hash     CHAR(64),                          -- hash jurnal POSTED sebelumnya
    ADD COLUMN reversal_of   BIGINT REFERENCES journal_headers(header_id) ON DELETE RESTRICT;

-- untuk 3.1b (PSAK 2): klasifikasi arus kas per baris
ALTER TABLE journal_lines
    ADD COLUMN cash_flow_category VARCHAR(10),
    ADD CONSTRAINT chk_cash_flow_category
        CHECK (cash_flow_category IS NULL OR cash_flow_category IN ('OPERASI','INVESTASI','PENDANAAN'));

-- b) Fungsi penghitung hash ------------------------------------------
-- Hash = SHA-256( prev_hash | header | seluruh baris terurut ). Mengubah satu angka
-- di jurnal lama -> hash berubah -> hash jurnal-jurnal sesudahnya ikut tidak cocok.
CREATE OR REPLACE FUNCTION fn_compute_journal_hash(p_header_id BIGINT, p_prev CHAR(64))
RETURNS CHAR(64) LANGUAGE sql STABLE SET search_path = public, extensions AS $$
    SELECT encode(digest(
              COALESCE(p_prev,'GENESIS') || '|' || h.header_id || '|' || h.ref_no || '|' ||
              h.trx_date::text || '|' || COALESCE(h.description,'') || '|' ||
              COALESCE((SELECT string_agg(l.account_id || ':' || l.debit::text || ':' || l.credit::text,
                                          ';' ORDER BY l.line_id)
                          FROM journal_lines l WHERE l.header_id = h.header_id), ''),
              'sha256'), 'hex')
      FROM journal_headers h WHERE h.header_id = p_header_id;
$$;

-- c) Trigger penolak UPDATE/DELETE pada transaksi POSTED -------------
CREATE OR REPLACE FUNCTION trg_block_posted_header()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.posting_status <> 'DRAFT' THEN
            RAISE EXCEPTION 'Jurnal % berstatus % tidak boleh dihapus. Gunakan jurnal pembalik (fn_reverse_journal).',
                            OLD.ref_no, OLD.posting_status USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN OLD;
    END IF;

    -- UPDATE
    IF OLD.posting_status = 'DRAFT' THEN
        RETURN NEW;                                   -- DRAFT -> POSTED tetap boleh
    ELSIF OLD.posting_status = 'POSTED'
          AND NEW.posting_status = 'REVERSED'
          AND ROW(NEW.header_id, NEW.trx_date, NEW.ref_no, NEW.description, NEW.created_by,
                  NEW.created_at, NEW.posted_at, NEW.posted_seq, NEW.hash_checksum,
                  NEW.prev_hash, NEW.reversal_of)
              IS NOT DISTINCT FROM
              ROW(OLD.header_id, OLD.trx_date, OLD.ref_no, OLD.description, OLD.created_by,
                  OLD.created_at, OLD.posted_at, OLD.posted_seq, OLD.hash_checksum,
                  OLD.prev_hash, OLD.reversal_of)
    THEN
        RETURN NEW;                                   -- hanya penandaan "sudah dibalik"
    END IF;
    RAISE EXCEPTION 'Jurnal % berstatus % terkunci (immutable). Koreksi harus lewat jurnal pembalik.',
                    OLD.ref_no, OLD.posting_status USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER trg_header_immutable
    BEFORE UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION trg_block_posted_header();

-- Baris jurnal hanya boleh diubah/ditambah/dihapus selama header masih DRAFT
CREATE OR REPLACE FUNCTION trg_block_posted_lines()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status TEXT; v_hid BIGINT;
BEGIN
    v_hid := CASE WHEN TG_OP = 'INSERT' THEN NEW.header_id ELSE OLD.header_id END;
    SELECT posting_status INTO v_status FROM journal_headers WHERE header_id = v_hid;
    IF v_status IS NOT NULL AND v_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Baris jurnal % terkunci karena header berstatus %', v_hid, v_status
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

CREATE TRIGGER trg_lines_immutable
    BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION trg_block_posted_lines();

-- d) RPC: POSTING ------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_post_journal(p_header_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_status TEXT; v_d NUMERIC; v_k NUMERIC; v_n INT; v_prev CHAR(64); v_hash CHAR(64);
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('journal_hash_chain'));  -- rantai hash tidak bercabang

    SELECT posting_status INTO v_status FROM journal_headers WHERE header_id = p_header_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Jurnal % tidak ditemukan', p_header_id; END IF;
    IF v_status <> 'DRAFT' THEN RAISE EXCEPTION 'Jurnal % sudah berstatus %', p_header_id, v_status; END IF;

    SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0), COUNT(*)
      INTO v_d, v_k, v_n FROM journal_lines WHERE header_id = p_header_id;
    IF v_n < 2 OR v_d <> v_k THEN
        RAISE EXCEPTION 'Jurnal % tidak dapat diposting: baris=% debit=% kredit=%', p_header_id, v_n, v_d, v_k;
    END IF;

    SELECT hash_checksum INTO v_prev FROM journal_headers
     WHERE posted_seq IS NOT NULL ORDER BY posted_seq DESC LIMIT 1;
    v_hash := fn_compute_journal_hash(p_header_id, v_prev);

    UPDATE journal_headers
       SET posting_status = 'POSTED', posted_at = now(),
           posted_seq = nextval('journal_post_seq'),
           prev_hash = v_prev, hash_checksum = v_hash
     WHERE header_id = p_header_id;
END;
$$;

-- RPC: REVERSING ENTRY (storno)
CREATE OR REPLACE FUNCTION fn_reverse_journal(p_header_id BIGINT, p_reason TEXT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE o journal_headers%ROWTYPE; v_new BIGINT;
BEGIN
    SELECT * INTO o FROM journal_headers WHERE header_id = p_header_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Jurnal % tidak ditemukan', p_header_id; END IF;
    IF o.posting_status <> 'POSTED' THEN
        RAISE EXCEPTION 'Hanya jurnal POSTED yang bisa dibalik (status sekarang: %)', o.posting_status;
    END IF;
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        RAISE EXCEPTION 'Alasan pembalikan wajib diisi';
    END IF;

    INSERT INTO journal_headers (trx_date, ref_no, description, posting_status, reversal_of)
    VALUES (CURRENT_DATE, 'REV-' || o.ref_no,
            'Pembalik ' || o.ref_no || ': ' || p_reason, 'DRAFT', o.header_id)
    RETURNING header_id INTO v_new;

    INSERT INTO journal_lines (header_id, account_id, debit, credit, cash_flow_category)
    SELECT v_new, account_id, credit, debit, cash_flow_category     -- debit & kredit ditukar
      FROM journal_lines WHERE header_id = o.header_id;

    PERFORM fn_post_journal(v_new);
    UPDATE journal_headers SET posting_status = 'REVERSED' WHERE header_id = o.header_id;
    RETURN v_new;
    -- Lalu buat jurnal koreksi baru yang benar lewat fn_create_cash_out_voucher().
END;
$$;

-- RPC: buat voucher kas keluar (dipanggil frontend Soal 3.1a)
-- p_lines: [{"account_id":5,"debit":500000,"credit":0,"cash_flow_category":"OPERASI"}, ...]
CREATE OR REPLACE FUNCTION fn_create_cash_out_voucher(
        p_trx_date DATE, p_ref_no VARCHAR, p_description TEXT, p_lines JSONB, p_post BOOLEAN DEFAULT TRUE)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id BIGINT;
BEGIN
    INSERT INTO journal_headers (trx_date, ref_no, description, posting_status)
    VALUES (p_trx_date, p_ref_no, p_description, 'DRAFT')
    RETURNING header_id INTO v_id;                   -- created_by & created_at terisi di server

    INSERT INTO journal_lines (header_id, account_id, debit, credit, cash_flow_category)
    SELECT v_id, (l->>'account_id')::INT,
           COALESCE((l->>'debit')::NUMERIC, 0), COALESCE((l->>'credit')::NUMERIC, 0),
           NULLIF(l->>'cash_flow_category','')
      FROM jsonb_array_elements(p_lines) AS l;

    -- Aturan kas keluar: minimal satu baris mengkredit akun kas/bank (PSAK 2)
    IF NOT EXISTS (SELECT 1 FROM journal_lines jl JOIN chart_of_accounts a ON a.account_id = jl.account_id
                    WHERE jl.header_id = v_id AND jl.credit > 0 AND a.is_cash) THEN
        RAISE EXCEPTION 'Voucher kas keluar harus mengkredit minimal satu akun kas/bank';
    END IF;

    IF p_post THEN PERFORM fn_post_journal(v_id); END IF;
    RETURN v_id;
END;
$$;

-- e) Verifikasi integritas (untuk auditor) ----------------------------
CREATE OR REPLACE FUNCTION fn_verify_journal_chain()
RETURNS TABLE (o_header_id BIGINT, o_ref_no VARCHAR, o_ok BOOLEAN, o_detail TEXT)
LANGUAGE plpgsql STABLE SET search_path = public, extensions AS $$
DECLARE r RECORD; v_prev CHAR(64) := NULL; v_calc CHAR(64);
BEGIN
    FOR r IN SELECT * FROM journal_headers WHERE posted_seq IS NOT NULL ORDER BY posted_seq LOOP
        v_calc := fn_compute_journal_hash(r.header_id, v_prev);
        o_header_id := r.header_id; o_ref_no := r.ref_no;
        IF r.prev_hash IS DISTINCT FROM v_prev THEN
            o_ok := FALSE; o_detail := 'Rantai putus: prev_hash tidak cocok (jurnal sebelumnya diubah/dihapus)';
        ELSIF r.hash_checksum IS DISTINCT FROM v_calc THEN
            o_ok := FALSE; o_detail := 'Isi jurnal berubah: hash tersimpan <> hash hitung ulang';
        ELSE
            o_ok := TRUE;  o_detail := 'OK';
        END IF;
        v_prev := r.hash_checksum;
        RETURN NEXT;
    END LOOP;
END;
$$;
-- Pemakaian: SELECT * FROM fn_verify_journal_chain() WHERE NOT o_ok;   (kosong = semua utuh)

-- Tabel audit_log: siapa, kapan, apa, data lama/baru ------------------
CREATE TABLE audit_log (
    log_id     BIGSERIAL   PRIMARY KEY,
    user_id    UUID        DEFAULT auth.uid(),
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    action     VARCHAR(10) NOT NULL,
    table_name VARCHAR(50) NOT NULL,
    record_id  TEXT,
    old_data   JSONB,
    new_data   JSONB
);

CREATE OR REPLACE FUNCTION trg_audit_row() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_old JSONB := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END;
        v_new JSONB := to_jsonb(NEW);
BEGIN
    INSERT INTO audit_log (action, table_name, record_id, old_data, new_data)
    VALUES (TG_OP, TG_TABLE_NAME, v_new->>TG_ARGV[0], v_old, v_new);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_headers AFTER INSERT OR UPDATE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION trg_audit_row('header_id');
CREATE TRIGGER trg_audit_lines   AFTER INSERT OR UPDATE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION trg_audit_row('line_id');

-- audit_log sendiri append-only
CREATE OR REPLACE FUNCTION trg_audit_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'audit_log bersifat append-only'; END; $$;
CREATE TRIGGER trg_audit_log_lock BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION trg_audit_append_only();
-- Catatan: percobaan UPDATE/DELETE yang DITOLAK ikut di-rollback bersama transaksinya,
-- sehingga tidak masuk audit_log; jejaknya ada di log server PostgreSQL (pesan ERROR).

-- Lapisan tambahan (Supabase): RLS + cabut hak langsung ---------------
ALTER TABLE journal_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_lines   ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log       ENABLE ROW LEVEL SECURITY;
CREATE POLICY read_headers ON journal_headers FOR SELECT TO authenticated USING (true);
CREATE POLICY read_lines   ON journal_lines   FOR SELECT TO authenticated USING (true);
CREATE POLICY read_audit   ON audit_log       FOR SELECT TO authenticated USING (true);
-- Tanpa policy INSERT/UPDATE/DELETE, klien tidak bisa menulis langsung ke tabel;
-- penulisan hanya lewat RPC SECURITY DEFINER di atas.
REVOKE UPDATE, DELETE ON journal_headers, journal_lines FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION fn_post_journal(BIGINT), fn_reverse_journal(BIGINT, TEXT),
                           fn_create_cash_out_voucher(DATE, VARCHAR, TEXT, JSONB, BOOLEAN) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION fn_post_journal(BIGINT), fn_reverse_journal(BIGINT, TEXT),
                           fn_create_cash_out_voucher(DATE, VARCHAR, TEXT, JSONB, BOOLEAN) TO authenticated;
-- Demo tanpa login saja (jangan untuk produksi):
-- GRANT EXECUTE ON FUNCTION fn_create_cash_out_voucher(DATE, VARCHAR, TEXT, JSONB, BOOLEAN) TO anon;

-- ============================ PENGUJIAN ==============================
-- SELECT fn_create_cash_out_voucher(CURRENT_DATE,'BKK-2026-010','Bayar gaji',
--   '[{"account_id":8,"debit":2000000,"credit":0,"cash_flow_category":"OPERASI"},
--     {"account_id":1,"debit":0,"credit":2000000,"cash_flow_category":"OPERASI"}]'::jsonb);
-- UPDATE journal_headers SET description='diubah' WHERE ref_no='BKK-2026-010';   -- ERROR terkunci
-- DELETE FROM journal_headers WHERE ref_no='BKK-2026-010';                       -- ERROR terkunci
-- SELECT fn_reverse_journal((SELECT header_id FROM journal_headers WHERE ref_no='BKK-2026-010'),'Salah akun');
-- SELECT * FROM fn_verify_journal_chain();
