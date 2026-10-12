UTS Pemrograman / Coding Akuntansi — 2026/2027

Repositori ini berisi artefak jawaban Ujian Tengah Semester (UTS) mata kuliah Pemrograman / Coding. Proyek ini mendemonstrasikan perancangan arsitektur basis data relasional (ERD & Normalisasi), otomasi bisnis melalui trigger PostgreSQL, serta pembuatan purwarupa modul kas keluar berbasis web dengan jejak audit (audit trail).

👤 Identitas

Nama: Al Furqon Dzikri Islami

NIM: 12030123130195

Mata Kuliah: Pemrograman / Coding

Program Studi: Akuntansi, Fakultas Ekonomika dan Bisnis, Universitas Diponegoro

📁 Struktur Repositori

Repositori ini dibagi menjadi beberapa folder sesuai dengan instruksi pengerjaan soal:

Soal-1/

Berisi diagram ERD (1.1_ERD.png & 1.1_ERD.mmd).

Skrip DDL PostgreSQL untuk pembuatan tabel Header-Line dan constraint integritas (1.2_ddl_jurnal.sql).

Analisis mengenai keandalan pemisahan Header-Line dan 3NF (1.3_analisis_header_line.md).

Soal-2/

Skrip Stored Procedure dan Trigger untuk otomasi persediaan persediaan (2.1_trigger_stok.sql).

Penjelasan dan cuplikan kode penanganan masalah Race Condition (2.2_concurrency.sql).

Soal-3/

Purwarupa antarmuka web Voucher Kas Keluar terintegrasi API (voucher_kas_keluar.html).

Dokumentasi penggunaan prompt AI (Gemini Canvas) dan hasil verifikasi kepatuhan aturan bisnis (PSAK 2) menggunakan NotebookLM (3.1_prompt_dan_verifikasi_psak2.md).

Skrip implementasi Audit Trail, Immutability, dan Reversing Entry via Supabase RPC (3.2_audit_trail.sql).

Dokumentasi/

(Folder ini disiapkan untuk menyimpan tangkapan layar/screenshot bukti pengujian Supabase, riwayat obrolan AI, dan dokumen pendukung lainnya).

🚀 Cara Penggunaan & Pengujian

Database (Supabase / PostgreSQL):

Jalankan skrip DDL dari Soal-1 dan Soal-2 pada SQL Editor di Supabase.

Lanjutkan dengan menjalankan skrip RPC dan Trigger dari Soal-3 (3.2_audit_trail.sql).

Frontend Web:

File voucher_kas_keluar.html dapat dibuka langsung menggunakan web browser apa pun (tidak perlu proses build atau server lokal khusus karena menggunakan CDN Tailwind dan Vanilla JS).

Pastikan URL API dan anon_key Supabase pada file HTML tersebut sudah disesuaikan dengan kredensial proyek Supabase Anda.

📝 Catatan Penting

Bukti pengujian PostgreSQL/Supabase dan penggunaan AI (Gemini Canvas & NotebookLM) yang dicantumkan merupakan hasil aktual dari lingkungan pengembangan (sandbox).
