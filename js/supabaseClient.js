// ============================================================
// KONFIGURASI SUPABASE
// Ganti dua nilai di bawah ini dengan punya kamu:
// - Buka project Supabase > Project Settings > API
// - Copy "Project URL" dan "anon public" key
// ============================================================
const SUPABASE_URL = "https://xdqejpyrrrnhhiqfoxsk.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhkcWVqcHlycnJuaGhpcWZveHNrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg5NTExMzIsImV4cCI6MjEwNDUyNzEzMn0.2b4e9UOfEIijpzaehkIlExRZUDmGU12pAAVZ3fmmEt4";

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

// ============================================================
// MESIN RBAC PUSAT
// Urutan level: lihat(1) < layani(2) < penuh(3).
// Semua modul WAJIB pake bolehLihat()/bolehLayani()/bolehLaporan()/bolehAksi()
// di bawah -- jangan cek profil.role langsung di HTML modul buat nentuin
// boleh-input-atau-tidak (nav-hiding doang gak cukup, ini yang nentuin beneran
// boleh submit/insert/update atau tidak).
// ============================================================
const LEVEL_URUTAN = { lihat: 1, layani: 2, penuh: 3 };

// Role yang otomatis dapet level "layani" bawaan di klaster tempat dia
// ditugaskan (klasterIds), per modul_kode -- gantiin baked-in role check yang
// dulu cuma ada lokal di rekam-medis.html (bisaLayani), sekarang berlaku pusat
// buat modul manapun yang manggil bolehLayani()/bolehAksi(). Hak akses
// granular (hak_akses table) tetap bisa NAIKIN ke "penuh" atau kasih akses
// lintas klaster di atas bawaan ini.
const ROLE_LAYANI_BAWAAN = {
  rekam_medis: ["dokter", "perawat", "bidan"],
  ugd: ["dokter", "perawat", "bidan"],
  ranap: ["dokter", "perawat", "bidan"],
  gigi: ["dokter", "perawat", "bidan"],
  // klaster1 SENGAJA gak ada di sini -- klaster1 = modul Manajemen (surat,
  // keuangan, kepegawaian, aset, mutu), bukan poli klinis. Gak ada role yang
  // "otomatis" boleh layani di situ; akses murni dari hak_akses granular yang
  // di-set admin manual di pengaturan.html (KTU/bendahara/dst).
  klaster2: ["dokter", "perawat", "bidan"],
  klaster3: ["dokter", "perawat", "bidan"],
  klaster4: ["dokter", "perawat", "bidan"],
  apotek: ["farmasi"],
  kasir: ["petugas", "staff"],
  pendaftaran: ["petugas", "staff"],
};

// Level tertinggi dari hak_akses granular buat 1 modul (atau beberapa alias
// modul_kode sekaligus), opsional dibatasi ke 1 klaster. klaster_id null di
// baris hak_akses artinya berlaku semua klaster. Kalau klasterId gak dikasih
// (undefined), semua baris ikut dihitung tanpa filter klaster.
function levelDariHakAkses(profil, modulKodeAtauArray, klasterId) {
  const daftarKode = Array.isArray(modulKodeAtauArray) ? modulKodeAtauArray : [modulKodeAtauArray];
  let terbaik = null;
  daftarKode.forEach(kode => {
    ((profil.hakAksesPeta || {})[kode] || []).forEach(h => {
      if (h.klaster_id !== null && klasterId !== undefined && h.klaster_id !== klasterId) return;
      if (!terbaik || LEVEL_URUTAN[h.level] > LEVEL_URUTAN[terbaik]) terbaik = h.level;
    });
  });
  return terbaik;
}

// Level EFEKTIF pegawai buat 1 modul (opsional di 1 klaster tertentu):
// gabungan role bawaan (ROLE_LAYANI_BAWAAN, cuma nyala kalau klasterId cocok
// klaster tugas pegawai) + hak akses granular (bisa nimpa ke level lebih
// tinggi). Balikin null kalau gak punya akses sama sekali ke modul ini.
function levelEfektifModul(profil, modulKodeAtauArray, klasterId) {
  if (!profil) return null;
  if (profil.role === "admin") return "penuh";

  const daftarKode = Array.isArray(modulKodeAtauArray) ? modulKodeAtauArray : [modulKodeAtauArray];
  let terbaik = null;

  daftarKode.forEach(kode => {
    const roleBawaan = ROLE_LAYANI_BAWAAN[kode] || [];
    if (roleBawaan.includes(profil.role)) {
      const cocokKlaster = klasterId === undefined || (profil.klasterIds || []).includes(klasterId);
      if (cocokKlaster) terbaik = "layani";
    }
  });

  const dariHak = levelDariHakAkses(profil, daftarKode, klasterId);
  if (dariHak && (!terbaik || LEVEL_URUTAN[dariHak] > LEVEL_URUTAN[terbaik])) terbaik = dariHak;

  return terbaik;
}

// Dipanggil sebelum nampilin data pasien/rekam -- minimal level "lihat".
function bolehLihat(profil, modulKode, klasterId) {
  if (!profil) return false;
  if (profil.role === "admin") return true;
  return levelEfektifModul(profil, modulKode, klasterId) !== null;
}

// Dipanggil sebelum ngizinin submit/insert/update data pelayanan (isi rekam
// medis, resep, tindakan, dst) -- minimal level "layani".
function bolehLayani(profil, modulKode, klasterId) {
  if (!profil) return false;
  const level = levelEfektifModul(profil, modulKode, klasterId);
  return !!level && LEVEL_URUTAN[level] >= LEVEL_URUTAN.layani;
}

// Dipanggil sebelum nampilin/ngizinin Laporan Internal & Laporan ke Dinas --
// wajib level "penuh".
function bolehLaporan(profil, modulKode, klasterId) {
  if (!profil) return false;
  return levelEfektifModul(profil, modulKode, klasterId) === "penuh";
}

// Versi generik, buat kasus yang minLevel-nya gak baku (lihat/layani/penuh).
function bolehAksi(profil, modulKode, klasterId, minLevel = "lihat") {
  if (!profil) return false;
  if (profil.role === "admin") return true;
  const level = levelEfektifModul(profil, modulKode, klasterId);
  return !!level && LEVEL_URUTAN[level] >= LEVEL_URUTAN[minLevel];
}

// --- Kompatibilitas mundur, biar kode lama yang masih manggil nama lama gak
// error. JANGAN dipake buat kode baru -- pake 4 fungsi bolehX() di atas. ---
function cekHakAkses(profil, modulKode, klasterId, minLevel = "lihat") {
  return bolehAksi(profil, modulKode, klasterId, minLevel);
}
function punyaAksesModul(profil, modulKode) {
  if (!profil) return false;
  if (profil.role === "admin") return true;
  return levelEfektifModul(profil, modulKode) !== null;
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
// Paket akses bawaan HANYA buat role yang emang 1 fungsi khusus (admin lihat
// semua, kapus/pemegang-program cuma 1 halaman). Role klinis/petugas LAINNYA
// (dokter, perawat, bidan, farmasi, petugas, staff, klaster1, dst) TIDAK lagi
// dapet paket bawaan lebar -- akses mereka 100% ditentuin dari "Klaster
// Tambahan"/"Hak Akses Modul" yang di-set admin per-orang di pengaturan.html.
const AKSES_HALAMAN = {
  admin: ["admin.html", "index.html", "rekam-medis.html", "apotek.html", "ugd.html", "ranap.html", "klaster1.html", "klaster2.html", "klaster3.html", "klaster4.html", "gigi.html", "pengaturan.html", "kasir.html", "papan-antrian.html", "pustu.html", "kapus.html", "pemegang-program.html"],
  kepala_puskesmas: ["kapus.html"],
  pemegang_program: ["pemegang-program.html"]
};
// Halaman universal yang boleh dibuka SEMUA pegawai berapapun role-nya
// (ganti password sendiri, liat papan antrian) -- bukan modul sensitif.
const AKSES_HALAMAN_DEFAULT = ["pengaturan.html", "papan-antrian.html"];

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

  const izin = new Set(AKSES_HALAMAN[profil.role] || AKSES_HALAMAN_DEFAULT);

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
  if (!profil) {
    // Dulu di sini cuma "return" -- diam aja. Efeknya: kalau profil gagal
    // dimuat (network/DB kedip), TIDAK ADA pengecekan akses sama sekali,
    // dan sesuaikanTabNav() (di bawah) ikut nganggur juga -> semua link
    // modul kelihatan tanpa saringan. Sekarang fail CLOSED: kasih tau
    // jelas + log, jangan diam-diam biarin halaman kebuka polos.
    console.error("cekAksesHalaman: profil gagal dimuat, akses tidak bisa diverifikasi.");
    alert("Gagal memuat data akun kamu. Coba refresh halaman (F5). Kalau berulang terus, hubungi admin.");
    return;
  }
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
  // Kalau profil null (gagal dimuat), izin = [] -> SEMUA link modul lain
  // disembunyikan (fail closed). Dulu function ini "return" langsung kalau
  // profil null, yang artinya BIARIN SEMUA LINK KELIHATAN -- itu yang bikin
  // Poli Gigi dkk nongol padahal harusnya kesaring.
  const izin = profil ? halamanIzinUntuk(profil) : [];
  document.querySelectorAll(".tab-nav a, .sidebar nav a").forEach(a => {
    const href = a.getAttribute("href");
    if (!href) return; // subtab internal (onclick, tanpa href) — bukan link antar modul, jangan disembunyikan
    if (!izin.includes(href)) a.style.display = "none";
  });
}

// ================= Sidebar dinamis (nama pegawai + menu sesuai akses) =================
// Ganti sistem lama (daftar link statis di tiap file .html, lalu disembunyiin satu-satu
// pakai sesuaikanTabNav). Sekarang: satu registry di sini, tiap halaman cuma render
// container kosong, isi menu "Modul Lain" digenerate sesuai izin akun yang login --
// biar gak numpuk & gak keliatan berantakan pas lagi kebuka penuh.
const MENU_LAIN_REGISTRY = [
  { halaman: "index.html", label: "Pendaftaran", ikon: "📝", grup: "Menu Utama" },
  { halaman: "rekam-medis.html", label: "Rekam Medis", ikon: "🗂️", grup: "Menu Utama" },
  { halaman: "klaster1.html", label: "Klaster 1 — Manajemen", ikon: "🏥", grup: "Menu Utama" },
  { halaman: "klaster2.html", label: "Klaster 2 — Ibu, Anak & Remaja", ikon: "🤰", grup: "Menu Utama" },
  { halaman: "klaster3.html", label: "Klaster 3 — Dewasa & Lansia", ikon: "🩺", grup: "Menu Utama" },
  { halaman: "klaster4.html", label: "Klaster 4 — Penyakit Menular", ikon: "🦠", grup: "Menu Utama" },
  { halaman: "gigi.html", label: "Poli Gigi", ikon: "🦷", grup: "Menu Utama" },
  { halaman: "ugd.html", label: "UGD", ikon: "🚑", grup: "Lintas Klaster" },
  { halaman: "ranap.html", label: "Rawat Inap", ikon: "🛏️", grup: "Lintas Klaster" },
  { halaman: "apotek.html", label: "Apotek", ikon: "💊", grup: "Lintas Klaster" },
  { halaman: "kasir.html", label: "Kasir", ikon: "💳", grup: "Lintas Klaster" },
  { halaman: "pustu.html", label: "Pustu", ikon: "📡", grup: "Lintas Klaster" },
  { halaman: "kapus.html", label: "Kepala Puskesmas", ikon: "📋", grup: "Manajemen" },
  { halaman: "pemegang-program.html", label: "Pemegang Program", ikon: "📊", grup: "Manajemen" },
  { halaman: "admin.html", label: "Admin", ikon: "⚙️", grup: "Manajemen" },
  { halaman: "pengaturan.html", label: "Pengaturan Akun", ikon: "🔧", grup: "Lainnya" },
  { halaman: "papan-antrian.html", label: "Papan Antrian", ikon: "📺", grup: "Lainnya" }
];

// Render menu "modul lain" ke satu container kosong (<div id="sidebarModulLain">),
// cuma nampilin halaman yang profil ini emang punya izin (halamanIzinUntuk), dikelompokin
// per grup, dan gak nampilin link ke halaman yang lagi dibuka sekarang (halamanAktif).
function renderSidebarDinamis(profil, halamanAktif, containerEl) {
  if (!containerEl) return;
  const izin = profil ? halamanIzinUntuk(profil) : [];
  const perGrup = {};
  MENU_LAIN_REGISTRY.forEach(item => {
    if (item.halaman === halamanAktif) return;
    if (!izin.includes(item.halaman)) return;
    (perGrup[item.grup] = perGrup[item.grup] || []).push(item);
  });
  const urutanGrup = ["Menu Utama", "Lintas Klaster", "Manajemen", "Lainnya"];
  let html = "";
  urutanGrup.forEach(grup => {
    const items = perGrup[grup];
    if (!items || !items.length) return;
    html += `<div class="ph-group-title">${grup}</div>`;
    items.forEach(item => {
      html += `<a href="${item.halaman}"><span class="nav-ic">${item.ikon}</span> ${item.label}</a>`;
    });
  });
  containerEl.innerHTML = html || `<div class="ph-group-title">Modul Lain</div><a style="opacity:.5;cursor:default;">Belum ada akses modul lain</a>`;
}

// Isi baris kecil di bawah judul brand sidebar dengan nama + role akun yang login
// (contoh: "Akun: Ayu Lestari — Bidan"), biar tiap akun langsung keliatan lagi login
// sebagai siapa tanpa harus liat topbar dulu.
function tampilkanAkunDiBrand(profil) {
  const el = document.getElementById("brandAkun");
  if (!el) return;
  el.textContent = profil ? `Akun: ${profil.nama} — ${labelRole(profil.role)}` : "Akun: —";
}

function labelRole(role) {
  const peta = {
    admin: "Admin", dokter: "Dokter", perawat: "Perawat", bidan: "Bidan",
    farmasi: "Farmasi", petugas: "Petugas", staff: "Staff",
    kepala_puskesmas: "Kepala Puskesmas", pemegang_program: "Pemegang Program"
  };
  return peta[role] || role;
}

// Kompatibilitas mundur -- dulu levelUntukModul cuma ngitung dari hak_akses
// (gak ikut role bawaan). Sekarang delegasi ke levelEfektifModul (klasterId
// undefined = gak difilter per klaster, sama kayak perilaku lama).
function levelUntukModul(profil, modulKodeAtauArray) {
  return levelEfektifModul(profil, modulKodeAtauArray);
}

// Sembunyikan elemen (biasanya tab/link "Laporan Internal", "Laporan ke
// Dinas", dst) yang cuma boleh diliat kalau level pegawai buat modul ini
// "penuh". Panggil sekali per halaman modul, abis sesuaikanTabNav().
function terapkanLevelUI(profil, modulKodeAtauArray, idElemenButuhPenuh) {
  const cukup = bolehLaporan(profil, modulKodeAtauArray);
  (idElemenButuhPenuh || []).forEach(id => {
    const el = document.getElementById(id);
    if (el) el.style.display = cukup ? "" : "none";
  });
}
