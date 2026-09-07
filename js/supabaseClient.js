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
  mulaiPelacakanSesi(session);
  return session;
}

// ============================================================
// MANAJEMEN SESI AKTIF
// Tiap browser/perangkat dapat "sesi_token" acak sendiri, disimpan di
// localStorage supaya tetap sama walau halaman di-refresh/pindah tab.
// Token ini dicatat ke tabel sesi_aktif biar admin bisa lihat siapa lagi
// login dari mana, dan bisa "paksa logout" (lihat catatan keterbatasan
// di schema.sql bagian 38).
// ============================================================
function ambilSesiToken() {
  let token = localStorage.getItem("simpus_sesi_token");
  if (!token) {
    token = crypto.randomUUID();
    localStorage.setItem("simpus_sesi_token", token);
  }
  return token;
}

// Ringkasan perangkat/browser dari user agent, buat ditampilin ke admin
// (gak perlu presisi, cukup cukup buat "oh ini dari HP/laptop mana").
function ringkasPerangkat() {
  const ua = navigator.userAgent;
  let browser = "Browser lain";
  if (ua.includes("Edg/")) browser = "Edge";
  else if (ua.includes("Chrome/") && !ua.includes("Chromium")) browser = "Chrome";
  else if (ua.includes("Firefox/")) browser = "Firefox";
  else if (ua.includes("Safari/") && !ua.includes("Chrome")) browser = "Safari";

  let os = "OS lain";
  if (ua.includes("Windows")) os = "Windows";
  else if (ua.includes("Android")) os = "Android";
  else if (ua.includes("iPhone") || ua.includes("iPad")) os = "iOS";
  else if (ua.includes("Mac OS")) os = "Mac";
  else if (ua.includes("Linux")) os = "Linux";

  return `${browser} di ${os}`;
}

let pelacakanSesiInterval = null;

async function mulaiPelacakanSesi(session) {
  if (pelacakanSesiInterval) return; // sudah jalan, gak perlu dobel
  const token = ambilSesiToken();

  async function catatDenyut() {
    const { data, error } = await supabaseClient
      .from("sesi_aktif")
      .upsert(
        {
          pegawai_id: session.user.id,
          sesi_token: token,
          perangkat: ringkasPerangkat(),
          last_active: new Date().toISOString(),
        },
        { onConflict: "sesi_token" }
      )
      .select("dicabut")
      .single();

    if (error) {
      console.error("Gagal catat sesi aktif:", error.message);
      return;
    }
    // Kalau admin sudah "Paksa Logout" sesi ini, langsung keluar.
    if (data && data.dicabut) {
      clearInterval(pelacakanSesiInterval);
      pelacakanSesiInterval = null;
      alert("Sesi Anda dihentikan oleh admin. Silakan login ulang.");
      await logout();
    }
  }

  await catatDenyut();
  pelacakanSesiInterval = setInterval(catatDenyut, 30000);
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
      pustu!profil_pegawai_pustu_id_fkey(nama, tipe, wilayah),
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
  if (pelacakanSesiInterval) {
    clearInterval(pelacakanSesiInterval);
    pelacakanSesiInterval = null;
  }
  // Hapus token sesi biar login berikutnya (walau di browser yang sama)
  // dapat baris sesi_aktif baru yang bersih, gak kebawa status "dicabut".
  localStorage.removeItem("simpus_sesi_token");
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
    // supabase-js bungkus error HTTP non-2xx di sini. error.context itu Response
    // mentah, BUKAN JSON hasil parse — jadi error.context?.error selalu undefined
    // dan yang kepampang cuma pesan generik "Edge Function returned a non-2xx
    // status code". Di sini kita baca body-nya sendiri biar pesan error ASLI
    // dari server (mis. "duplicate key...", "pegawai_id wajib.") yang muncul.
    let pesan = error.message || "Gagal hubungi server.";
    try {
      if (error.context && typeof error.context.json === "function") {
        const body = await error.context.json();
        if (body?.error) pesan = body.error;
      }
    } catch (e2) {
      // body bukan JSON / sudah kebaca — pakai pesan fallback di atas
    }
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
// dokter/perawat/bidan -> rekam-medis.html + ugd.html (dibatasi ke klaster tempat ditugaskan)
// farmasi     -> apotek.html saja
// kepala_puskesmas -> kapus.html saja (dashboard eksekutif lintas unit)
//
// Di luar ini, siapapun yang punya baris di tabel hak_akses buat modul
// "rekam_medis" (misal Kapus, KTU, Bendahara BOK) otomatis dapat tambahan
// akses ke rekam-medis.html, walau role dasarnya bukan dokter/perawat/bidan.
// ============================================================
const AKSES_HALAMAN = {
  admin: ["admin.html", "index.html", "rekam-medis.html", "apotek.html", "ugd.html", "ranap.html", "klaster1.html", "klaster2.html", "klaster3.html", "klaster4.html", "gigi.html", "pengaturan.html", "kasir.html", "papan-antrian.html", "pustu.html", "kapus.html", "pemegang-program.html"],
  petugas: ["index.html", "rekam-medis.html", "pengaturan.html", "kasir.html", "papan-antrian.html"],
  staff: ["index.html", "rekam-medis.html", "pengaturan.html", "kasir.html", "papan-antrian.html"],
  dokter: ["rekam-medis.html", "ugd.html", "ranap.html", "klaster2.html", "klaster3.html", "klaster4.html", "gigi.html", "pengaturan.html", "papan-antrian.html"],
  perawat: ["rekam-medis.html", "ugd.html", "ranap.html", "klaster2.html", "klaster3.html", "klaster4.html", "gigi.html", "pengaturan.html", "papan-antrian.html"],
  bidan: ["rekam-medis.html", "ugd.html", "klaster2.html", "klaster3.html", "klaster4.html", "gigi.html", "pengaturan.html", "papan-antrian.html"],
  farmasi: ["apotek.html", "pengaturan.html", "papan-antrian.html"],
  klaster1: ["klaster1.html", "pengaturan.html", "papan-antrian.html"],
  kepala_puskesmas: ["kapus.html"],
  pemegang_program: ["pemegang-program.html"]
};

// Peta modul_kode (di tabel hak_akses) -> halaman .html yang dibuka.
// Tambah baris hak_akses baru buat pegawai manapun (role apa aja: bidan,
// perawat, staff, dst) pakai salah satu modul_kode ini, otomatis dia bisa
// buka halaman itu juga, TANPA perlu ganti role dasarnya.
const MODUL_KE_HALAMAN = {
  pendaftaran: "index.html",
  rekam_medis: "rekam-medis.html",
  apotek: "apotek.html",
  ugd: "ugd.html",
  ranap: "ranap.html",
  klaster1: "klaster1.html",
  manajemen: "klaster1.html", // nama lama, tetap didukung
  klaster2: "klaster2.html",
  klaster3: "klaster3.html",
  klaster4: "klaster4.html",
  gigi: "gigi.html",
  pustu: "pustu.html",
  kasir: "kasir.html",
  pengaturan: "pengaturan.html",
  papan_antrian: "papan-antrian.html",
  kapus: "kapus.html",
  pemegang_program: "pemegang-program.html"
};

// Hitung daftar halaman yang boleh diakses profil ini: role dasar + tambahan
// dari hak_akses granular.
function halamanIzinUntuk(profil) {
  if (!profil) return [];
  if (profil.role === "admin") return AKSES_HALAMAN.admin;

  // Pegawai yang ditugaskan di Pustu (bidan/perawat/petugas Pustu dkk) cuma
  // boleh buka pustu.html, gak ikut akses klaster/rekam-medis induk biasa
  // walau role dasarnya dokter/perawat/bidan/dst.
  if (profil.pustu_id) return ["pustu.html"];

  const izin = new Set(AKSES_HALAMAN[profil.role] || []);

  // Tambahan generik: tiap modul_kode di hak_akses pegawai ini otomatis
  // buka halaman yang sesuai, apapun role dasarnya.
  Object.keys(profil.hakAksesPeta || {}).forEach(modulKode => {
    const halaman = MODUL_KE_HALAMAN[modulKode];
    if (halaman) izin.add(halaman);
  });

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
    if (!href) return; // subtab internal (onclick, tanpa href) — bukan link antar modul, jangan disembunyikan
    if (!izin.includes(href)) a.style.display = "none";
  });
}
