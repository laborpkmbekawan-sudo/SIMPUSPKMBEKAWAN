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

// Ambil data profil pegawai (nama, role, klaster) dari user yang login
async function getProfilSaya() {
  const { data: { user } } = await supabaseClient.auth.getUser();
  if (!user) return null;

  const { data, error } = await supabaseClient
    .from("profil_pegawai")
    .select("*, klaster(nama, kode)")
    .eq("id", user.id)
    .single();

  if (error) {
    console.error("Gagal ambil profil:", error.message);
    return null;
  }
  return data;
}

async function logout() {
  await supabaseClient.auth.signOut();
  window.location.href = "login.html";
}

// ============================================================
// KONTROL AKSES PER HALAMAN BERDASARKAN ROLE
// admin       -> semua halaman
// petugas     -> index.html (Pendaftaran) saja
// dokter/perawat/bidan -> rekam-medis.html saja (dibatasi ke klaster tempat ditugaskan)
// farmasi     -> apotek.html saja
// ============================================================
const AKSES_HALAMAN = {
  admin: ["index.html", "rekam-medis.html", "apotek.html"],
  petugas: ["index.html"],
  dokter: ["rekam-medis.html"],
  perawat: ["rekam-medis.html"],
  bidan: ["rekam-medis.html"],
  farmasi: ["apotek.html"]
};

// Panggil setelah getProfilSaya(). Kalau role gak punya izin ke halaman ini,
// otomatis dilempar ke halaman yang sesuai role-nya.
function cekAksesHalaman(profil, halamanIni) {
  if (!profil) return;
  const izin = AKSES_HALAMAN[profil.role] || [];
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
  const izin = AKSES_HALAMAN[profil.role] || [];
  document.querySelectorAll(".tab-nav a").forEach(a => {
    const href = a.getAttribute("href");
    if (!izin.includes(href)) a.style.display = "none";
  });
}
