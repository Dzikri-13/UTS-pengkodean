-- =====================================================================
-- SOAL 2.2 - Race condition: 2 kasir, stok tersisa 1 unit
-- Persiapan: UPDATE inventory_items SET stock_qty = 1 WHERE item_id = 'BRG-001';
-- =====================================================================

-- ---------------------------------------------------------------------
-- MASALAH (tanpa pengaman), dua sesi berjalan bersamaan:
--   Sesi A: SELECT stock_qty ... -> 1 (cukup)     Sesi B: SELECT stock_qty ... -> 1 (cukup)
--   Sesi A: UPDATE stock = 1 - 1                  Sesi B: UPDATE stock = 1 - 1
-- Keduanya membaca nilai lama sebelum salah satu COMMIT -> 2 barang terjual
-- padahal fisik hanya 1 (overselling / phantom stock, "lost update").
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- SOLUSI 1: Pessimistic locking - SELECT ... FOR UPDATE   (DIPILIH)
-- ---------------------------------------------------------------------
BEGIN;
SELECT stock_qty FROM inventory_items WHERE item_id = 'BRG-001' FOR UPDATE;  -- baris dikunci
-- aplikasi: cek stock_qty >= 1 ; kalau tidak cukup -> ROLLBACK
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001','SALE',1);
COMMIT;   -- kunci dilepas
-- Sesi B yang menjalankan SELECT ... FOR UPDATE pada baris sama akan MENUNGGU sampai
-- sesi A COMMIT/ROLLBACK, lalu membaca stok = 0 -> ditolak.
-- Trigger trg_update_stock_and_journal() sudah memakai FOR UPDATE di dalamnya,
-- jadi perlindungan ini tertanam di database walau aplikasi lupa mengunci.

-- ---------------------------------------------------------------------
-- SOLUSI 2: Isolation level SERIALIZABLE
-- ---------------------------------------------------------------------
BEGIN ISOLATION LEVEL SERIALIZABLE;
INSERT INTO inventory_transactions (item_id, trx_type, qty) VALUES ('BRG-001','SALE',1);
COMMIT;
-- Jika dua transaksi saling bergantung, PostgreSQL membatalkan salah satunya:
--   ERROR: could not serialize access ...   (SQLSTATE 40001)
-- Aplikasi WAJIB menangkap 40001 dan mengulang (retry), contoh pseudocode Node.js:
--
--   for (let i = 0; i < 3; i++) {
--     try { await tx(`BEGIN ISOLATION LEVEL SERIALIZABLE`); ...; await tx(`COMMIT`); break; }
--     catch (e) { await tx(`ROLLBACK`); if (e.code !== '40001') throw e; }
--   }

-- ---------------------------------------------------------------------
-- SOLUSI 3: Update atomik bersyarat (cek + kurang dalam SATU perintah)
-- ---------------------------------------------------------------------
UPDATE inventory_items
   SET stock_qty = stock_qty - 1
 WHERE item_id = 'BRG-001'
   AND stock_qty >= 1
RETURNING stock_qty;
-- 0 baris terpengaruh = stok tidak cukup -> aplikasi menolak penjualan.
-- Catatan: bila dipakai langsung, jangan sekaligus INSERT SALE yang memicu trigger 2.1
-- (stok akan berkurang dua kali). Pola ini untuk aplikasi yang tidak memakai trigger.

-- ---------------------------------------------------------------------
-- PERTAHANAN TERAKHIR: sudah ada di 2.1
-- ALTER TABLE inventory_items ADD CONSTRAINT chk_stock_nonneg CHECK (stock_qty >= 0);
-- ---------------------------------------------------------------------

-- ================= SIMULASI DUA SESI (buka 2 tab SQL) =================
-- Tab A: BEGIN; INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG-001','SALE',1);   -- (belum COMMIT)
-- Tab B: BEGIN; INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG-001','SALE',1);   -- MENUNGGU (terkunci)
-- Tab A: COMMIT;
-- Tab B: -> ERROR "Stok BRG-001 tidak cukup: tersedia 0 ..."; lalu ROLLBACK;
