// ============================================================
// KONFIGURASI SUPABASE
// Ganti dua nilai di bawah ini dengan punya kamu:
// - Buka project Supabase > Project Settings > API
// - Copy "Project URL" dan "anon public" key
// ============================================================
const SUPABASE_URL = "https://njkwpictaipmhazhfmnd.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5qa3dwaWN0YWlwbWhhemhmbW5kIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcwNjQ5NDcsImV4cCI6MjEwMjY0MDk0N30.sSp8NrfMZmxCnncfc6NSrKmv3USRzNoS5Z9dokz6lMY";

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Cek status login. Kalau belum login, lempar ke halaman login.
// Panggil fungsi ini di awal setiap halaman (kecuali login.html).
async function wajibLogin() {
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (!session) {
    window.location.href = "login.html";
    return null;
  }
  return session;
}

// Ambil data profil pegawai (nama, role, klaster) dari user yang login.
// Ditambah: semua klaster yang bisa diakses (klaster utama + pegawai_klaster),
// dan peta hak akses granular per modul (hak_akses) — dipakai buat Kapus/KTU/
// Bendahara BOK yang aksesnya lintas klaster/lintas peran.
async function getProfilSaya() {
  const { data: { user } } = await supabaseClient.auth.getUser();
  if (!user) return null;

  const { data, error } = await supabaseClient
    .from("profil_pegawai")
    .select(`
      *,
      klaster(nama, kode),
      pegawai_klaster(klaster_id, keterangan, klaster(nama, kode)),
      hak_akses(modul_kode, klaster_id, level)
    `)
    .eq("id", user.id)
    .single();

  if (error) {
    console.error("Gagal ambil profil:", error.message);
    return null;
  }

  // Kumpulkan semua id klaster yang bisa diakses pegawai ini (klaster utama + tambahan)
  const klasterIds = new Set();
  if (data.klaster_id) klasterIds.add(data.klaster_id);
  (data.pegawai_klaster || []).forEach(pk => klasterIds.add(pk.klaster_id));
  data.klasterIds = Array.from(klasterIds);

  // Peta hak akses granular: { modul_kode: [{klaster_id, level}, ...] }
  // klaster_id null artinya berlaku buat semua klaster.
  const peta = {};
  (data.hak_akses || []).forEach(h => {
    if (!peta[h.modul_kode]) peta[h.modul_kode] = [];
    peta[h.modul_kode].push({ klaster_id: h.klaster_id, level: h.level });
  });
  data.hakAksesPeta = peta;

  return data;
}

// Urutan level hak akses, dipakai buat bandingkan cukup/gak nya
const LEVEL_URUTAN = { lihat: 1, layani: 2, penuh: 3 };

// Cek apakah pegawai punya hak akses ke modul tertentu (opsional: di klaster tertentu),
// minimal level tertentu. Admin selalu lolos.
function cekHakAkses(profil, modulKode, klasterId, minLevel = "lihat") {
  if (!profil) return false;
  if (profil.role === "admin") return true;

  const daftar = (profil.hakAksesPeta || {})[modulKode] || [];
  const cocok = daftar.find(h => h.klaster_id === null || h.klaster_id === klasterId);
  if (!cocok) return false;
  return LEVEL_URUTAN[cocok.level] >= LEVEL_URUTAN[minLevel];
}

// Cek apakah pegawai punya hak akses ke modul tertentu, di klaster manapun
function punyaAksesModul(profil, modulKode) {
  if (!profil) return false;
  if (profil.role === "admin") return true;
  return ((profil.hakAksesPeta || {})[modulKode] || []).length > 0;
}

async function logout() {
  await supabaseClient.auth.signOut();
  window.location.href = "login.html";
}

// Panggil Edge Function "kelola-pegawai" bawa token user yang lagi login.
// Edge Function sendiri yang verifikasi apakah user ini admin.
// Return: { data } kalau sukses, atau { error: "pesan" } kalau gagal.
async function panggilAdmin(action, payload) {
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (!session) return { error: "Sesi login habis, silakan login ulang." };

  const { data, error } = await supabaseClient.functions.invoke("kelola-pegawai", {
    body: { action, payload },
    headers: { Authorization: `Bearer ${session.access_token}` },
  });

  if (error) {
    // supabase-js bungkus error HTTP non-2xx di sini; coba baca pesan dari body kalau ada
    const pesan = error.context?.error || error.message || "Gagal hubungi server.";
    return { error: pesan };
  }
  if (data?.error) return { error: data.error };
  return { data: data?.data };
}

// ============================================================
// KONTROL AKSES PER HALAMAN BERDASARKAN ROLE
// admin       -> semua halaman
// petugas     -> index.html (Pendaftaran) saja
// staff       -> index.html (Pendaftaran) saja
// dokter/perawat/bidan -> rekam-medis.html saja (dibatasi ke klaster tempat ditugaskan)
// farmasi     -> apotek.html saja
//
// Di luar ini, siapapun yang punya baris di tabel hak_akses buat modul
// "rekam_medis" (misal Kapus, KTU, Bendahara BOK) otomatis dapat tambahan
// akses ke rekam-medis.html, walau role dasarnya bukan dokter/perawat/bidan.
// ============================================================
const AKSES_HALAMAN = {
  admin: ["index.html", "rekam-medis.html", "apotek.html", "pengaturan.html"],
  petugas: ["index.html", "pengaturan.html"],
  staff: ["index.html", "pengaturan.html"],
  dokter: ["rekam-medis.html", "pengaturan.html"],
  perawat: ["rekam-medis.html", "pengaturan.html"],
  bidan: ["rekam-medis.html", "pengaturan.html"],
  farmasi: ["apotek.html", "pengaturan.html"]
};

// Hitung daftar halaman yang boleh diakses profil ini: role dasar + tambahan
// dari hak_akses granular.
function halamanIzinUntuk(profil) {
  if (!profil) return [];
  if (profil.role === "admin") return AKSES_HALAMAN.admin;

  const izin = new Set(AKSES_HALAMAN[profil.role] || []);
  if (punyaAksesModul(profil, "rekam_medis")) izin.add("rekam-medis.html");
  return Array.from(izin);
}

// Panggil setelah getProfilSaya(). Kalau role gak punya izin ke halaman ini,
// otomatis dilempar ke halaman yang sesuai role-nya.
function cekAksesHalaman(profil, halamanIni) {
  if (!profil) return;
  const izin = halamanIzinUntuk(profil);
  if (izin.includes(halamanIni)) return;

  if (izin.length > 0) {
    window.location.href = izin[0];
  } else {
    alert("Role akun kamu belum diberi akses ke halaman manapun. Hubungi admin.");
    logout();
  }
}

// Sembunyikan tab navigasi yang gak diizinkan buat role ini
function sesuaikanTabNav(profil) {
  if (!profil) return;
  const izin = halamanIzinUntuk(profil);
  document.querySelectorAll(".tab-nav a, .sidebar nav a").forEach(a => {
    const href = a.getAttribute("href");
    if (!izin.includes(href)) a.style.display = "none";
  });
}
