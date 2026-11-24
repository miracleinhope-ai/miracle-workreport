-- =====================================================================
-- SiKerja Pro — Migrasi v4: Fitur Suspend / Nonaktifkan User Sementara
-- Jalankan di: Supabase Dashboard > SQL Editor
-- =====================================================================

ALTER TABLE users ADD COLUMN IF NOT EXISTS aktif BOOLEAN DEFAULT true;
UPDATE users SET aktif = true WHERE aktif IS NULL;
