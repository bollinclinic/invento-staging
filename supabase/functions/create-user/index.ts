// Developer-only "create a new clinic staff account" action (tightened from superadmin --
// Users & roles is now a developer-only area). Auth admin.createUser needs the service-role
// key, which must never reach the browser -- so this runs server-side as an Edge Function
// instead of a client call. The caller's own JWT is verified against `profiles` (role =
// developer) before any privileged action runs; only then is a separate service-role client
// used to actually create the auth user. New accounts get a fixed default password the
// developer can hand to the new starter, who is expected to change it on first login via the
// existing "change password" feature.
import { createClient } from "npm:@supabase/supabase-js@2";

const DEFAULT_PASSWORD = "Bollin123!";
const VALID_ROLES = ["common", "staff", "admin", "superadmin", "developer"];

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // Client scoped to the CALLER's own JWT -- used only to verify who they are.
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: "Not signed in" }), { status: 401, headers: corsHeaders });
    }
    const { data: profile, error: profErr } = await callerClient
      .from("profiles").select("role,active").eq("id", userData.user.id).single();
    if (profErr || !profile || profile.role !== "developer" || profile.active !== true) {
      return new Response(JSON.stringify({ error: "Developer access required" }), { status: 403, headers: corsHeaders });
    }

    const body = await req.json();
    const username = String(body.username || "").trim().toLowerCase();
    const displayName = String(body.displayName || "").trim() || username;
    const role = String(body.role || "common");
    if (!username) return new Response(JSON.stringify({ error: "Username is required" }), { status: 400, headers: corsHeaders });
    if (!/^[a-z0-9._-]+$/.test(username)) return new Response(JSON.stringify({ error: "Username can only contain letters, numbers, dots, hyphens and underscores" }), { status: 400, headers: corsHeaders });
    if (!VALID_ROLES.includes(role)) return new Response(JSON.stringify({ error: "Invalid role" }), { status: 400, headers: corsHeaders });

    // Privileged client -- service role bypasses RLS and can call the auth admin API.
    const adminClient = createClient(supabaseUrl, serviceKey);
    const email = `${username}@bollin.local`;
    const { data: created, error: createErr } = await adminClient.auth.admin.createUser({
      email, password: DEFAULT_PASSWORD, email_confirm: true,
      user_metadata: { username, display_name: displayName, role },
    });
    if (createErr) {
      const msg = /already been registered|already exists/i.test(createErr.message)
        ? `Username "${username}" is already taken` : createErr.message;
      return new Response(JSON.stringify({ error: msg }), { status: 400, headers: corsHeaders });
    }

    return new Response(JSON.stringify({
      ok: true, username, displayName, role, password: DEFAULT_PASSWORD, userId: created.user.id,
    }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : String(e) }), { status: 500, headers: corsHeaders });
  }
});
