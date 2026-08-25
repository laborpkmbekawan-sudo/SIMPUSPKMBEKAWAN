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
-- Catatan: kolom daftar_obat (jsonb) tiap item sekarang bisa punya field
-- tambahan: diserahkan (boolean), diserahkan_at (timestamptz text), diserahkan_oleh (uuid text).
-- Ini dipakai buat konfirmasi penyerahan per obat, bukan per resep utuh.
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
-- 15. SINKRONISASI: kolom obat yang sudah dipakai di apotek.html
--     tapi belum pernah tercatat di schema.sql ini (deployed duluan
--     langsung lewat SQL Editor). Aman diulang.
-- ============================================================
alter table obat add column if not exists dosis text;
alter table obat add column if not exists merk text;
alter table obat add column if not exists no_lot text;
alter table obat add column if not exists exp_date date;

create index if not exists idx_obat_exp on obat(exp_date);

-- ============================================================
-- 16. MODUL APOTEK — FASE 1: kategori obat, stok minimum,
--     Kartu Stok Digital (riwayat keluar-masuk per batch obat)
-- ============================================================

-- Kategori obat (buat laporan Narkotika/Psikotropika/SIPNAP nanti)
-- dan ambang stok minimum buat notifikasi alert.
alter table obat add column if not exists kategori text
  default 'bebas' check (kategori in ('narkotika','psikotropika','keras','bebas_terbatas','bebas'));
alter table obat add column if not exists bentuk_sediaan text;
alter table obat add column if not exists harga numeric(12,2);
alter table obat add column if not exists stok_minimum int not null default 10;
alter table obat add column if not exists nama_generik boolean not null default true;

-- Kartu Stok: setiap mutasi stok (masuk/keluar/opname/mutasi) tercatat
-- di sini, gak cuma update angka stok di tabel obat. Ini dasar buat
-- LPLPO, laporan, dan audit FEFO/FIFO nanti.
create table if not exists kartu_stok (
  id uuid primary key default gen_random_uuid(),
  obat_id uuid not null references obat(id) on delete cascade,
  tanggal date not null default current_date,
  jenis text not null check (jenis in ('masuk','keluar','opname_tambah','opname_kurang','mutasi_keluar','mutasi_masuk')),
  jumlah int not null,               -- selalu positif, arah ditentukan oleh "jenis"
  saldo_setelah int not null,        -- sisa stok batch ini setelah mutasi
  referensi text,                    -- no. resep / no. LPLPO / "Stok opname" / tujuan mutasi, dll
  keterangan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_kartu_stok_obat on kartu_stok(obat_id);
create index if not exists idx_kartu_stok_tanggal on kartu_stok(tanggal);

alter table kartu_stok enable row level security;
create policy "authenticated_all_kartu_stok" on kartu_stok for all to authenticated using (true) with check (true);

-- ============================================================
-- 17. KONFIRMASI PENYERAHAN PER OBAT: status resep tambah state
--     "sebagian" (sebagian obat di resep sudah diserahkan, belum semua).
--     Tiap item di daftar_obat (jsonb) sekarang bisa punya field
--     tambahan: diserahkan (boolean), diserahkan_at, diserahkan_oleh (uuid text).
-- ============================================================
alter table resep drop constraint if exists resep_status_check;
alter table resep add constraint resep_status_check
  check (status in ('menunggu', 'disiapkan', 'sebagian', 'diserahkan'));

-- ============================================================
-- 18. RACIKAN OBAT + JENIS OBAT + WAKTU MINUM (dokumentasi saja,
--     TIDAK PERLU DIJALANKAN — daftar_obat tetap jsonb, jadi field baru
--     otomatis diterima tanpa migrasi kolom).
--
--     Item obat biasa di daftar_obat sekarang bisa punya field tambahan:
--       jenis_obat: 'tablet_kapsul' | 'sirup' | 'salep' | 'tetes' | 'lainnya'
--       waktu: array teks, misal ['pagi','siang','sore']
--
--     Item racikan (dari menu Racikan Obat) berbentuk beda, ditandai
--     racikan: true, contoh:
--       {
--         "racikan": true,
--         "nama_racikan": "Puyer Batuk Anak",
--         "jumlah_bungkus": 10,
--         "satuan": "bungkus",
--         "aturan_pakai": "3x1 bungkus sehabis makan",
--         "waktu": ["pagi","siang","sore"],
--         "komponen": [
--           {"nama_obat": "Paracetamol", "dosis": "500mg", "jumlah_dipakai": 5, "satuan": "tablet"},
--           {"nama_obat": "CTM", "dosis": "4mg", "jumlah_dipakai": 5, "satuan": "tablet"}
--         ],
--         "diserahkan": true, "jumlah_diserahkan": 10, "diserahkan_at": "...", "diserahkan_oleh": "..."
--       }
--     Pas racikan diserahkan, stok tiap obat di "komponen" dipotong sesuai
--     jumlah_dipakai masing-masing (FEFO), bukan cuma 1 nama obat kayak resep biasa.
-- ============================================================

-- ============================================================
-- 19. MODUL APOTEK — FASE 2: MUTASI & PENERIMAAN
--     (Penerimaan SBBK dari Dinas, Mutasi Keluar ke Klaster/Pustu,
--     Mutasi Internal antar lokasi simpan, Retur)
-- ============================================================

-- Sinkronisasi kolom obat.jenis_item, sudah dipakai apotek.html sejak
-- Fase 1 tapi belum pernah tercatat resmi di schema.sql. Aman diulang.
alter table obat add column if not exists jenis_item text
  default 'obat' check (jenis_item in ('obat','bmhp'));
create index if not exists idx_obat_jenis_item on obat(jenis_item);

-- Master Pustu / Poskesdes / Polindes (tujuan mutasi di luar gedung induk)
create table if not exists pustu (
  id serial primary key,
  nama text not null,
  tipe text not null default 'pustu' check (tipe in ('pustu','poskesdes','polindes')),
  wilayah text,
  aktif boolean not null default true
);

-- Tambah pilihan jenis kartu_stok buat transaksi Fase 2.
alter table kartu_stok drop constraint if exists kartu_stok_jenis_check;
alter table kartu_stok add constraint kartu_stok_jenis_check
  check (jenis in ('masuk','keluar','opname_tambah','opname_kurang',
                    'mutasi_keluar','mutasi_masuk','penerimaan_sbbk',
                    'retur_masuk','retur_keluar'));

-- ---------- 19a. Penerimaan dari Dinas Kesehatan (SBBK) ----------
create table if not exists sbbk_penerimaan (
  id uuid primary key default gen_random_uuid(),
  no_sbbk text not null,
  tanggal_terima date not null default current_date,
  sumber text not null default 'dinas_kesehatan_kab'
    check (sumber in ('dinas_kesehatan_kab','gudang_farmasi_kab','droping_program')),
  petugas_id uuid references profil_pegawai(id),
  file_url text,
  status text not null default 'draft' check (status in ('draft','diverifikasi','selesai')),
  total_item int not null default 0,
  total_nilai numeric(14,2) not null default 0,
  catatan text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists sbbk_penerimaan_item (
  id uuid primary key default gen_random_uuid(),
  sbbk_id uuid not null references sbbk_penerimaan(id) on delete cascade,
  jenis_item text not null default 'obat' check (jenis_item in ('obat','bmhp')),
  nama_item text not null,
  dosis text,
  no_batch text,
  exp_date date,
  jumlah int not null,
  satuan text not null,
  harga_satuan numeric(12,2) not null default 0,
  subtotal numeric(14,2) not null default 0,
  obat_id uuid references obat(id) -- terisi setelah status "Selesai" (link ke master stok)
);

create index if not exists idx_sbbk_item_sbbk on sbbk_penerimaan_item(sbbk_id);

-- ---------- 19b. Mutasi Keluar (ke Klaster internal / Pustu) ----------
create table if not exists mutasi_keluar (
  id uuid primary key default gen_random_uuid(),
  tanggal date not null default current_date,
  tujuan_tipe text not null check (tujuan_tipe in ('klaster','pustu')),
  tujuan_klaster_id int references klaster(id),
  tujuan_pustu_id int references pustu(id),
  penerima_nama text,
  penerima_jabatan text,
  catatan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create table if not exists mutasi_keluar_item (
  id uuid primary key default gen_random_uuid(),
  mutasi_id uuid not null references mutasi_keluar(id) on delete cascade,
  obat_id uuid not null references obat(id),
  jenis_item text not null default 'obat' check (jenis_item in ('obat','bmhp')),
  jumlah int not null,
  satuan text not null
);

create index if not exists idx_mutasi_keluar_item_mutasi on mutasi_keluar_item(mutasi_id);

-- ---------- 19c. Mutasi Internal (antar lokasi simpan, gak ubah total stok) ----------
create table if not exists mutasi_internal (
  id uuid primary key default gen_random_uuid(),
  tanggal date not null default current_date,
  obat_id uuid not null references obat(id),
  jenis_item text not null default 'obat' check (jenis_item in ('obat','bmhp')),
  jumlah int not null,
  dari_lokasi text not null,
  ke_lokasi text not null,
  catatan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

-- ---------- 19d. Retur (klaster/Pustu -> Farmasi, atau Farmasi -> Dinas) ----------
create table if not exists retur (
  id uuid primary key default gen_random_uuid(),
  tanggal date not null default current_date,
  arah text not null check (arah in ('masuk','ke_dinas')), -- masuk = balik ke Farmasi, ke_dinas = keluar ke Dinas
  asal_tujuan text, -- nama klaster/Pustu asal (arah=masuk) atau catatan tujuan Dinas (arah=ke_dinas)
  obat_id uuid not null references obat(id),
  jenis_item text not null default 'obat' check (jenis_item in ('obat','bmhp')),
  jumlah int not null,
  satuan text not null,
  alasan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

alter table pustu enable row level security;
alter table sbbk_penerimaan enable row level security;
alter table sbbk_penerimaan_item enable row level security;
alter table mutasi_keluar enable row level security;
alter table mutasi_keluar_item enable row level security;
alter table mutasi_internal enable row level security;
alter table retur enable row level security;

create policy "authenticated_all_pustu" on pustu for all to authenticated using (true) with check (true);
create policy "authenticated_all_sbbk_penerimaan" on sbbk_penerimaan for all to authenticated using (true) with check (true);
create policy "authenticated_all_sbbk_penerimaan_item" on sbbk_penerimaan_item for all to authenticated using (true) with check (true);
create policy "authenticated_all_mutasi_keluar" on mutasi_keluar for all to authenticated using (true) with check (true);
create policy "authenticated_all_mutasi_keluar_item" on mutasi_keluar_item for all to authenticated using (true) with check (true);
create policy "authenticated_all_mutasi_internal" on mutasi_internal for all to authenticated using (true) with check (true);
create policy "authenticated_all_retur" on retur for all to authenticated using (true) with check (true);

insert into pustu (nama, tipe, wilayah) values
  ('Pustu Contoh 1', 'pustu', 'Ganti sesuai wilayah kerja'),
  ('Pustu Contoh 2', 'pustu', 'Ganti sesuai wilayah kerja')
on conflict do nothing;

-- ============================================================
-- SELESAI. Setelah run schema ini:
-- 1. Buat user pertama lewat Supabase Dashboard > Authentication > Add user
-- 2. Insert baris ke profil_pegawai dengan id = user id yang baru dibuat
-- 3. Kalau ini update dari database yang sudah jalan, cukup jalankan
--    bagian yang belum pernah dijalankan (nomor terbaru) — aman, idempotent
-- ============================================================
