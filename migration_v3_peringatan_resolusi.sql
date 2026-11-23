-- =====================================================================
-- SiKerja Pro — Migrasi v3: Peringatan Klien & Indikasi Kelalaian (SRK / IKU)
-- Menyimpan riwayat tindakan penanganan, catatan penyelesaian & status normal
-- Jalankan di: Supabase Dashboard > SQL Editor
-- =====================================================================

CREATE TABLE IF NOT EXISTS peringatan_resolusi (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  klien_id         uuid REFERENCES klien(id) ON DELETE CASCADE,
  periode_bulan    integer NOT NULL CHECK (periode_bulan BETWEEN 1 AND 12),
  periode_tahun    integer NOT NULL,
  status           text NOT NULL DEFAULT 'aktif' CHECK (status IN ('aktif', 'selesai', 'normal')),
  tindakan         text,
  penyelesaian     text,
  resolved_at      timestamptz,
  resolved_by_id   uuid REFERENCES users(id) ON DELETE SET NULL,
  resolved_by_nama text,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now(),
  CONSTRAINT uq_klien_periode UNIQUE (klien_id, periode_tahun, periode_bulan)
);

CREATE INDEX IF NOT EXISTS idx_pr_klien_periode ON peringatan_resolusi(klien_id, periode_tahun, periode_bulan);

-- RLS terbuka untuk anon
ALTER TABLE peringatan_resolusi ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon_all_peringatan_resolusi" ON peringatan_resolusi;
CREATE POLICY "anon_all_peringatan_resolusi" ON peringatan_resolusi FOR ALL TO anon USING (true) WITH CHECK (true);

-- Realtime
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE peringatan_resolusi;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
