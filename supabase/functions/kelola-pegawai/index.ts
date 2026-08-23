// ============================================================
// Edge Function: kelola-pegawai
// Satu pintu buat admin ngatur akun pegawai (email/password/role/
// klaster/hak akses). Service role key CUMA dipakai di sini
// (server-side), gak pernah dikirim ke browser.
//
// Deploy: supabase functions deploy kelola-pegawai
// Env yang dipakai (otomatis tersedia di Supabase Edge Functions,
// gak perlu di-set manual): SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY
// ============================================================

import { serve } from "https://deno.land/std@0.203.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });

  const authHeader = req.headers.get("Authorization") ?? "";

  // Client atas nama user yang login, cuma buat verifikasi siapa dia
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !user) return json({ error: "Belum login." }, 401);

  // Client service_role, buat kerja beneran (bypass RLS, akses auth admin API)
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: callerProfil, error: profilErr } = await admin
    .from("profil_pegawai")
    .select("role")
    .eq("id", user.id)
    .single();

  if (profilErr || !callerProfil || callerProfil.role !== "admin") {
    return json({ error: "Cuma admin yang boleh kelola akun pegawai." }, 403);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Body request gak valid." }, 400);
  }

  const { action, payload } = body ?? {};

  try {
    switch (action) {
      // ------------------------------------------------------
      case "daftar_pegawai": {
        const { data: profilList, error: e1 } = await admin
          .from("profil_pegawai")
          .select(`
            id, nama, nip, role, klaster_id, aktif, created_at,
            klaster(nama, kode),
            pegawai_klaster(klaster_id, keterangan, klaster(nama, kode)),
            hak_akses(id, modul_kode, klaster_id, level)
          `)
          .order("nama");
        if (e1) throw e1;

        // Gabung email dari auth.users (gak ada di profil_pegawai)
        const { data: usersPage, error: e2 } = await admin.auth.admin.listUsers({ perPage: 1000 });
        if (e2) throw e2;
        const emailMap = new Map(usersPage.users.map((u) => [u.id, u.email]));

        const hasil = (profilList ?? []).map((p) => ({ ...p, email: emailMap.get(p.id) ?? null }));
        return json({ data: hasil });
      }

      // ------------------------------------------------------
      case "buat_pegawai": {
        const { email, password, nama, nip, role, klaster_id } = payload ?? {};
        if (!email || !password || !nama || !role) {
          return json({ error: "email, password, nama, role wajib diisi." }, 400);
        }
        const { data: created, error: e1 } = await admin.auth.admin.createUser({
          email, password, email_confirm: true,
        });
        if (e1) throw e1;

        const { error: e2 } = await admin.from("profil_pegawai").insert({
          id: created.user.id, nama, nip: nip || null, role, klaster_id: klaster_id || null, aktif: true,
        });
        if (e2) {
          // Rollback biar gak ada auth user nyangkut tanpa profil
          await admin.auth.admin.deleteUser(created.user.id);
          throw e2;
        }
        return json({ data: { id: created.user.id } });
      }

      // ------------------------------------------------------
      case "reset_password": {
        const { pegawai_id, password_baru } = payload ?? {};
        if (!pegawai_id || !password_baru) return json({ error: "pegawai_id & password_baru wajib." }, 400);
        const { error } = await admin.auth.admin.updateUserById(pegawai_id, { password: password_baru });
        if (error) throw error;
        return json({ data: { ok: true } });
      }

      // ------------------------------------------------------
      case "ubah_email": {
        const { pegawai_id, email_baru } = payload ?? {};
        if (!pegawai_id || !email_baru) return json({ error: "pegawai_id & email_baru wajib." }, 400);
        const { error } = await admin.auth.admin.updateUserById(pegawai_id, { email: email_baru, email_confirm: true });
        if (error) throw error;
        return json({ data: { ok: true } });
      }

      // ------------------------------------------------------
      case "update_profil": {
        const { pegawai_id, nama, nip, role, klaster_id, aktif } = payload ?? {};
        if (!pegawai_id) return json({ error: "pegawai_id wajib." }, 400);
        const patch: Record<string, unknown> = {};
        if (nama !== undefined) patch.nama = nama;
        if (nip !== undefined) patch.nip = nip;
        if (role !== undefined) patch.role = role;
        if (klaster_id !== undefined) patch.klaster_id = klaster_id;
        if (aktif !== undefined) patch.aktif = aktif;
        const { error } = await admin.from("profil_pegawai").update(patch).eq("id", pegawai_id);
        if (error) throw error;
        return json({ data: { ok: true } });
      }

      // ------------------------------------------------------
      // Timpa total akses klaster tambahan + hak akses granular pegawai ini
      case "set_akses": {
        const { pegawai_id, klaster_tambahan, hak_akses } = payload ?? {};
        // klaster_tambahan: [{klaster_id, keterangan}]
        // hak_akses: [{modul_kode, klaster_id|null, level}]
        if (!pegawai_id) return json({ error: "pegawai_id wajib." }, 400);

        const { error: eDel1 } = await admin.from("pegawai_klaster").delete().eq("pegawai_id", pegawai_id);
        if (eDel1) throw eDel1;
        if (Array.isArray(klaster_tambahan) && klaster_tambahan.length) {
          const { error: eIns1 } = await admin.from("pegawai_klaster").insert(
            klaster_tambahan.map((k: any) => ({ pegawai_id, klaster_id: k.klaster_id, keterangan: k.keterangan || null }))
          );
          if (eIns1) throw eIns1;
        }

        const { error: eDel2 } = await admin.from("hak_akses").delete().eq("pegawai_id", pegawai_id);
        if (eDel2) throw eDel2;
        if (Array.isArray(hak_akses) && hak_akses.length) {
          const { error: eIns2 } = await admin.from("hak_akses").insert(
            hak_akses.map((h: any) => ({ pegawai_id, modul_kode: h.modul_kode, klaster_id: h.klaster_id ?? null, level: h.level }))
          );
          if (eIns2) throw eIns2;
        }
        return json({ data: { ok: true } });
      }

      // ------------------------------------------------------
      default:
        return json({ error: `Action gak dikenal: ${action}` }, 400);
    }
  } catch (err) {
    return json({ error: err?.message || String(err) }, 500);
  }
});
