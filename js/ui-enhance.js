// ============================================================
// UI ENHANCE — cuma dandanin tampilan sidebar & topbar.
// GAK ubah/hapus id, onclick, href yang udah ada — jadi semua
// fungsi lama (login, akses per-role, dst di supabaseClient.js)
// tetap jalan sama persis kayak sebelumnya.
//
// Cara pakai: taruh script ini SETELAH js/supabaseClient.js dan
// setelah script halaman itu sendiri, sebelum </body>:
//   <script src="js/ui-enhance.js"></script>
// Mau balik ke tampilan lama? Hapus baris <script> ini aja,
// plus baris <link> css/tampilan-baru.css.
// ============================================================

(function () {
  // Ikon buat tiap menu, dicocokin dari id atau href elemen <a>.
  // Gak ketemu di daftar ini? otomatis pakai ikon titik polos.
  const IKON = {
    navDashboard: "🏠",
    navIdentifikasi: "🧾",
    navSkrining: "🩺",
    navKoordinasi: "🔗",
    navRujukan: "↗️",
    navKerahasiaan: "🔒",
    navSurvei: "⭐",
    navLaporan: "📊",
    navLaporanInternal: "📊",
    navLaporanDinas: "📤",
    navAudit: "🛡️",
    navPeriksa: "🦷",
    navTindakan: "🔧",
    navPromotif: "📣",
    navRm: "📋",
    "index.html": "🧾",
    "rekam-medis.html": "📋",
    "apotek.html": "💊",
    "ugd.html": "🚑",
    "ranap.html": "🛏️",
    "klaster1.html": "👶",
    "klaster2.html": "🧑",
    "klaster3.html": "💪",
    "klaster4.html": "🩹",
    "gigi.html": "🦷",
    "pustu.html": "🏥",
    "pengaturan.html": "⚙️",
    "kasir.html": "💳",
    "papan-antrian.html": "📺"
  };

  function ikonUntuk(a) {
    const key = a.id || a.getAttribute("href") || "";
    return IKON[key] || "•";
  }

  function pasangIkon(nav) {
    nav.querySelectorAll("a").forEach(a => {
      if (a.querySelector(".nav-icon")) return; // sudah dipasang
      const span = document.createElement("span");
      span.className = "nav-icon";
      span.textContent = ikonUntuk(a);
      a.insertBefore(span, a.firstChild);
    });
  }

  // Kelompokkan <a> di bawah tiap .ph-group-title jadi grup yang
  // bisa dibuka/tutup. <a> aslinya cuma dipindah container (reparent),
  // atribut id/onclick/href-nya gak disentuh sama sekali.
  function buatGrupBisaLipat(nav) {
    if (nav.dataset.grouped) return; // udah pernah dijalanin
    nav.dataset.grouped = "1";

    const anak = Array.from(nav.children);
    let grupSaatIni = null;
    let bodySaatIni = null;

    anak.forEach(el => {
      if (el.classList.contains("ph-group-title")) {
        const wrap = document.createElement("div");
        wrap.className = "nav-group";

        const tombol = document.createElement("button");
        tombol.type = "button";
        tombol.className = "nav-group-title";
        tombol.innerHTML = `<span>${el.textContent}</span><span class="chevron">▾</span>`;

        const body = document.createElement("div");
        body.className = "nav-group-body";

        tombol.addEventListener("click", () => {
          tombol.classList.toggle("collapsed");
          body.classList.toggle("collapsed");
        });

        wrap.appendChild(tombol);
        wrap.appendChild(body);
        nav.replaceChild(wrap, el);

        grupSaatIni = wrap;
        bodySaatIni = body;
      } else if (bodySaatIni) {
        bodySaatIni.appendChild(el); // reparent, atribut tetap sama
      }
    });

    // Buka otomatis grup yang isinya link aktif; sisanya tutup.
    nav.querySelectorAll(".nav-group").forEach(g => {
      const adaAktif = g.querySelector("a.active");
      const tombol = g.querySelector(".nav-group-title");
      const body = g.querySelector(".nav-group-body");
      if (!adaAktif) {
        tombol.classList.add("collapsed");
        body.classList.add("collapsed");
      }
    });
  }

  function dandaniTopbar(topbar) {
    if (topbar.dataset.dandan) return;
    topbar.dataset.dandan = "1";

    const h1 = topbar.querySelector("h1");
    const userInfo = topbar.querySelector(".user-info");
    if (!h1 || !userInfo) return;

    // Breadcrumb kecil di atas judul halaman
    const kiri = document.createElement("div");
    const crumbs = document.createElement("div");
    crumbs.className = "crumbs";
    crumbs.innerHTML = `<span>🏠 Beranda</span><span>›</span><span class="curr">${h1.textContent}</span>`;
    h1.parentNode.insertBefore(kiri, h1);
    kiri.appendChild(crumbs);
    kiri.appendChild(h1);

    // Lonceng notifikasi (dekorasi, gak nyambung backend apapun)
    const bell = document.createElement("div");
    bell.className = "bell";
    bell.innerHTML = `🔔<span class="dot-red"></span>`;
    userInfo.insertBefore(bell, userInfo.firstChild);

    // Bungkus nama user + tombol keluar jadi 1 chip rapi
    const namaUser = userInfo.querySelector("#namaUser");
    const btnKeluar = userInfo.querySelector("button");
    if (namaUser) {
      const chip = document.createElement("div");
      chip.className = "user-chip";
      const avatar = document.createElement("span");
      avatar.className = "avatar";
      avatar.textContent = "👤";
      namaUser.parentNode.insertBefore(chip, namaUser);
      chip.appendChild(avatar);
      chip.appendChild(namaUser);
      if (btnKeluar) chip.parentNode.insertBefore(btnKeluar, chip.nextSibling);
    }
  }

  function jalankan() {
    const nav = document.querySelector(".sidebar nav");
    const topbar = document.querySelector(".topbar");
    if (nav) {
      pasangIkon(nav);
      buatGrupBisaLipat(nav);
    }
    if (topbar) dandaniTopbar(topbar);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", jalankan);
  } else {
    jalankan();
  }
})();
