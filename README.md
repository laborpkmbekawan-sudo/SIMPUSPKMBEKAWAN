# SIMPUS UPTD PUSKESMAS BEKAWAN — Setup

## 1. Buat project Supabase (gratis)
1. Buka https://supabase.com → Sign up → New Project
2. Catat: Project URL dan anon public key (Settings → API)

## 2. Jalankan schema database
1. Di dashboard Supabase → SQL Editor → New query
2. Copy-paste seluruh isi `schema.sql` → klik Run

## 3. Buat user pegawai pertama (buat login)
1. Dashboard Supabase → Authentication → Users → Add user
2. Isi email + password → simpan
3. Copy User UID yang muncul
4. SQL Editor → jalankan (ganti nilai sesuai):
```sql
insert into profil_pegawai (id, nama, nip, role, klaster_id)
values ('paste-user-uid-disini', 'Nama Pegawai', '1234567890', 'admin', 1);
```

## 4. Hubungkan kode ke Supabase
Buka `js/supabaseClient.js`, ganti dua baris ini:
```js
const SUPABASE_URL = "https://xxxxxxxxxxxx.supabase.co";
const SUPABASE_ANON_KEY = "isi_anon_key_disini";
```
dengan punya project kamu sendiri.

## 5. Coba jalan lokal dulu
Buka folder di VS Code → klik kanan `login.html` → "Open with Live Server"
(kalau belum ada, install extension "Live Server" dulu di VS Code)

## 6. Upload ke GitHub
1. Buat repo baru di github.com
2. Di VS Code terminal:
```bash
git init
git add .
git commit -m "SIMPUS awal - pendaftaran dan rekam medis"
git branch -M main
git remote add origin https://github.com/USERNAME/NAMA-REPO.git
git push -u origin main
```

## 7. Deploy ke Vercel (gratis, auto-update tiap push)
1. Buka https://vercel.com → Sign up pakai akun GitHub
2. Add New Project → pilih repo yang tadi
3. Deploy (gak perlu ubah setting apa-apa, ini situs statis)
4. Dapat link publik, bisa diakses dari HP/laptop mana aja

## Struktur file
```
simpus/
├── login.html          halaman login
├── index.html           pendaftaran pasien + antrian
├── rekam-medis.html     isi rekam medis pasien
├── schema.sql            struktur database, jalankan di Supabase
├── js/supabaseClient.js  koneksi ke Supabase
└── css/style.css         tampilan
```

## Alur pakai
1. Buka `login.html` → login pakai akun yang dibuat di langkah 3
2. Cari NIK pasien di halaman Pendaftaran → kalau belum ada, isi data baru
3. Pilih klaster tujuan → daftarkan kunjungan → dapat no. antrian
4. Petugas klaster buka tab Rekam Medis → pilih pasien → isi SOAP → simpan
5. Semua rekam medis otomatis tercatat nama petugas yang isi
