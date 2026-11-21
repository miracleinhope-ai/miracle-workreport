-- =====================================================================
-- SiKerja Pro — Migrasi v2: Sistem Kerja, Jenis Tindakan, Tindakan Harian & KPI
-- Zona Waktu Default: WITA (Asia/Makassar, UTC+8)
-- Jalankan di: Supabase Dashboard > SQL Editor
-- =====================================================================

-- 1. Helper fungsi jam server untuk sinkronisasi waktu WITA anti-manipulasi
CREATE OR REPLACE FUNCTION get_server_time()
RETURNS timestamptz
LANGUAGE sql
STABLE
AS $$
  SELECT now();
$$;

-- 2. Tambah kolom pelacakan keterlambatan & jam keluar pada tabel absensi
ALTER TABLE absensi ADD COLUMN IF NOT EXISTS terlambat boolean DEFAULT false;
ALTER TABLE absensi ADD COLUMN IF NOT EXISTS menit_terlambat integer DEFAULT 0;
ALTER TABLE absensi ADD COLUMN IF NOT EXISTS jam_keluar text;
ALTER TABLE absensi ADD COLUMN IF NOT EXISTS closing_hari_at timestamptz;

-- 3. MASTER: Sistem Kerja (keberadaan pekerjaan: ABSS, Access, Excel, NextBO, dll.)
CREATE TABLE IF NOT EXISTS m_sistem_kerja (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kode       text UNIQUE NOT NULL,
  nama       text NOT NULL,
  aktif      boolean NOT NULL DEFAULT true,
  urutan     integer NOT NULL DEFAULT 1,
  created_at timestamptz DEFAULT now()
);

INSERT INTO m_sistem_kerja (kode, nama, urutan) VALUES
  ('ABSS',    'ABSS (MYOB)',        1),
  ('ACCESS',  'Access App',         2),
  ('EXCEL',   'Excel Sheet',        3),
  ('NEXTBO',  'NextBO',             4),
  ('CORETAX', 'Coretax / e-Faktur', 5),
  ('LAIN',    'Lainnya',            6)
ON CONFLICT (kode) DO NOTHING;

-- 4. MASTER: Jenis Tindakan & Bobot KPI
CREATE TABLE IF NOT EXISTS m_jenis_tindakan (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kode          text UNIQUE NOT NULL,
  nama          text NOT NULL,
  boleh_diulang boolean NOT NULL DEFAULT true,
  bobot         numeric(4,2) NOT NULL DEFAULT 1.00,
  deskripsi     text,
  aktif         boolean NOT NULL DEFAULT true,
  urutan        integer NOT NULL DEFAULT 1,
  created_at    timestamptz DEFAULT now()
);

INSERT INTO m_jenis_tindakan (kode, nama, boleh_diulang, bobot, deskripsi, urutan) VALUES
  ('DE', 'Data Entry → Checker',                 false, 1.00, 'Input transaksi awal ke sistem sampai siap diperiksa (tidak boleh diulang)', 1),
  ('CR', 'Checker → Review',                     true,  0.80, 'Pemeriksaan silang dokumen bukti vs inputan sebelum review akhir',           2),
  ('RV', 'Review → Final / Approval',            true,  0.70, 'Review akhir kewajaran akun, saldo, dan persetujuan laporan',               3),
  ('RK', 'Rekonsiliasi (Bank/Kas/Piutang/Hutang)', true, 1.00, 'Pencocokan mutasi rekening koran, kas fisik, atau buku pembantu',           4),
  ('KR', 'Koreksi / Revisi Temuan',              true,  0.80, 'Perbaikan jurnal atau angka berdasarkan temuan checker/reviewer/klien',     5),
  ('JP', 'Jurnal Penyesuaian & Tutup Buku',      true,  0.90, 'Penyusutan, akrual, biaya dibayar dimuka, dan closing periode',             6),
  ('LP', 'Penyusunan Laporan Keuangan',          true,  1.00, 'Menyusun Laba Rugi, Neraca, Arus Kas, dan catatan laporan',                 7),
  ('PJ', 'Perpajakan (Hitung, Rekon & Lapor SPT)', true, 1.00, 'Perhitungan, rekonsiliasi, dan pelaporan PPh/PPN',                           8),
  ('PR', 'Payroll & BPJS',                       true,  0.80, 'Perhitungan gaji, lembur, PPh 21 karyawan, dan iuran BPJS',                 9),
  ('AR', 'Arsip & Kirim Dokumen Klien',          true,  0.50, 'Pengarsipan berkas kerja dan pengiriman laporan ke klien',                  10),
  ('LN', 'Lainnya',                              true,  0.50, 'Pekerjaan administratif atau khusus lainnya',                               11)
ON CONFLICT (kode) DO NOTHING;

-- 5. TRANSAKSI: Tindakan Harian (menggantikan/menyempurnakan rencana_harian)
CREATE TABLE IF NOT EXISTS tindakan_harian (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid REFERENCES users(id) ON DELETE CASCADE,
  tanggal_kerja    date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Makassar')::date),
  klien_id         uuid REFERENCES klien(id) ON DELETE RESTRICT,
  periode_bulan    integer NOT NULL CHECK (periode_bulan BETWEEN 1 AND 12),
  periode_tahun    integer NOT NULL,
  sistem_id        uuid REFERENCES m_sistem_kerja(id) ON DELETE RESTRICT,
  jenis_id         uuid REFERENCES m_jenis_tindakan(id) ON DELETE RESTRICT,
  uraian           text,
  -- pelacakan pengulangan (buka ulang)
  is_ulang         boolean NOT NULL DEFAULT false,
  ulang_dari_id    uuid REFERENCES tindakan_harian(id) ON DELETE SET NULL,
  ulang_ke         integer NOT NULL DEFAULT 0,
  alasan_ulang     text,
  -- waktu pelaksanaan (WITA / server timestamptz)
  mulai_at         timestamptz,
  selesai_at       timestamptz,
  durasi_detik     integer DEFAULT 0,
  -- status & closing
  status           text NOT NULL DEFAULT 'rencana'
    CHECK (status IN ('rencana','dikerjakan','selesai','lanjut','bermasalah')),
  kendala          text,
  kategori_kendala text,
  sifat_kendala    text CHECK (sifat_kendala IN ('eksternal','internal','teknis') OR sifat_kendala IS NULL),
  closing_at       timestamptz,
  created_at       timestamptz DEFAULT now()
);

-- Index untuk performa query KPI & validasi pengulangan
CREATE INDEX IF NOT EXISTS idx_th_tanggal_user ON tindakan_harian(tanggal_kerja, user_id);
CREATE INDEX IF NOT EXISTS idx_th_klien_periode ON tindakan_harian(klien_id, periode_tahun, periode_bulan);

-- 6. Trigger database: cegah pengulangan Data Entry → Checker di level database
CREATE OR REPLACE FUNCTION cek_pengulangan_tindakan()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_boleh boolean;
  v_sudah int;
BEGIN
  SELECT boleh_diulang INTO v_boleh FROM m_jenis_tindakan WHERE id = NEW.jenis_id;
  IF v_boleh = false THEN
    SELECT COUNT(*) INTO v_sudah
    FROM tindakan_harian
    WHERE klien_id = NEW.klien_id
      AND sistem_id = NEW.sistem_id
      AND periode_bulan = NEW.periode_bulan
      AND periode_tahun = NEW.periode_tahun
      AND jenis_id = NEW.jenis_id
      AND id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);
    IF v_sudah > 0 THEN
      RAISE EXCEPTION 'Data Entry → Checker tidak boleh diulang untuk klien, sistem, dan periode yang sama!';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cek_pengulangan ON tindakan_harian;
CREATE TRIGGER trg_cek_pengulangan
  BEFORE INSERT ON tindakan_harian
  FOR EACH ROW
  EXECUTE FUNCTION cek_pengulangan_tindakan();

-- 7. RLS terbuka untuk anon (sesuai permintaan user untuk kemudahan akses)
ALTER TABLE m_sistem_kerja ENABLE ROW LEVEL SECURITY;
ALTER TABLE m_jenis_tindakan ENABLE ROW LEVEL SECURITY;
ALTER TABLE tindakan_harian ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_m_sistem_kerja" ON m_sistem_kerja;
CREATE POLICY "anon_all_m_sistem_kerja" ON m_sistem_kerja FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_all_m_jenis_tindakan" ON m_jenis_tindakan;
CREATE POLICY "anon_all_m_jenis_tindakan" ON m_jenis_tindakan FOR ALL TO anon USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "anon_all_tindakan_harian" ON tindakan_harian;
CREATE POLICY "anon_all_tindakan_harian" ON tindakan_harian FOR ALL TO anon USING (true) WITH CHECK (true);

-- 8. Aktifkan Realtime untuk tabel baru
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE m_sistem_kerja;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE m_jenis_tindakan;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE tindakan_harian;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 9. KOMENTAR & ARAHAN KOLABORASI (gaya ClickUp / Monday.com)
CREATE TABLE IF NOT EXISTS tindakan_comments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tindakan_id  uuid REFERENCES tindakan_harian(id) ON DELETE CASCADE,
  user_id      uuid REFERENCES users(id) ON DELETE SET NULL,
  pesan        text NOT NULL,
  is_instruksi boolean NOT NULL DEFAULT false,
  mention_ids  uuid[] NOT NULL DEFAULT '{}',
  sudah_dibaca uuid[] NOT NULL DEFAULT '{}',
  created_at   timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tc_tindakan ON tindakan_comments(tindakan_id, created_at);

ALTER TABLE tindakan_comments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "anon_all_tindakan_comments" ON tindakan_comments;
CREATE POLICY "anon_all_tindakan_comments" ON tindakan_comments FOR ALL TO anon USING (true) WITH CHECK (true);

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE tindakan_comments;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
