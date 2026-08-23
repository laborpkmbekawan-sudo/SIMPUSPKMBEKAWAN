-- ============================================================
-- SIMPUS (Sistem Informasi Manajemen Puskesmas)
-- Schema: Login/User, Klaster (ILP), Pendaftaran, Rekam Medis
-- Jalankan di Supabase SQL Editor (Project > SQL Editor > New query)
-- ============================================================

-- ------------------------------------------------------------
-- 1. TABEL KLASTER (referensi tetap, sesuai ILP terbaru)
-- ------------------------------------------------------------
create table if not exists klaster (
  id serial primary key,
  kode text unique not null,       -- K1, K2, K3, K4, LK
  nama text not null,
  keterangan text
);

insert into klaster (kode, nama, keterangan) values
  ('K1', 'Manajemen', 'Administrasi, SDM, surat menyurat, BOK, aset, laporan'),
  ('K2', 'Ibu dan Anak', 'KIA, imunisasi, KB, tumbuh kembang anak'),
  ('K3', 'Usia Dewasa dan Lansia', 'Pelayanan umum dewasa, PTM, lansia'),
  ('K4', 'Penanggulangan Penyakit Menular', 'TB, HIV, kusta, kesehatan lingkungan'),
  ('LK', 'Lintas Klaster', 'Gawat darurat, gigi, gizi, laboratorium, farmasi')
on conflict (kode) do nothing;

-- ------------------------------------------------------------
-- 2. TABEL USER / KARYAWAN (profil tambahan di atas Supabase Auth)
-- Supabase Auth sudah handle login (email + password).
-- Tabel ini nyimpen data tambahan: nama, NIP, role, klaster.
-- ------------------------------------------------------------
create table if not exists profil_pegawai (
  id uuid primary key references auth.users(id) on delete cascade,
  nama text not null,
  nip text,
  role text not null default 'petugas', -- dokter, perawat, bidan, apoteker, admin, petugas
  klaster_id int references klaster(id),
  aktif boolean not null default true,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 3. TABEL PASIEN
-- ------------------------------------------------------------
create table if not exists pasien (
  id uuid primary key default gen_random_uuid(),
  nik text unique not null,
  nama text not null,
  tempat_lahir text,
  tanggal_lahir date not null,
  jenis_kelamin text not null check (jenis_kelamin in ('L', 'P')),
  alamat text,
  rt_rw text,
  desa_kelurahan text,
  kecamatan text,
  no_hp text,
  status_bpjs text default 'tidak_ada' check (status_bpjs in ('aktif', 'tidak_aktif', 'tidak_ada')),
  no_bpjs text,
  no_kk text,
  pekerjaan text,
  gol_darah text,
  alergi_obat text,
  created_at timestamptz not null default now(),
  created_by uuid references profil_pegawai(id)
);

create index if not exists idx_pasien_nik on pasien(nik);
create index if not exists idx_pasien_nama on pasien(nama);

-- ------------------------------------------------------------
-- 4. TABEL KUNJUNGAN
-- ------------------------------------------------------------
create table if not exists kunjungan (
  id uuid primary key default gen_random_uuid(),
  no_kunjungan text unique not null,       -- generate: YYYYMMDD-0001
  pasien_id uuid not null references pasien(id),
  tanggal date not null default current_date,
  klaster_id int not null references klaster(id),
  jenis_bayar text not null check (jenis_bayar in ('BPJS', 'Umum')),
  no_antrian int not null,
  status text not null default 'menunggu' check (status in ('menunggu', 'dipanggil', 'diperiksa', 'selesai', 'batal')),
  keluhan_awal text,
  created_at timestamptz not null default now(),
  created_by uuid references profil_pegawai(id)
);

create index if not exists idx_kunjungan_tanggal on kunjungan(tanggal);
create index if not exists idx_kunjungan_pasien on kunjungan(pasien_id);
create index if not exists idx_kunjungan_status on kunjungan(status);

-- ------------------------------------------------------------
-- 5. TABEL REKAM MEDIS (format SOAP)
-- ------------------------------------------------------------
create table if not exists rekam_medis (
  id uuid primary key default gen_random_uuid(),
  kunjungan_id uuid not null references kunjungan(id),
  subjektif text,
  objektif text,
  tekanan_darah text,
  suhu text,
  nadi text,
  respirasi text,
  berat_badan text,
  tinggi_badan text,
  assessment text,
  kode_icd10 text,
  plan text,
  butuh_lab boolean not null default false,
  butuh_obat boolean not null default false,
  petugas_id uuid not null references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_rm_kunjungan on rekam_medis(kunjungan_id);

-- ------------------------------------------------------------
-- 6. TABEL RESEP (link ke apotek, disiapkan buat modul lanjut)
-- ------------------------------------------------------------
create table if not exists resep (
  id uuid primary key default gen_random_uuid(),
  kunjungan_id uuid not null references kunjungan(id),
  rekam_medis_id uuid references rekam_medis(id),
  dokter_id uuid not null references profil_pegawai(id),
  daftar_obat jsonb not null default '[]', -- [{nama_obat, dosis, jumlah, aturan_pakai}]
  status text not null default 'menunggu' check (status in ('menunggu', 'disiapkan', 'diserahkan')),
  diserahkan_oleh uuid references profil_pegawai(id),
  diserahkan_at timestamptz,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 7. FUNGSI: generate nomor kunjungan otomatis (YYYYMMDD-0001)
-- ------------------------------------------------------------
create or replace function generate_no_kunjungan()
returns text as $$
declare
  today_str text := to_char(current_date, 'YYYYMMDD');
  next_seq int;
  result text;
begin
  select count(*) + 1 into next_seq
  from kunjungan
  where tanggal = current_date;

  result := today_str || '-' || lpad(next_seq::text, 4, '0');
  return result;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 8. FUNGSI: generate nomor antrian per klaster per hari
-- ------------------------------------------------------------
create or replace function generate_no_antrian(p_klaster_id int)
returns int as $$
declare
  next_num int;
begin
  select coalesce(max(no_antrian), 0) + 1 into next_num
  from kunjungan
  where klaster_id = p_klaster_id and tanggal = current_date;

  return next_num;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 9. ROW LEVEL SECURITY (wajib aktif — hanya user login yang bisa akses)
-- ------------------------------------------------------------
alter table profil_pegawai enable row level security;
alter table pasien enable row level security;
alter table kunjungan enable row level security;
alter table rekam_medis enable row level security;
alter table resep enable row level security;
alter table klaster enable row level security;

-- Semua user yang sudah login (authenticated) boleh baca & tulis.
-- (Bisa diperketat per role nanti kalau perlu.)
create policy "authenticated_read_klaster" on klaster for select to authenticated using (true);

create policy "authenticated_read_profil" on profil_pegawai for select to authenticated using (true);
create policy "authenticated_update_own_profil" on profil_pegawai for update to authenticated using (auth.uid() = id);

create policy "authenticated_all_pasien" on pasien for all to authenticated using (true) with check (true);
create policy "authenticated_all_kunjungan" on kunjungan for all to authenticated using (true) with check (true);
create policy "authenticated_all_rekam_medis" on rekam_medis for all to authenticated using (true) with check (true);
create policy "authenticated_all_resep" on resep for all to authenticated using (true) with check (true);

-- ============================================================
-- 10. UPDATE: No. RM otomatis, riwayat obat, tanda vital di pendaftaran
-- ============================================================

-- No. Rekam Medis, generate otomatis pas pasien baru disimpan
create sequence if not exists no_rm_seq start 1;

alter table pasien add column if not exists no_rm text unique;
alter table pasien add column if not exists riwayat_obat text;

create or replace function generate_no_rm()
returns trigger as $$
begin
  if new.no_rm is null or trim(new.no_rm) = '' then
    new.no_rm := lpad(nextval('no_rm_seq')::text, 6, '0');
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_generate_no_rm on pasien;
create trigger trg_generate_no_rm
before insert on pasien
for each row execute function generate_no_rm();

create index if not exists idx_pasien_no_rm on pasien(no_rm);
create index if not exists idx_pasien_no_bpjs on pasien(no_bpjs);

-- Tanda vital pindah ke kunjungan, diisi petugas pendaftaran (triase awal)
alter table kunjungan add column if not exists tekanan_darah text;
alter table kunjungan add column if not exists suhu text;
alter table kunjungan add column if not exists nadi text;
alter table kunjungan add column if not exists respirasi text;
alter table kunjungan add column if not exists berat_badan text;
alter table kunjungan add column if not exists tinggi_badan text;

-- ============================================================
-- 11. MODUL APOTEK: master obat (dikelola akun farmasi) + resep
-- ============================================================

create table if not exists obat (
  id uuid primary key default gen_random_uuid(),
  nama_obat text not null,
  satuan text not null default 'tablet', -- tablet, kapsul, botol, tube, strip, dll
  stok int not null default 0,
  kode_obat text,
  keterangan text,
  updated_by uuid references profil_pegawai(id),
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists idx_obat_nama on obat(nama_obat);
alter table obat enable row level security;
create policy "authenticated_all_obat" on obat for all to authenticated using (true) with check (true);

-- ============================================================
-- 12. Jenis kunjungan (baru/lama), tercatat eksplisit per kunjungan
-- ============================================================
alter table kunjungan add column if not exists jenis_kunjungan text
  check (jenis_kunjungan in ('baru','lama'));

-- ============================================================
-- 13. Kolom tambahan biar form Registrasi Pasien sesuai SOP:
--     data pasien (Nama KK, Pendidikan, Dusun) + data kunjungan
--     (Petugas Loket, Lokasi Pemeriksaan, Jenis Pasien, Pengirim,
--     Kode Administrasi Pasien)
-- ============================================================
alter table pasien add column if not exists nama_kk text;
alter table pasien add column if not exists pendidikan text;
alter table pasien add column if not exists dusun text;

alter table kunjungan add column if not exists petugas_loket text;
alter table kunjungan add column if not exists lokasi_pemeriksaan text;
alter table kunjungan add column if not exists jenis_pasien text;
alter table kunjungan add column if not exists pengirim text default 'Sendiri';
alter table kunjungan add column if not exists kode_administrasi_pasien text;

-- ============================================================
-- 14. TABEL AKSES LINTAS KLASTER (dipakai js/supabaseClient.js:
--     getProfilSaya() join ke pegawai_klaster & hak_akses).
--     Tabel ini belum pernah ada di schema — kalau belum dijalankan,
--     SEMUA login gagal karena query profil error. Jalankan bagian
--     ini sebelum lanjut apa pun. Aman diulang (if not exists).
-- ============================================================

-- Klaster tambahan yang bisa diakses satu pegawai, di luar klaster_id utamanya
-- (misal: bidan yang juga bantu di Klaster Ibu&Anak dan Lansia).
create table if not exists pegawai_klaster (
  id uuid primary key default gen_random_uuid(),
  pegawai_id uuid not null references profil_pegawai(id) on delete cascade,
  klaster_id int not null references klaster(id),
  keterangan text,
  created_at timestamptz not null default now(),
  unique (pegawai_id, klaster_id)
);

-- Hak akses granular per modul (index.html, rekam-medis.html, apotek.html,
-- dst pakai kode modul sendiri, misal "rekam_medis"), opsional dibatasi per
-- klaster (klaster_id null = berlaku semua klaster). level: lihat/layani/penuh.
create table if not exists hak_akses (
  id uuid primary key default gen_random_uuid(),
  pegawai_id uuid not null references profil_pegawai(id) on delete cascade,
  modul_kode text not null,
  klaster_id int references klaster(id),
  level text not null default 'lihat' check (level in ('lihat', 'layani', 'penuh')),
  created_at timestamptz not null default now()
);

create index if not exists idx_pegawai_klaster_pegawai on pegawai_klaster(pegawai_id);
create index if not exists idx_hak_akses_pegawai on hak_akses(pegawai_id);

alter table pegawai_klaster enable row level security;
alter table hak_akses enable row level security;

create policy "authenticated_read_pegawai_klaster" on pegawai_klaster for select to authenticated using (true);
create policy "authenticated_read_hak_akses" on hak_akses for select to authenticated using (true);

-- Gak ada policy insert/update/delete buat role authenticated di dua tabel
-- ini secara sengaja: tulis cuma boleh lewat Edge Function kelola-pegawai
-- yang pakai service_role (bypass RLS). Jadi walau token admin bocor,
-- gak bisa langsung ubah akses lewat REST API biasa.

-- ============================================================
-- SELESAI. Setelah run schema ini:
-- 1. Buat user pertama lewat Supabase Dashboard > Authentication > Add user
-- 2. Insert baris ke profil_pegawai dengan id = user id yang baru dibuat
-- 3. Kalau ini update dari database yang sudah jalan, cukup jalankan
--    bagian yang belum pernah dijalankan (nomor terbaru) — aman, idempotent
-- ============================================================
