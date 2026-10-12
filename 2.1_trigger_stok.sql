-- =====================================================================
-- SOAL 2.1 - trg_update_stock_and_journal()
-- Prasyarat: tabel Soal 1 (chart_of_accounts, journal_headers, journal_lines)
-- sudah ada, beserta akun 5-1100 (HPP) dan 1-1300 (Persediaan).
-- =====================================================================

CREATE TABLE inventory_items (
    item_id    VARCHAR(10)   PRIMARY KEY,
    item_name  VARCHAR(100),
    stock_qty  INT           NOT NULL DEFAULT 0,
    unit_cost  NUMERIC(15,2) NOT NULL
);
CREATE TABLE inventory_transactions (
    trx_id    SERIAL PRIMARY KEY,
    item_id   VARCHAR(10) REFERENCES inventory_items(item_id),
    trx_type  VARCHAR(10) CHECK (trx_type IN ('PURCHASE','SALE','ADJUSTMENT')),
    qty       INT NOT NULL,
    trx_date  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Pertahanan terakhir: database menolak stok negatif walau ada bug aplikasi
ALTER TABLE inventory_items
    ADD CONSTRAINT chk_stock_nonneg CHECK (stock_qty >= 0);

-- Asumsi: PURCHASE & SALE -> qty > 0 (arah ditentukan trx_type);
--         ADJUSTMENT -> qty boleh + (menambah) atau - (mengurangi, mis. stock opname).
CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_stock   INT;
    v_cost    NUMERIC(15,2);
    v_delta   INT;
    v_new     INT;
    v_amount  NUMERIC(15,2);
    v_acc_hpp INT;
    v_acc_inv INT;
    v_header  BIGINT;
BEGIN
    -- Kunci baris barang: transaksi lain pada barang yang sama menunggu (anti race condition, lihat 2.2)
    SELECT stock_qty, unit_cost INTO v_stock, v_cost
      FROM inventory_items WHERE item_id = NEW.item_id
      FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Barang % tidak ditemukan', NEW.item_id;
    END IF;

    IF NEW.trx_type IN ('PURCHASE','SALE') AND NEW.qty <= 0 THEN
        RAISE EXCEPTION 'qty % tidak valid: % harus bernilai positif', NEW.qty, NEW.trx_type;
    END IF;

    v_delta := CASE NEW.trx_type
                   WHEN 'PURCHASE'   THEN  NEW.qty
                   WHEN 'SALE'       THEN -NEW.qty
                   WHEN 'ADJUSTMENT' THEN  NEW.qty
               END;
    v_new := v_stock + v_delta;

    -- (b) anti-negative inventory: batalkan seluruh transaksi
    IF v_new < 0 THEN
        RAISE EXCEPTION 'Stok % tidak cukup: tersedia %, diminta % (%). Transaksi dibatalkan.',
                        NEW.item_id, v_stock, ABS(v_delta), NEW.trx_type
            USING ERRCODE = 'check_violation';
    END IF;

    -- (a) mutasi stok otomatis
    UPDATE inventory_items SET stock_qty = v_new WHERE item_id = NEW.item_id;

    -- Jurnal otomatis HPP saat SALE: Dr HPP / Cr Persediaan = qty x unit_cost
    IF NEW.trx_type = 'SALE' THEN
        v_amount := NEW.qty * v_cost;
        IF v_amount > 0 THEN
            SELECT account_id INTO v_acc_hpp FROM chart_of_accounts WHERE account_code = '5-1100';
            SELECT account_id INTO v_acc_inv FROM chart_of_accounts WHERE account_code = '1-1300';
            IF v_acc_hpp IS NULL OR v_acc_inv IS NULL THEN
                RAISE EXCEPTION 'Akun HPP (5-1100) / Persediaan (1-1300) belum ada di chart_of_accounts';
            END IF;

            INSERT INTO journal_headers (trx_date, ref_no, description, posting_status)
            VALUES (CURRENT_DATE, 'HPP-' || NEW.trx_id,
                    'HPP penjualan ' || NEW.item_id || ' qty ' || NEW.qty, 'DRAFT')
            RETURNING header_id INTO v_header;

            INSERT INTO journal_lines (header_id, account_id, debit, credit) VALUES
                (v_header, v_acc_hpp, v_amount, 0),
                (v_header, v_acc_inv, 0, v_amount);
            -- Status DRAFT; posting resmi lewat fn_post_journal() (Soal 3.2).
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_inventory_transactions_bi
    BEFORE INSERT ON inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION trg_update_stock_and_journal();

-- ============================ PENGUJIAN ==============================
INSERT INTO inventory_items VALUES ('BRG-001','Kertas A4', 0, 50000);

INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001','PURCHASE', 10);  -- stok 10
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001','SALE',      3);  -- stok 7 + jurnal HPP 150.000
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001','ADJUSTMENT',-1);  -- stok 6 (opname)
-- INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001','SALE', 99);   -- ERROR: Stok tidak cukup

SELECT * FROM inventory_items;
SELECT h.ref_no, l.account_id, l.debit, l.credit
  FROM journal_headers h JOIN journal_lines l USING (header_id) WHERE h.ref_no LIKE 'HPP-%';
