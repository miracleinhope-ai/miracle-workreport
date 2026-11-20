-- =============================================
-- SiKerja Pro — Migrasi: Tabel Rencana Harian
-- Jalankan di: Supabase Dashboard > SQL Editor
-- =============================================

create table if not exists rencana_harian (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references users(id) on delete cascade,
  tanggal     date not null default current_date,
  klien_id    uuid references klien(id) on delete set null,
  judul       text not null,
  catatan     text,
  urutan      integer default 1,
  status      text not null default 'rencana' check (status in ('rencana','selesai')),
  laporan     text,
  closing_at  timestamptz,
  created_at  timestamptz default now()
);

alter table rencana_harian enable row level security;

create policy "anon_all_rencana_harian" on rencana_harian
  for all to anon using (true) with check (true);

alter publication supabase_realtime add table rencana_harian;
