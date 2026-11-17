-- =============================================
-- SiKerja Pro — Database Migration
-- Jalankan di: Supabase Dashboard > SQL Editor
-- =============================================

-- 1. USERS
create table if not exists users (
  id          uuid primary key default gen_random_uuid(),
  nama        text not null,
  role        text not null default 'asisten' check (role in ('admin','asisten')),
  pin         text,
  created_at  timestamptz default now()
);

-- 2. KLIEN
create table if not exists klien (
  id           uuid primary key default gen_random_uuid(),
  nama         text not null,
  nama_kontak  text,
  npwp         text,
  bidang       text,
  kontak       text,
  email        text,
  catatan      text,
  created_at   timestamptz default now()
);

-- 3. PEKERJAAN (termasuk subtask via parent_id)
create table if not exists pekerjaan (
  id          uuid primary key default gen_random_uuid(),
  judul       text not null,
  klien_id    uuid references klien(id) on delete set null,
  kategori    text,
  user_id     uuid references users(id) on delete set null,
  asisten_id  uuid references users(id) on delete set null,
  status      text not null default 'Belum Dimulai' check (status in ('Belum Dimulai','Dalam Proses','Selesai')),
  prioritas   text not null default 'Normal' check (prioritas in ('Normal','Urgen')),
  tanggal     date,
  deadline    date,
  catatan     text,
  parent_id   uuid references pekerjaan(id) on delete cascade,
  created_by  uuid references users(id) on delete set null,
  created_at  timestamptz default now()
);

-- 4. ABSENSI
create table if not exists absensi (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references users(id) on delete cascade,
  nama        text,
  tanggal     date not null,
  jam         text,
  tipe        text default 'Masuk',
  created_at  timestamptz default now()
);

-- 5. DOCS
create table if not exists docs (
  id            uuid primary key default gen_random_uuid(),
  judul         text not null,
  body          text,
  klien_id      uuid references klien(id) on delete set null,
  pek_id        uuid references pekerjaan(id) on delete set null,
  nama_file     text,
  link_dokumen  text,
  updated_at    date default current_date,
  created_at    timestamptz default now()
);

-- 6. COMMENTS
create table if not exists comments (
  id          uuid primary key default gen_random_uuid(),
  pek_id      uuid references pekerjaan(id) on delete cascade,
  user_id     uuid references users(id) on delete set null,
  teks        text not null,
  waktu       text,
  created_at  timestamptz default now()
);

-- 7. TIMELOGS
create table if not exists timelogs (
  id          uuid primary key default gen_random_uuid(),
  pek_id      uuid references pekerjaan(id) on delete cascade,
  user_id     uuid references users(id) on delete set null,
  durasi      integer default 0,
  tanggal     date,
  created_at  timestamptz default now()
);

-- =============================================
-- ROW LEVEL SECURITY — izinkan anon key penuh
-- (app pakai anon key langsung tanpa Supabase Auth)
-- =============================================
alter table users     enable row level security;
alter table klien     enable row level security;
alter table pekerjaan enable row level security;
alter table absensi   enable row level security;
alter table docs      enable row level security;
alter table comments  enable row level security;
alter table timelogs  enable row level security;

-- Policy: anon bisa baca & tulis semua tabel
do $$
declare
  tbl text;
begin
  foreach tbl in array array['users','klien','pekerjaan','absensi','docs','comments','timelogs']
  loop
    execute format('create policy "anon_all_%s" on %I for all to anon using (true) with check (true)', tbl, tbl);
  end loop;
end $$;

-- =============================================
-- DATA AWAL — 1 user Admin
-- =============================================
insert into users (nama, role, pin) values
  ('Admin', 'admin', ''),
  ('Asisten 1', 'asisten', '')
on conflict do nothing;
