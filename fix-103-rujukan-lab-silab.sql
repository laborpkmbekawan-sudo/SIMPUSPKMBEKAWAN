-- ============================================================
-- 103. INTEGRASI SILAB — kolom jembatan di rujukan_lab
--      Menyimpan id pasien di siLab (project Supabase TERPISAH:
--      ayeuzvsipotqekvbtakp.supabase.co) supaya SIMPUS bisa narik
--      balik status (Menunggu/Validasi/Selesai) & hasil pemeriksaan
--      dari sana, tanpa perlu input manual dobel di SIMPUS.
--      Idempotent, aman diulang.
-- ============================================================

alter table rujukan_lab add column if not exists silab_pasien_id uuid;
alter table rujukan_lab add column if not exists silab_dikirim_at timestamptz;

create index if not exists idx_rujukan_lab_silab_pasien on rujukan_lab(silab_pasien_id);

-- ============================================================
-- SELESAI section 103. Idempotent, aman diulang.
-- ============================================================
