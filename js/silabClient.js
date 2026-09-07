// ============================================================
// KLIEN SILAB (Laboratorium) — PROJECT SUPABASE TERPISAH
// ============================================================
// PENTING: siLab (https://silab-puskesmas-bekawan) adalah aplikasi
// TERPISAH dari SIMPUS, dengan project Supabase-nya sendiri. Ini
// BUKAN typo/duplikat dari js/supabaseClient.js.
//
// Anon key ini memang publik/tertanam di kode (sama seperti siLab
// sendiri menaruhnya di source code React-nya) — RLS di sisi siLab
// untuk tabel pasien/pemeriksaan/parameters memang "public" (using
// (true)), jadi menambah SIMPUS sebagai klien lain TIDAK menambah
// risiko baru dibanding yang sudah ada. Catatan keamanan ini
// disampaikan apa adanya ke Nia, bukan disembunyikan.
// ============================================================
const SILAB_URL = "https://ayeuzvsipotqekvbtakp.supabase.co";
const SILAB_ANON_KEY = "sb_publishable_cHyxQngpenvxw57X9dPXEw_92_g83E8";

const silabClient = window.supabase.createClient(SILAB_URL, SILAB_ANON_KEY);

// Cache kecil buat master parameter (nama, satuan, nilai normal) —
// dipakai nampilin hasil lab biar gak query berkali-kali.
let _silabParametersCache = null;
async function _muatSilabParameters() {
  if (_silabParametersCache) return _silabParametersCache;
  const { data, error } = await silabClient.from("parameters").select("*");
  if (error) { console.error("Gagal muat parameters siLab:", error.message); return []; }
  _silabParametersCache = data || [];
  return _silabParametersCache;
}

// Map jenis_kelamin SIMPUS ('L'/'P') -> format siLab ('Laki-laki'/'Perempuan')
function _genderKeSilab(kode) {
  return kode === "P" ? "Perempuan" : "Laki-laki";
}

function _hitungUmurSilab(tglLahir) {
  if (!tglLahir) return 0;
  const lahir = new Date(tglLahir);
  const now = new Date();
  let umur = now.getFullYear() - lahir.getFullYear();
  const m = now.getMonth() - lahir.getMonth();
  if (m < 0 || (m === 0 && now.getDate() < lahir.getDate())) umur--;
  return umur;
}

// ------------------------------------------------------------
// Kirim permintaan pemeriksaan lab baru ke siLab.
// Dipanggil setelah rujukan_lab berhasil dibuat di SIMPUS.
// Return: { silabPasienId } kalau sukses, null kalau gagal (gagal
// kirim ke siLab TIDAK membatalkan alur SIMPUS — cuma dicatat).
// ------------------------------------------------------------
async function kirimPermintaanLabKeSilab({ pasien, jenisLabText, asalUnit, dokterPengirim, noRujukanSimpus, penjamin }) {
  try {
    const silabId = (typeof crypto !== "undefined" && crypto.randomUUID) ? crypto.randomUUID() : null;
    if (!silabId) throw new Error("Browser tidak mendukung crypto.randomUUID");

    const patientPayload = {
      id: silabId,
      nik: pasien.nik || "",
      no_kk: pasien.no_kk || "",
      nama: pasien.nama,
      tanggal_lahir: pasien.tanggal_lahir,
      jenis_kelamin: _genderKeSilab(pasien.jenis_kelamin),
      alamat: pasien.alamat || "",
      no_hp: pasien.no_hp || "",
      rm: pasien.no_rm || "",
      created_at: new Date().toISOString()
    };
    const { error: errPasien } = await silabClient.from("pasien").insert(patientPayload);
    if (errPasien) throw errPasien;

    const hasilAwal = {
      results: {}, status: {},
      fasting: "Tidak Puasa", fastingFrom: "", specType: "Darah Kapiler",
      validatedAt: "", validatedBy: "",
      regNum: noRujukanSimpus || `SIMPUS-${silabId.slice(0, 8).toUpperCase()}`,
      regTime: new Date().toTimeString().slice(0, 5),
      testIds: jenisLabText.split(",").map(s => s.trim()).filter(Boolean),
      patientStatus: "Menunggu",
      penjamin: penjamin || "Umum",
      asalPoli: asalUnit || "SIMPUS",
      dokterPengirim: dokterPengirim || "",
      rujukanKeluar: null, bhpUsage: [], catatanValidasi: ""
    };
    const examPayload = {
      id: silabId,
      pasien_id: silabId,
      jenis_pemeriksaan: jenisLabText,
      hasil: JSON.stringify(hasilAwal),
      keterangan: "Menunggu",
      foto_berkas: null,
      sync_status: "true",
      created_at: new Date().toISOString()
    };
    const { error: errPemeriksaan } = await silabClient.from("pemeriksaan").insert(examPayload);
    if (errPemeriksaan) {
      // rollback pasien di siLab supaya gak ada data yatim
      await silabClient.from("pasien").delete().eq("id", silabId);
      throw errPemeriksaan;
    }

    return { silabPasienId: silabId };
  } catch (err) {
    console.error("Gagal kirim permintaan lab ke siLab:", err.message || err);
    return null;
  }
}

// ------------------------------------------------------------
// Ambil status + hasil pemeriksaan dari siLab berdasarkan id
// pasien siLab (disimpan di rujukan_lab.silab_pasien_id).
// Return: { status, hasil: [{nama, hasil, satuan, nilaiRujukan, flag}], validatedAt, validatedBy, catatanValidasi } | null
// ------------------------------------------------------------
async function ambilStatusHasilSilab(silabPasienId) {
  if (!silabPasienId) return null;
  try {
    const { data: pemeriksaan, error } = await silabClient
      .from("pemeriksaan")
      .select("keterangan, hasil")
      .eq("pasien_id", silabPasienId)
      .maybeSingle();
    if (error || !pemeriksaan) return null;

    let parsed = {};
    try { parsed = pemeriksaan.hasil ? JSON.parse(pemeriksaan.hasil) : {}; } catch (e) { parsed = {}; }

    const status = pemeriksaan.keterangan || parsed.patientStatus || "Menunggu";
    const results = parsed.results || {};
    const resultsStatus = parsed.status || {};
    const parameters = await _muatSilabParameters();

    const hasilList = Object.keys(results).map(paramId => {
      const p = parameters.find(x => x.id === paramId);
      return {
        nama: p ? p.name : paramId,
        hasil: results[paramId],
        satuan: p ? p.unit : "",
        nilaiRujukan: p ? (p.male_normal || p.female_normal || p.child_normal || "-") : "-",
        flag: resultsStatus[paramId] || "N"
      };
    });

    return {
      status,
      hasil: hasilList,
      validatedAt: parsed.validatedAt || "",
      validatedBy: parsed.validatedBy || "",
      catatanValidasi: parsed.catatanValidasi || ""
    };
  } catch (err) {
    console.error("Gagal ambil status/hasil dari siLab:", err.message || err);
    return null;
  }
}

const BADGE_STATUS_SILAB = { "Menunggu": "badge-menunggu", "Validasi": "badge-diperiksa", "Selesai": "badge-selesai" };
