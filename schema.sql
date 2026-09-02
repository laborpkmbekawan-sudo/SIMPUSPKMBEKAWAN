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
-- 20. MODUL APOTEK — LPLPO (Laporan Pemakaian & Lembar Permintaan Obat)
--     Header per periode (lplpo) + item per obat/BMHP (lplpo_item).
--     Aman dijalankan ulang.
-- ============================================================

-- Sumber anggaran per item (DAK 2017 E-Katalog, BHP DAK 2018, APBN Diare, dst)
-- Dipakai buat group-header di tabel LPLPO. Kosong = "Tanpa Sumber Dana".
alter table obat add column if not exists sumber_dana text;
create index if not exists idx_obat_sumber_dana on obat(sumber_dana);

-- ---------- Header LPLPO per periode ----------
create table if not exists lplpo (
  id uuid primary key default gen_random_uuid(),
  periode_bulan int not null check (periode_bulan between 1 and 12),
  periode_tahun int not null check (periode_tahun between 2020 and 2100),
  status text not null default 'draft'
    check (status in ('draft', 'diajukan', 'disetujui_dinas', 'diterima')),
  tanggal_cetak date not null default current_date,
  petugas_id uuid references profil_pegawai(id),
  tanggal_diajukan timestamptz,
  tanggal_disetujui timestamptz,
  tanggal_diterima timestamptz,
  catatan text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (periode_bulan, periode_tahun)
);

create index if not exists idx_lplpo_periode on lplpo(periode_tahun, periode_bulan);
create index if not exists idx_lplpo_status on lplpo(status);

-- ---------- Item per obat/BMHP di 1 LPLPO ----------
-- Nama/satuan/harga/sumber_dana di-snapshot pas generate, biar laporan lama
-- gak berubah walau master obat diedit belakangan.
create table if not exists lplpo_item (
  id uuid primary key default gen_random_uuid(),
  lplpo_id uuid not null references lplpo(id) on delete cascade,
  obat_id uuid not null references obat(id),
  jenis_item text not null default 'obat' check (jenis_item in ('obat', 'bmhp')),

  -- snapshot data master (biar histori gak berubah kalau master diedit)
  nama_item text not null,
  dosis text,
  satuan text not null,
  harga_satuan numeric(12,2) not null default 0,
  sumber_dana text,

  -- angka laporan
  stok_awal int not null default 0,          -- carry-over stok akhir sistem periode lalu
  penerimaan int not null default 0,         -- auto dari SBBK, editable
  pemakaian int not null default 0,          -- auto dari mutasi_keluar (klaster+Pustu), editable
  stok_akhir_sistem int not null default 0,  -- = stok_awal + penerimaan - pemakaian
  sisa_stok_fisik int not null default 0,    -- input manual hasil stok opname
  selisih int not null default 0,            -- = sisa_stok_fisik - stok_akhir_sistem
  rata2_3bulan numeric(10,2) not null default 0,  -- rata pemakaian 3 LPLPO terakhir
  permintaan int not null default 0,         -- default (rata2_3bulan*2) - sisa_stok_fisik, editable
  catatan text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (lplpo_id, obat_id)
);

create index if not exists idx_lplpo_item_lplpo on lplpo_item(lplpo_id);
create index if not exists idx_lplpo_item_obat on lplpo_item(obat_id);
create index if not exists idx_lplpo_item_jenis on lplpo_item(jenis_item);

alter table lplpo enable row level security;
alter table lplpo_item enable row level security;

create policy "authenticated_all_lplpo" on lplpo for all to authenticated using (true) with check (true);
create policy "authenticated_all_lplpo_item" on lplpo_item for all to authenticated using (true) with check (true);

-- ============================================================
-- 21. MODUL APOTEK — LAPORAN: Indikator Peresepan (POR) & Rekap PIO
--     Cuma butuh 1 kolom baru buat tandai obat golongan antibiotik
--     (dipakai hitung % resep dengan antibiotik). Rekap PIO reuse
--     field pio_diberikan yang sudah ada di daftar_obat (jsonb resep).
-- ============================================================
alter table obat add column if not exists is_antibiotik boolean not null default false;

-- ============================================================
-- 22. MODUL APOTEK — LAPORAN: Formularium Nasional (Fornas)
--     Tabel referensi Fornas (bukan cuma flag boolean) + link ke
--     master obat, biar bisa lihat kelas terapi & cari per item.
-- ============================================================

-- ---------- Tabel referensi Fornas ----------
create table if not exists fornas_referensi (
  id uuid primary key default gen_random_uuid(),
  kelas_terapi text not null,
  nama_obat text not null,
  bentuk_sediaan text,
  kekuatan text,
  keterangan text,
  aktif boolean not null default true,
  created_at timestamptz not null default now()
);

create unique index if not exists idx_fornas_referensi_unik
  on fornas_referensi (nama_obat, bentuk_sediaan, coalesce(kekuatan, ''));
create index if not exists idx_fornas_referensi_kelas on fornas_referensi(kelas_terapi);
create index if not exists idx_fornas_referensi_nama on fornas_referensi(nama_obat);

alter table fornas_referensi enable row level security;
create policy "authenticated_all_fornas_referensi" on fornas_referensi for all to authenticated using (true) with check (true);

-- ---------- Link master obat ke referensi Fornas ----------
-- Kosong (null) = belum dicocokkan / di luar Fornas, ditandai manual
-- oleh Farmasi lewat Master Data Obat.
alter table obat add column if not exists fornas_ref_id uuid references fornas_referensi(id);
create index if not exists idx_obat_fornas_ref on obat(fornas_ref_id);

-- ---------- Seed data referensi Fornas ----------
-- Daftar ini REPRESENTATIF (obat esensial yang lazim dipakai di Puskesmas),
-- BUKAN salinan lengkap dokumen resmi Fornas Kepmenkes (ribuan item, semua
-- tingkat layanan). Farmasi tetap perlu cek & tambah item sesuai Fornas
-- terbaru yang berlaku, lewat menu Kelola Referensi Fornas di aplikasi.
insert into fornas_referensi (kelas_terapi, nama_obat, bentuk_sediaan, kekuatan, keterangan) values
('Analgesik, Antipiretik, Antiinflamasi Nonsteroid', 'Paracetamol', 'Tablet', '500 mg', ''),
('Analgesik, Antipiretik, Antiinflamasi Nonsteroid', 'Paracetamol', 'Sirup', '120 mg/5 ml', ''),
('Analgesik, Antipiretik, Antiinflamasi Nonsteroid', 'Asam Mefenamat', 'Tablet', '500 mg', ''),
('Analgesik, Antipiretik, Antiinflamasi Nonsteroid', 'Ibuprofen', 'Tablet', '400 mg', ''),
('Analgesik, Antipiretik, Antiinflamasi Nonsteroid', 'Natrium Diklofenak', 'Tablet', '50 mg', ''),
('Anestetik', 'Lidokain HCl', 'Injeksi', '2%', ''),
('Antialergi dan Obat untuk Anafilaksis', 'Chlorpheniramine Maleate (CTM)', 'Tablet', '4 mg', ''),
('Antialergi dan Obat untuk Anafilaksis', 'Cetirizine', 'Tablet', '10 mg', ''),
('Antialergi dan Obat untuk Anafilaksis', 'Difenhidramin HCl', 'Injeksi', '10 mg/ml', ''),
('Antialergi dan Obat untuk Anafilaksis', 'Epinefrin (Adrenalin)', 'Injeksi', '0,1%', 'Emergensi anafilaksis'),
('Antidotum dan Obat Lain untuk Keracunan', 'Norit / Karbon Aktif', 'Tablet', '250 mg', ''),
('Antiepilepsi-Antikonvulsi', 'Fenitoin', 'Tablet', '100 mg', ''),
('Antiepilepsi-Antikonvulsi', 'Diazepam', 'Tablet', '2 mg', ''),
('Antiepilepsi-Antikonvulsi', 'Diazepam', 'Injeksi', '5 mg/ml', ''),
('Obat Infeksi Parasit', 'Albendazol', 'Tablet', '400 mg', ''),
('Obat Infeksi Parasit', 'Pirantel Pamoat', 'Tablet', '125 mg', ''),
('Antibakteri', 'Amoksisilin', 'Tablet', '500 mg', ''),
('Antibakteri', 'Amoksisilin', 'Sirup Kering', '125 mg/5 ml', ''),
('Antibakteri', 'Ampisilin', 'Kapsul', '500 mg', ''),
('Antibakteri', 'Ciprofloxacin', 'Tablet', '500 mg', ''),
('Antibakteri', 'Cotrimoxazole (Sulfametoksazol-Trimetoprim)', 'Tablet', '480 mg', ''),
('Antibakteri', 'Cotrimoxazole', 'Suspensi', '240 mg/5 ml', ''),
('Antibakteri', 'Eritromisin', 'Tablet', '500 mg', ''),
('Antibakteri', 'Metronidazol', 'Tablet', '500 mg', ''),
('Antibakteri', 'Doksisiklin', 'Kapsul', '100 mg', ''),
('Antibakteri', 'Kloramfenikol', 'Kapsul', '250 mg', ''),
('Antituberkulosis', 'OAT Kombipak Kategori 1', 'Tablet', 'Fase Intensif', 'Program TB Nasional'),
('Antituberkulosis', 'Rifampisin + Isoniazid (FDC)', 'Tablet', '150/75 mg', ''),
('Antifungi', 'Griseofulvin', 'Tablet', '125 mg', ''),
('Antifungi', 'Ketokonazol', 'Krim', '2%', ''),
('Antifungi', 'Nistatin', 'Suspensi Oral', '100.000 IU/ml', ''),
('Obat Saluran Cerna', 'Antasida DOEN (Al(OH)3 + Mg(OH)2)', 'Tablet Kunyah', null, ''),
('Obat Saluran Cerna', 'Antasida', 'Sirup', null, ''),
('Obat Saluran Cerna', 'Omeprazole', 'Kapsul', '20 mg', ''),
('Obat Saluran Cerna', 'Ranitidin', 'Tablet', '150 mg', ''),
('Obat Saluran Cerna', 'Domperidon', 'Tablet', '10 mg', ''),
('Obat Saluran Cerna', 'Oralit', 'Serbuk', 'Sachet 200 ml', ''),
('Obat Saluran Cerna', 'Zink', 'Tablet Dispersible', '20 mg', 'Diare balita'),
('Obat Saluran Cerna', 'Attapulgite', 'Tablet', '600 mg', ''),
('Obat Saluran Cerna', 'Laktulosa', 'Sirup', '3,3 g/5 ml', ''),
('Obat Saluran Napas', 'Salbutamol', 'Tablet', '2 mg', ''),
('Obat Saluran Napas', 'Salbutamol', 'Inhalasi Aerosol', '100 mcg/dosis', ''),
('Obat Saluran Napas', 'Ambroksol', 'Sirup', '15 mg/5 ml', ''),
('Obat Saluran Napas', 'Gliseril Guaiakolat (GG)', 'Tablet', '100 mg', ''),
('Obat Saluran Napas', 'Dekstrometorfan', 'Sirup', '10 mg/5 ml', ''),
('Obat Saluran Napas', 'Aminofilin', 'Tablet', '200 mg', ''),
('Obat Kardiovaskular', 'Amlodipin', 'Tablet', '5 mg', ''),
('Obat Kardiovaskular', 'Amlodipin', 'Tablet', '10 mg', ''),
('Obat Kardiovaskular', 'Captopril', 'Tablet', '25 mg', ''),
('Obat Kardiovaskular', 'Hidroklorotiazid (HCT)', 'Tablet', '25 mg', ''),
('Obat Kardiovaskular', 'Furosemid', 'Tablet', '40 mg', ''),
('Obat Kardiovaskular', 'Bisoprolol', 'Tablet', '5 mg', ''),
('Obat Kardiovaskular', 'Simvastatin', 'Tablet', '10 mg', ''),
('Obat Kardiovaskular', 'Digoksin', 'Tablet', '0,25 mg', ''),
('Hormon dan Antidiabetes', 'Metformin', 'Tablet', '500 mg', ''),
('Hormon dan Antidiabetes', 'Glibenklamid', 'Tablet', '5 mg', ''),
('Hormon dan Antidiabetes', 'Insulin Manusia (Human Insulin)', 'Injeksi', '100 IU/ml', ''),
('Hormon dan Antidiabetes', 'Levotiroksin', 'Tablet', '100 mcg', ''),
('Vitamin dan Mineral', 'Vitamin B Kompleks', 'Tablet', null, ''),
('Vitamin dan Mineral', 'Vitamin B1 (Tiamin)', 'Tablet', '50 mg', ''),
('Vitamin dan Mineral', 'Vitamin C', 'Tablet', '50 mg', ''),
('Vitamin dan Mineral', 'Asam Folat', 'Tablet', '1 mg', ''),
('Vitamin dan Mineral', 'Tablet Tambah Darah (Fe + Asam Folat)', 'Tablet', '60 mg', 'Program ibu hamil'),
('Vitamin dan Mineral', 'Kalsium Laktat', 'Tablet', '500 mg', ''),
('Vitamin dan Mineral', 'Vitamin A', 'Kapsul', '100.000 IU', 'Program balita'),
('Vitamin dan Mineral', 'Vitamin A', 'Kapsul', '200.000 IU', 'Program balita/nifas'),
('Obat Mata', 'Kloramfenikol', 'Tetes Mata', '0,5%', ''),
('Obat Mata', 'Kloramfenikol', 'Salep Mata', '1%', ''),
('Obat THT', 'H2O2 (Karbol Gliserin)', 'Tetes Telinga', '3%', ''),
('Obat Kulit', 'Betametason', 'Krim', '0,1%', ''),
('Obat Kulit', 'Hidrokortison', 'Krim', '1%', ''),
('Obat Kulit', 'Permetrin', 'Krim/Lotion', '5%', 'Skabisid'),
('Obat Kulit', 'Asam Salisilat + Sulfur', 'Salep', null, ''),
('Obat Kulit', 'Gentamisin', 'Salep/Krim', '0,1%', ''),
('Antiseptik-Disinfektan', 'Povidon Iodine', 'Larutan', '10%', ''),
('Antiseptik-Disinfektan', 'Alkohol 70%', 'Larutan', null, ''),
('Larutan Elektrolit dan Nutrisi Parenteral', 'Ringer Laktat', 'Infus', '500 ml', ''),
('Larutan Elektrolit dan Nutrisi Parenteral', 'NaCl 0,9%', 'Infus', '500 ml', ''),
('Larutan Elektrolit dan Nutrisi Parenteral', 'Dekstrosa 5%', 'Infus', '500 ml', ''),
('Larutan Elektrolit dan Nutrisi Parenteral', 'Dekstrosa 40%', 'Injeksi', '25 ml', 'Emergensi hipoglikemia'),
('Kesehatan Ibu', 'Metildopa', 'Tablet', '250 mg', ''),
('Kesehatan Ibu', 'Nifedipin', 'Tablet', '10 mg', 'Tokolitik/hipertensi kehamilan'),
('Kesehatan Ibu', 'Oksitosin', 'Injeksi', '10 IU/ml', ''),
('Kesehatan Ibu', 'MgSO4', 'Injeksi', '20%', 'Preeklampsia/eklampsia'),
('Kesehatan Ibu', 'Metilergometrin', 'Injeksi', '0,2 mg/ml', ''),
('Kontrasepsi', 'Pil KB Kombinasi', 'Tablet', null, 'Program KB'),
('Kontrasepsi', 'Suntik KB (DMPA)', 'Injeksi', '150 mg/ml', 'Program KB'),
('Anestetik Lokal', 'Etil Klorida', 'Semprot', null, ''),
('Vaksin', 'Vaksin BCG', 'Injeksi', null, 'Program imunisasi'),
('Vaksin', 'Vaksin DPT-HB-Hib (Pentavalen)', 'Injeksi', null, 'Program imunisasi'),
('Vaksin', 'Vaksin Polio (OPV)', 'Tetes Oral', null, 'Program imunisasi'),
('Vaksin', 'Vaksin Campak-Rubella (MR)', 'Injeksi', null, 'Program imunisasi'),
('Vaksin', 'Vaksin Tetanus Toksoid (TT)', 'Injeksi', null, 'Program imunisasi ibu hamil')
on conflict do nothing;

-- ============================================================
-- 23. MODUL APOTEK — LAPORAN: High Alert & LASA, Vaksin Cold Chain
--     High Alert/LASA cukup flag boolean di master obat (+ nama
--     pasangan LASA buat catatan). Cold chain butuh tabel baru
--     buat log suhu kulkas vaksin harian (pagi/sore).
-- ============================================================
alter table obat add column if not exists is_high_alert boolean not null default false;
alter table obat add column if not exists is_lasa boolean not null default false;
alter table obat add column if not exists lasa_pasangan text;
alter table obat add column if not exists perlu_cold_chain boolean not null default false;

create table if not exists vaksin_suhu_log (
  id uuid primary key default gen_random_uuid(),
  tanggal date not null,
  waktu text not null check (waktu in ('pagi','sore')),
  suhu_celsius numeric(4,1) not null,
  kondisi text not null default 'normal' check (kondisi in ('normal','diluar_range')),
  keterangan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now(),
  unique (tanggal, waktu)
);

create index if not exists idx_vaksin_suhu_log_tanggal on vaksin_suhu_log(tanggal);
alter table vaksin_suhu_log enable row level security;
create policy "authenticated_all_vaksin_suhu_log" on vaksin_suhu_log for all to authenticated using (true) with check (true);

-- ============================================================
-- 24. MODUL APOTEK — LAPORAN: Keselamatan Pasien
--     Medication Error, Efek Samping Obat (KTD/ADR), FMEA
--     Kefarmasian. Nama pasien free-text (bukan FK pasien) —
--     laporan ini kadang perlu tetap tercatat walau identitas
--     pasien gak lengkap/anonim demi kepatuhan lapor insiden.
-- ============================================================
create table if not exists medication_error_log (
  id uuid primary key default gen_random_uuid(),
  tanggal date not null,
  tahap text not null check (tahap in ('peresepan','pengkajian_resep','peracikan','penyerahan','penggunaan')),
  jenis_error text not null,
  nama_pasien text,
  obat_terkait text,
  deskripsi text not null,
  tingkat_keparahan text not null check (tingkat_keparahan in ('nyaris_cidera','tanpa_cidera','cidera_ringan','cidera_sedang','cidera_berat','kematian')),
  tindak_lanjut text,
  pelapor_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create table if not exists efek_samping_obat (
  id uuid primary key default gen_random_uuid(),
  tanggal date not null,
  nama_pasien text not null,
  obat_terkait text not null,
  gejala text not null,
  tingkat_keparahan text not null check (tingkat_keparahan in ('ringan','sedang','berat')),
  tindakan text,
  pelapor_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create table if not exists fmea_kefarmasian (
  id uuid primary key default gen_random_uuid(),
  proses text not null,
  failure_mode text not null,
  efek text,
  penyebab text,
  severity int not null check (severity between 1 and 10),
  occurrence int not null check (occurrence between 1 and 10),
  detection int not null check (detection between 1 and 10),
  rpn int generated always as (severity * occurrence * detection) stored,
  tindakan_perbaikan text,
  pj text,
  tanggal date not null default current_date,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_medication_error_tanggal on medication_error_log(tanggal);
create index if not exists idx_efek_samping_tanggal on efek_samping_obat(tanggal);
create index if not exists idx_fmea_rpn on fmea_kefarmasian(rpn desc);

alter table medication_error_log enable row level security;
alter table efek_samping_obat enable row level security;
alter table fmea_kefarmasian enable row level security;

create policy "authenticated_all_medication_error_log" on medication_error_log for all to authenticated using (true) with check (true);
create policy "authenticated_all_efek_samping_obat" on efek_samping_obat for all to authenticated using (true) with check (true);
create policy "authenticated_all_fmea_kefarmasian" on fmea_kefarmasian for all to authenticated using (true) with check (true);

-- ============================================================
-- 25. PENDAFTARAN — Triase Prioritas/Gawat Darurat (Standar 7.2.3)
--     Loket bisa tandai pasien darurat saat daftar kunjungan.
--     Antrian diurutkan prioritas dulu baru no urut biasa, jadi
--     panggilAntrean() otomatis ambil pasien darurat duluan
--     tanpa perlu ubah logika panggil (cukup ubah urutan query).
-- ============================================================
alter table kunjungan add column if not exists is_prioritas boolean not null default false;
alter table kunjungan add column if not exists keterangan_prioritas text;
create index if not exists idx_kunjungan_prioritas on kunjungan(tanggal, is_prioritas);

-- ============================================================
-- 26. DASHBOARD PENDAFTARAN — Kontrol Lanjutan Jatuh Tempo
--     Dokter/perawat/bidan isi tanggal kontrol berikutnya di RM,
--     Dashboard Pendaftaran tampilkan alert kalau sudah lewat tanggal.
--     (Input field di rekam-medis.html menyusul di sesi berikutnya.)
-- ============================================================
alter table rekam_medis add column if not exists tanggal_kontrol_berikutnya date;
create index if not exists idx_rm_kontrol_berikutnya on rekam_medis(tanggal_kontrol_berikutnya);

-- ============================================================
-- 27. SKRINING AWAL — Faktor Risiko PTM sebelum pasien masuk klaster
--     Diisi petugas pendaftaran, jadi bagian pengkajian awal RM.
--     1 kunjungan = maksimal 1 skrining.
-- ============================================================
create table if not exists skrining_awal (
  id uuid primary key default gen_random_uuid(),
  kunjungan_id uuid not null unique references kunjungan(id),
  merokok boolean not null default false,
  riwayat_keluarga_dm boolean not null default false,
  riwayat_keluarga_hipertensi boolean not null default false,
  riwayat_penyakit_menular text,
  gula_darah_sewaktu text,
  kolesterol text,
  lingkar_perut text,
  imt numeric(5,2),
  catatan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_skrining_kunjungan on skrining_awal(kunjungan_id);

alter table skrining_awal enable row level security;
create policy "authenticated_all_skrining_awal" on skrining_awal for all to authenticated using (true) with check (true);

-- ============================================================
-- 28. RUJUKAN — Internal antar klaster & FKRTL (rumah sakit/faskes lanjutan)
--     Rujukan internal otomatis bikin kunjungan baru di klaster tujuan.
-- ============================================================
create table if not exists rujukan (
  id uuid primary key default gen_random_uuid(),
  kunjungan_asal_id uuid not null references kunjungan(id),
  kunjungan_tujuan_id uuid references kunjungan(id), -- diisi kalau rujukan internal (kunjungan baru di klaster tujuan)
  jenis text not null check (jenis in ('internal', 'fkrtl')),
  klaster_tujuan_id int references klaster(id), -- diisi kalau internal
  faskes_tujuan text, -- diisi kalau fkrtl, mis. "RSUD Dumai"
  diagnosa_rujukan text,
  alasan_rujukan text not null,
  catatan text,
  status text not null default 'diajukan' check (status in ('diajukan', 'diterima', 'selesai', 'batal')),
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_rujukan_kunjungan_asal on rujukan(kunjungan_asal_id);
create index if not exists idx_rujukan_tanggal on rujukan(created_at);

alter table rujukan enable row level security;
create policy "authenticated_all_rujukan" on rujukan for all to authenticated using (true) with check (true);

-- ============================================================
-- 29. KERAHASIAAN & HAK AKSES — Consent pasien & log akses RM
-- ============================================================
create table if not exists consent_pasien (
  id uuid primary key default gen_random_uuid(),
  pasien_id uuid not null references pasien(id),
  jenis_consent text not null check (jenis_consent in ('berbagi_asuransi', 'berbagi_faskes_lain', 'penelitian', 'lainnya')),
  pihak_penerima text not null,
  tanggal_consent date not null default current_date,
  catatan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_consent_pasien on consent_pasien(pasien_id);

alter table consent_pasien enable row level security;
create policy "authenticated_all_consent_pasien" on consent_pasien for all to authenticated using (true) with check (true);

create table if not exists log_akses_rm (
  id uuid primary key default gen_random_uuid(),
  pasien_id uuid not null references pasien(id),
  kunjungan_id uuid references kunjungan(id),
  aksi text not null check (aksi in ('lihat', 'ubah')),
  keterangan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_log_akses_rm_pasien on log_akses_rm(pasien_id);
create index if not exists idx_log_akses_rm_tanggal on log_akses_rm(created_at);

alter table log_akses_rm enable row level security;
create policy "authenticated_all_log_akses_rm" on log_akses_rm for all to authenticated using (true) with check (true);

-- ============================================================
-- 31. RUJUKAN INTERNAL — dokter/perawat rujuk pasien ke klaster lain
-- di puskesmas yg sama (poli umum -> poli gigi/lab/dsb), otomatis
-- bikin antrian baru di klaster tujuan.
-- ============================================================
create table if not exists rujukan_internal (
  id uuid primary key default gen_random_uuid(),
  kunjungan_asal_id uuid not null references kunjungan(id),
  kunjungan_tujuan_id uuid not null references kunjungan(id),
  klaster_tujuan_id int not null references klaster(id),
  alasan text not null,
  status text not null default 'menunggu' check (status in ('menunggu', 'selesai', 'batal')),
  dibuat_oleh uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_rujukan_internal_asal on rujukan_internal(kunjungan_asal_id);
create index if not exists idx_rujukan_internal_pasien on rujukan_internal(kunjungan_tujuan_id);

alter table rujukan_internal enable row level security;
create policy "authenticated_all_rujukan_internal" on rujukan_internal for all to authenticated using (true) with check (true);
-- ============================================================
create table if not exists survei_kepuasan (
  id uuid primary key default gen_random_uuid(),
  kunjungan_id uuid references kunjungan(id),
  nama_pasien text,
  skor_kecepatan int not null check (skor_kecepatan between 1 and 5),
  skor_keramahan int not null check (skor_keramahan between 1 and 5),
  skor_kejelasan_informasi int not null check (skor_kejelasan_informasi between 1 and 5),
  skor_kebersihan int not null check (skor_kebersihan between 1 and 5),
  saran text,
  created_at timestamptz not null default now()
);

create index if not exists idx_survei_tanggal on survei_kepuasan(created_at);

alter table survei_kepuasan enable row level security;
create policy "authenticated_all_survei_kepuasan" on survei_kepuasan for all to authenticated using (true) with check (true);
-- Pasien isi survei via scan QR di struk pendaftaran, tanpa login (role anon).
-- Insert-only: anon gak bisa select/update/delete data survei siapapun.
create policy "anon_insert_survei_kepuasan" on survei_kepuasan for insert to anon with check (true);

-- ============================================================
-- 32. GABUNG REKAM MEDIS — deteksi & gabung RM duplikat
-- ============================================================
alter table pasien add column if not exists digabung_ke_id uuid references pasien(id);
create index if not exists idx_pasien_digabung on pasien(digabung_ke_id);

create or replace function gabung_rekam_medis(p_utama uuid, p_duplikat uuid)
returns void as $$
begin
  if p_utama = p_duplikat then
    raise exception 'Pasien utama dan duplikat tidak boleh sama';
  end if;

  update kunjungan set pasien_id = p_utama where pasien_id = p_duplikat;
  update consent_pasien set pasien_id = p_utama where pasien_id = p_duplikat;
  update log_akses_rm set pasien_id = p_utama where pasien_id = p_duplikat;

  update pasien set digabung_ke_id = p_utama where id = p_duplikat;
end;
$$ language plpgsql;

-- ============================================================
-- 33. RUJUKAN LAB — centang "Perlu Lab" di rekam medis otomatis
-- bikin antrian baru di klaster LK (Laboratorium). Hasil lab dicatat
-- petugas lab, tapi tetap kebaca balik di riwayat rekam medis pasien.
-- ============================================================
alter table kunjungan add column if not exists tipe_layanan text not null default 'reguler'
  check (tipe_layanan in ('reguler','lab'));

create table if not exists rujukan_lab (
  id uuid primary key default gen_random_uuid(),
  kunjungan_asal_id uuid not null references kunjungan(id),
  kunjungan_tujuan_id uuid not null references kunjungan(id),
  jenis_pemeriksaan text not null,
  status text not null default 'menunggu' check (status in ('menunggu', 'selesai')),
  dibuat_oleh uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create table if not exists hasil_lab (
  id uuid primary key default gen_random_uuid(),
  rujukan_lab_id uuid not null references rujukan_lab(id),
  kunjungan_asal_id uuid not null references kunjungan(id),
  item_hasil jsonb not null default '[]', -- [{nama_pemeriksaan, hasil, satuan, nilai_rujukan}]
  petugas_id uuid not null references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_rujukan_lab_asal on rujukan_lab(kunjungan_asal_id);
create index if not exists idx_rujukan_lab_tujuan on rujukan_lab(kunjungan_tujuan_id);
create index if not exists idx_hasil_lab_asal on hasil_lab(kunjungan_asal_id);

alter table rujukan_lab enable row level security;
alter table hasil_lab enable row level security;
create policy "authenticated_all_rujukan_lab" on rujukan_lab for all to authenticated using (true) with check (true);
create policy "authenticated_all_hasil_lab" on hasil_lab for all to authenticated using (true) with check (true);

-- ============================================================
-- 34. TINDAKAN MEDIS — tindakan non-obat (jahit luka, nebulizer,
-- pasang infus, dll), dicatat bareng rekam medis per kunjungan.
-- ============================================================
create table if not exists tindakan_medis (
  id uuid primary key default gen_random_uuid(),
  kunjungan_id uuid not null references kunjungan(id),
  rekam_medis_id uuid references rekam_medis(id),
  daftar_tindakan jsonb not null default '[]', -- [{nama_tindakan, catatan}]
  petugas_id uuid not null references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_tindakan_kunjungan on tindakan_medis(kunjungan_id);

alter table tindakan_medis enable row level security;
create policy "authenticated_all_tindakan_medis" on tindakan_medis for all to authenticated using (true) with check (true);

-- ============================================================
-- 35. PEMINJAMAN RM FISIK — buat puskesmas yang masih hybrid (sebagian
-- arsip fisik). Petugas catat siapa pinjam, tujuan, tanggal pinjam,
-- rencana kembali, dan tanggal kembali aktual (null = belum kembali).
-- ============================================================
create table if not exists peminjaman_rm_fisik (
  id uuid primary key default gen_random_uuid(),
  pasien_id uuid not null references pasien(id),
  peminjam text not null, -- nama/unit yang minjam, mis. "dr. Ani - Poli Umum"
  tujuan text,
  tanggal_pinjam date not null default current_date,
  tanggal_rencana_kembali date,
  tanggal_kembali_aktual date,
  catatan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_pinjam_rm_pasien on peminjaman_rm_fisik(pasien_id);
create index if not exists idx_pinjam_rm_tanggal on peminjaman_rm_fisik(tanggal_pinjam);

alter table peminjaman_rm_fisik enable row level security;
create policy "authenticated_all_peminjaman_rm_fisik" on peminjaman_rm_fisik for all to authenticated using (true) with check (true);

-- ============================================================
-- 36. DISTRIBUSI BERKAS ANTAR UNIT — berkas RM fisik dikirim dari satu
-- klaster/unit ke klaster/unit lain (mis. loket -> poli umum -> lab).
-- ============================================================
create table if not exists distribusi_berkas_rm (
  id uuid primary key default gen_random_uuid(),
  pasien_id uuid not null references pasien(id),
  klaster_asal_id int references klaster(id),
  klaster_tujuan_id int references klaster(id),
  tanggal_kirim date not null default current_date,
  tanggal_terima date,
  status text not null default 'dikirim' check (status in ('dikirim', 'diterima', 'hilang')),
  catatan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_distribusi_berkas_pasien on distribusi_berkas_rm(pasien_id);
create index if not exists idx_distribusi_berkas_tanggal on distribusi_berkas_rm(tanggal_kirim);

alter table distribusi_berkas_rm enable row level security;
create policy "authenticated_all_distribusi_berkas_rm" on distribusi_berkas_rm for all to authenticated using (true) with check (true);

-- ============================================================
-- 37. AUDIT TRAIL — data sensitif (pasien, rekam_medis, resep).
-- Dicatat OTOMATIS lewat trigger database (bukan kode aplikasi), jadi
-- gak bisa kelewat/dilewatin walau perubahan dilakukan langsung dari
-- Supabase SQL Editor atau lewat jalur lain di luar frontend.
--
-- audit_log cuma bisa DIISI lewat trigger (security definer) — role
-- authenticated cuma dikasih izin SELECT, gak ada insert/update/delete.
-- Jadi walau token pegawai bocor, jejak audit gak bisa dipalsu/dihapus.
-- ============================================================
create table if not exists audit_log (
  id uuid primary key default gen_random_uuid(),
  tabel text not null,
  record_id uuid,
  aksi text not null check (aksi in ('insert', 'update', 'delete')),
  data_lama jsonb,
  data_baru jsonb,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_audit_log_tabel on audit_log(tabel);
create index if not exists idx_audit_log_record on audit_log(record_id);
create index if not exists idx_audit_log_tanggal on audit_log(created_at);
create index if not exists idx_audit_log_petugas on audit_log(petugas_id);

alter table audit_log enable row level security;
create policy "authenticated_read_audit_log" on audit_log for select to authenticated using (true);

create or replace function fn_audit_log() returns trigger
language plpgsql security definer as $$
declare
  v_petugas uuid;
begin
  -- auth.uid() baca dari JWT request yang lagi jalan (bukan dari session
  -- fungsi ini), jadi tetap kebaca siapa pegawai yang beneran ngetrigger
  -- perubahan walau fungsinya security definer.
  v_petugas := auth.uid();

  if (tg_op = 'DELETE') then
    insert into audit_log(tabel, record_id, aksi, data_lama, petugas_id)
    values (tg_table_name, old.id, 'delete', to_jsonb(old), v_petugas);
    return old;
  elsif (tg_op = 'UPDATE') then
    insert into audit_log(tabel, record_id, aksi, data_lama, data_baru, petugas_id)
    values (tg_table_name, new.id, 'update', to_jsonb(old), to_jsonb(new), v_petugas);
    return new;
  else
    insert into audit_log(tabel, record_id, aksi, data_baru, petugas_id)
    values (tg_table_name, new.id, 'insert', to_jsonb(new), v_petugas);
    return new;
  end if;
end;
$$;

drop trigger if exists trg_audit_pasien on pasien;
create trigger trg_audit_pasien after insert or update or delete on pasien
  for each row execute function fn_audit_log();

drop trigger if exists trg_audit_rekam_medis on rekam_medis;
create trigger trg_audit_rekam_medis after insert or update or delete on rekam_medis
  for each row execute function fn_audit_log();

drop trigger if exists trg_audit_resep on resep;
create trigger trg_audit_resep after insert or update or delete on resep
  for each row execute function fn_audit_log();

-- ============================================================
-- 38. MANAJEMEN SESI AKTIF — lacak sesi login tiap pegawai per
-- perangkat/browser, biar admin bisa lihat siapa lagi login dari mana
-- dan bisa paksa logout kalau perlu (perangkat hilang/dicuri, dsb).
--
-- CATATAN KETERBATASAN: Supabase Auth gak punya API buat cabut satu sesi
-- pegawai lain secara instan dari server (butuh JWT sesi itu, yang gak
-- kita punya). Jadi "Paksa Logout" kerjanya: tandai baris ini dicabut,
-- lalu browser pegawai bersangkutan polling tabel ini tiap ~30 detik dan
-- logout sendiri begitu kedeteksi — bukan instan, tapi otomatis dalam
-- hitungan detik selama browsernya masih terbuka/online.
-- ============================================================
create table if not exists sesi_aktif (
  id uuid primary key default gen_random_uuid(),
  pegawai_id uuid not null references profil_pegawai(id) on delete cascade,
  sesi_token text not null,
  perangkat text,
  login_at timestamptz not null default now(),
  last_active timestamptz not null default now(),
  dicabut boolean not null default false,
  dicabut_at timestamptz
);

create unique index if not exists idx_sesi_aktif_token on sesi_aktif(sesi_token);
create index if not exists idx_sesi_aktif_pegawai on sesi_aktif(pegawai_id);

alter table sesi_aktif enable row level security;
create policy "authenticated_all_sesi_aktif" on sesi_aktif for all to authenticated using (true) with check (true);

-- ============================================================
-- 39. MODUL UGD — FASE 1: Kunjungan UGD (dasar Dashboard & Triase)
--     kunjungan_ugd adalah EKSTENSI dari kunjungan, bukan tabel
--     terpisah — 1 kunjungan (klaster LK) bisa punya maks 1 baris
--     kunjungan_ugd. Field klinis (SOAP, tindakan, rujukan) tetap
--     pakai tabel rekam_medis/tindakan_medis/rujukan yang sudah ada,
--     supaya gak dobel-bikin.
-- ============================================================
create table if not exists kunjungan_ugd (
  id uuid primary key default gen_random_uuid(),
  kunjungan_id uuid not null unique references kunjungan(id),
  pasien_id uuid not null references pasien(id),
  status_ugd text not null default 'baru' check (status_ugd in ('baru', 'ditangani', 'observasi', 'dirujuk', 'pulang', 'meninggal')),
  triase_warna text check (triase_warna in ('merah', 'kuning', 'hijau', 'hitam')),
  waktu_triase timestamptz,
  petugas_triase_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now(),
  created_by uuid references profil_pegawai(id)
);

create index if not exists idx_kunjungan_ugd_status on kunjungan_ugd(status_ugd);
create index if not exists idx_kunjungan_ugd_triase on kunjungan_ugd(triase_warna);
create index if not exists idx_kunjungan_ugd_pasien on kunjungan_ugd(pasien_id);

alter table kunjungan_ugd enable row level security;
create policy "authenticated_all_kunjungan_ugd" on kunjungan_ugd for all to authenticated using (true) with check (true);

drop trigger if exists trg_audit_kunjungan_ugd on kunjungan_ugd;
create trigger trg_audit_kunjungan_ugd after insert or update or delete on kunjungan_ugd
  for each row execute function fn_audit_log();

-- ============================================================
-- 40. MODUL UGD — FASE 2: Pemeriksaan & Tindakan Gawat Darurat
--     Reuse tabel yang sudah ada (kunjungan, tindakan_medis, resep,
--     rujukan_lab) — cuma nambah kolom yang belum ada, gak bikin
--     tabel baru. Kolom vital tambahan & is_cito berguna juga buat
--     modul lain di luar UGD (RM umum, Farmasi, Lab).
-- ============================================================
alter table kunjungan add column if not exists kesadaran text;
alter table kunjungan add column if not exists gcs text;
alter table kunjungan add column if not exists saturasi_o2 text;

alter table kunjungan_ugd add column if not exists diagnosis_kerja text;

alter table rujukan_lab add column if not exists is_cito boolean not null default false;
alter table resep add column if not exists is_cito boolean not null default false;

create index if not exists idx_rujukan_lab_cito on rujukan_lab(is_cito) where is_cito = true;
create index if not exists idx_resep_cito on resep(is_cito) where is_cito = true;

-- ============================================================
-- 41. MODUL UGD — FASE 3: Observasi & Rujukan Gawat Darurat
--     Observasi: tabel baru observasi_ugd, khusus buat catatan
--     tanda vital BERKALA (kunjungan cuma nyimpen 1 set vital
--     terakhir, gak cukup buat pasien yang dipantau berulang).
--     Rujukan Gawat Darurat: reuse tabel rujukan yang sudah ada
--     (dipakai bareng modul Pendaftaran) — tidak ada tabel baru.
-- ============================================================
create table if not exists observasi_ugd (
  id uuid primary key default gen_random_uuid(),
  kunjungan_ugd_id uuid not null references kunjungan_ugd(id),
  waktu timestamptz not null default now(),
  kesadaran text,
  tekanan_darah text,
  nadi text,
  respirasi text,
  suhu text,
  saturasi_o2 text,
  keterangan text,
  petugas_id uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_observasi_ugd_kunjungan on observasi_ugd(kunjungan_ugd_id);
create index if not exists idx_observasi_ugd_waktu on observasi_ugd(waktu);

alter table observasi_ugd enable row level security;
create policy "authenticated_all_observasi_ugd" on observasi_ugd for all to authenticated using (true) with check (true);

drop trigger if exists trg_audit_observasi_ugd on observasi_ugd;
create trigger trg_audit_observasi_ugd after insert or update or delete on observasi_ugd
  for each row execute function fn_audit_log();

-- ============================================================
-- 42. KLASTER 2 (IBU, ANAK & REMAJA) — FASE 1: Scaffold & Dashboard.
--     Kunjungan Klaster 2 REUSE tabel kunjungan yang sudah ada
--     (klaster_id = K2), gak ada tabel baru buat itu.
--     Tabel kehamilan: dasar pelacakan status hamil pasien, dipakai
--     buat kategori sasaran "Bumil" di Dashboard, dan nanti dipakai
--     lagi oleh fitur ANC/Persalinan/Nifas.
-- ============================================================
create table if not exists kehamilan (
  id uuid primary key default gen_random_uuid(),
  pasien_id uuid not null references pasien(id),
  hpht date,
  hpl date,
  gravida int,
  paritas int,
  status text not null default 'hamil' check (status in ('hamil', 'bersalin', 'nifas', 'selesai')),
  catatan text,
  created_by uuid references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_kehamilan_pasien on kehamilan(pasien_id);
create index if not exists idx_kehamilan_status on kehamilan(status);

alter table kehamilan enable row level security;
create policy "authenticated_all_kehamilan" on kehamilan for all to authenticated using (true) with check (true);

drop trigger if exists trg_audit_kehamilan on kehamilan;
create trigger trg_audit_kehamilan after insert or update or delete on kehamilan
  for each row execute function fn_audit_log();

-- ============================================================
-- 43. KLASTER 2 — FASE 2: ANC (Antenatal Care).
--     Reuse tabel kehamilan (section 42) yang sudah ada — ANC
--     adalah catatan pemeriksaan BERKALA selama kehamilan itu.
-- ============================================================
create table if not exists kunjungan_anc (
  id uuid primary key default gen_random_uuid(),
  kehamilan_id uuid not null references kehamilan(id),
  kunjungan_id uuid references kunjungan(id),
  usia_kehamilan_minggu int,
  tekanan_darah text,
  berat_badan text,
  tinggi_fundus text,
  lila text,
  hb text,
  status_gizi text,
  skrining_risiko jsonb not null default '[]'::jsonb,
  catatan text,
  petugas_id uuid not null references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_kunjungan_anc_kehamilan on kunjungan_anc(kehamilan_id);

alter table kunjungan_anc enable row level security;
create policy "authenticated_all_kunjungan_anc" on kunjungan_anc for all to authenticated using (true) with check (true);

drop trigger if exists trg_audit_kunjungan_anc on kunjungan_anc;
create trigger trg_audit_kunjungan_anc after insert or update or delete on kunjungan_anc
  for each row execute function fn_audit_log();

-- ============================================================
-- 44. KLASTER 2 — FASE 3: Imunisasi TT/Td Ibu Hamil.
--     Reuse tabel kehamilan yang sudah ada.
-- ============================================================
create table if not exists imunisasi_tt (
  id uuid primary key default gen_random_uuid(),
  kehamilan_id uuid not null references kehamilan(id),
  jenis text not null check (jenis in ('TT1', 'TT2', 'TT3', 'TT4', 'TT5', 'Td (Booster)')),
  tanggal date not null default current_date,
  catatan text,
  petugas_id uuid not null references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_imunisasi_tt_kehamilan on imunisasi_tt(kehamilan_id);

alter table imunisasi_tt enable row level security;
create policy "authenticated_all_imunisasi_tt" on imunisasi_tt for all to authenticated using (true) with check (true);

drop trigger if exists trg_audit_imunisasi_tt on imunisasi_tt;
create trigger trg_audit_imunisasi_tt after insert or update or delete on imunisasi_tt
  for each row execute function fn_audit_log();

-- ============================================================
-- 45. KLASTER 2 — FASE 4: Pencatatan Persalinan.
--     Reuse tabel kehamilan. Setelah persalinan disimpan, status
--     kehamilan otomatis pindah ke 'nifas'.
-- ============================================================
create table if not exists persalinan (
  id uuid primary key default gen_random_uuid(),
  kehamilan_id uuid not null references kehamilan(id),
  tanggal timestamptz not null default now(),
  jenis text not null check (jenis in ('normal', 'penyulit')),
  penyulit_catatan text,
  penolong text,
  tempat text,
  kondisi_ibu text,
  bayi_hidup boolean,
  jenis_kelamin_bayi text check (jenis_kelamin_bayi in ('L', 'P')),
  bb_lahir text,
  pb_lahir text,
  catatan text,
  petugas_id uuid not null references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_persalinan_kehamilan on persalinan(kehamilan_id);

alter table persalinan enable row level security;
create policy "authenticated_all_persalinan" on persalinan for all to authenticated using (true) with check (true);

drop trigger if exists trg_audit_persalinan on persalinan;
create trigger trg_audit_persalinan after insert or update or delete on persalinan
  for each row execute function fn_audit_log();

-- ============================================================
-- 46. KLASTER 2 — FASE 5: Nifas (KF1-KF4) & Rujukan Komplikasi.
--     Nifas: tabel baru kunjungan_nifas, reuse kehamilan (status
--     'nifas'). Setelah KF4 disimpan, status kehamilan otomatis
--     pindah ke 'selesai'.
--     Rujukan Komplikasi: reuse tabel rujukan yang sudah ada,
--     tidak ada tabel baru.
-- ============================================================
create table if not exists kunjungan_nifas (
  id uuid primary key default gen_random_uuid(),
  kehamilan_id uuid not null references kehamilan(id),
  tahap text not null check (tahap in ('KF1', 'KF2', 'KF3', 'KF4')),
  tanggal date not null default current_date,
  tekanan_darah text,
  suhu text,
  involusi_uterus text,
  lochea text,
  tanda_bahaya jsonb not null default '[]'::jsonb,
  kb_pasca_salin text,
  konseling_gizi boolean not null default false,
  catatan text,
  petugas_id uuid not null references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_kunjungan_nifas_kehamilan on kunjungan_nifas(kehamilan_id);

alter table kunjungan_nifas enable row level security;
create policy "authenticated_all_kunjungan_nifas" on kunjungan_nifas for all to authenticated using (true) with check (true);

drop trigger if exists trg_audit_kunjungan_nifas on kunjungan_nifas;
create trigger trg_audit_kunjungan_nifas after insert or update or delete on kunjungan_nifas
  for each row execute function fn_audit_log();

-- ============================================================
-- 47. KLASTER 2 — FASE 6: Bayi & Balita — KN (Kunjungan Neonatal)
--     & Tumbuh Kembang (SDIDTK, termasuk deteksi stunting/gizi).
--     Pasien bayi/balita REUSE tabel pasien yang sudah ada,
--     dicari langsung (bukan dari daftar kehamilan), karena gak
--     semua bayi tercatat lewat modul Persalinan ini.
-- ============================================================
create table if not exists kunjungan_kn (
  id uuid primary key default gen_random_uuid(),
  pasien_id uuid not null references pasien(id),
  tahap text not null check (tahap in ('KN1', 'KN2', 'KN3')),
  tanggal date not null default current_date,
  berat_badan text,
  suhu text,
  kondisi_umum text,
  asi_eksklusif boolean not null default false,
  tanda_bahaya jsonb not null default '[]'::jsonb,
  catatan text,
  petugas_id uuid not null references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_kunjungan_kn_pasien on kunjungan_kn(pasien_id);

alter table kunjungan_kn enable row level security;
create policy "authenticated_all_kunjungan_kn" on kunjungan_kn for all to authenticated using (true) with check (true);

drop trigger if exists trg_audit_kunjungan_kn on kunjungan_kn;
create trigger trg_audit_kunjungan_kn after insert or update or delete on kunjungan_kn
  for each row execute function fn_audit_log();

create table if not exists tumbuh_kembang (
  id uuid primary key default gen_random_uuid(),
  pasien_id uuid not null references pasien(id),
  tanggal date not null default current_date,
  berat_badan text,
  tinggi_panjang_badan text,
  lingkar_kepala text,
  status_gizi text,
  status_stunting text,
  status_perkembangan text,
  catatan text,
  petugas_id uuid not null references profil_pegawai(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_tumbuh_kembang_pasien on tumbuh_kembang(pasien_id);

alter table tumbuh_kembang enable row level security;
create policy "authenticated_all_tumbuh_kembang" on tumbuh_kembang for all to authenticated using (true) with check (true);

drop trigger if exists trg_audit_tumbuh_kembang on tumbuh_kembang;
create trigger trg_audit_tumbuh_kembang after insert or update or delete on tumbuh_kembang
  for each row execute function fn_audit_log();

-- ============================================================
-- SELESAI. Setelah run schema ini:
-- 1. Buat user pertama lewat Supabase Dashboard > Authentication > Add user
-- 2. Insert baris ke profil_pegawai dengan id = user id yang baru dibuat
-- 3. Kalau ini update dari database yang sudah jalan, cukup jalankan
--    bagian yang belum pernah dijalankan (nomor terbaru) — aman, idempotent
-- ============================================================
