// bollin-theatre-proxy: the app's connection to the Theatre Records Excel file on SharePoint.
//
// THIS FILE IS PUBLIC (the repo is public). It must never contain a secret. The Microsoft
// details are Cloudflare Worker settings: CLIENT_SECRET (encrypted), TENANT_ID, CLIENT_ID,
// DRIVE_HOST, SITE_PATH, FILE_NAME and TABLE_NAME. The Supabase anon keys below are public by
// design (they are in the page too).
//
// Who may use it:
//   * A browser request must come from the production or staging site.
//   * The caller must be signed in to the app and have the Theatre & Ward permission. The Worker
//     asks the Supabase project that issued the sign-in (app_can('tw.view')), so a deactivated
//     account or an unticked person is refused at once. If that check cannot be made, the
//     answer is no.
//   * REQUIRE_LOGIN = "1" enforces this. Without it (only during a release, while open screens
//     still run the old page) a request with no sign-in is let through; a bad sign-in never is.
const ALLOWED_ORIGINS = ['https://bollin.hashirhub.uk', 'https://bollinclinic.github.io'];
const PROJECTS = {
  ozkragagmtdjjlkvygjc: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im96a3JhZ2FnbXRkampsa3Z5Z2pjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcwNTM5NTMsImV4cCI6MjEwMjYyOTk1M30.16yVOfJqDoyY7KYXnPn3KocwToCwWEYDRv8PGo-52nA',
  ozlskwtbgblfmqjgcrmf: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im96bHNrd3RiZ2JsZm1xamdjcm1mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcwNTQyNzEsImV4cCI6MjEwMjYzMDI3MX0.jTRbcxqPHoygje8zMXEZk-TaxJKv3m-y6-ZtY9wS0JA',
};
const TW_COLUMNS = 23;

function corsFor(origin) {
  if (!ALLOWED_ORIGINS.includes(origin)) return { Vary: 'Origin' };
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin',
  };
}
function reply(body, status, cors) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

// Which of our two Supabase projects issued this token. This only chooses where to check it:
// the token is proved genuine by that project in checkLogin.
function tokenProject(token) {
  const parts = String(token).split('.');
  if (parts.length !== 3) return null;
  try {
    let b = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    while (b.length % 4) b += '=';
    const m = /^https:\/\/([a-z0-9]+)\.supabase\.co\/auth\/v1$/.exec(String(JSON.parse(atob(b)).iss || ''));
    return m && Object.prototype.hasOwnProperty.call(PROJECTS, m[1]) ? m[1] : null;
  } catch (e) {
    return null;
  }
}
async function checkLogin(request, env) {
  const signIn = { ok: false, status: 401, error: 'Please sign in again' };
  const m = /^Bearer\s+(\S+)$/.exec(request.headers.get('Authorization') || '');
  if (!m) return env.REQUIRE_LOGIN === '1' ? signIn : { ok: true };
  const ref = tokenProject(m[1]);
  if (!ref) return signIn;
  const unavailable = { ok: false, status: 503, error: 'Could not check your sign-in. Try again' };
  let r;
  try {
    r = await fetch(`https://${ref}.supabase.co/rest/v1/rpc/app_can`, {
      method: 'POST',
      headers: { apikey: PROJECTS[ref], Authorization: 'Bearer ' + m[1], 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_key: 'tw.view' }),
    });
  } catch (e) {
    return unavailable;
  }
  if (r.status === 401 || r.status === 403) return signIn;
  if (!r.ok) return unavailable;
  const allowed = await r.json().catch(() => null);
  return allowed === true ? { ok: true } : { ok: false, status: 403, error: 'You do not have access to Theatre & Ward' };
}

function validRow(values) {
  return Array.isArray(values) && values.length === TW_COLUMNS &&
    values.every(v => v === null || ['string', 'number', 'boolean'].includes(typeof v));
}

export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin');
    const cors = corsFor(origin);
    if (origin && !ALLOWED_ORIGINS.includes(origin)) return reply({ ok: false, error: 'Not allowed' }, 403, cors);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });

    const login = await checkLogin(request, env);
    if (!login.ok) return reply({ ok: false, error: login.error }, login.status, cors);

    // work out what is being asked before touching SharePoint
    let action = '', body = {};
    if (request.method === 'GET') {
      action = new URL(request.url).searchParams.get('action') === 'getRows' ? 'getRows' : '';
    } else if (request.method === 'POST') {
      body = await request.json().catch(() => null);
      if (!body || typeof body !== 'object') return reply({ ok: false, error: 'Bad request' }, 400, cors);
      action = body.action === 'addRow' || body.action === 'updateRow' ? body.action : '';
    }
    if (!action) return reply({ ok: false, error: 'Unknown action' }, 400, cors);
    if (action !== 'getRows' && !validRow(body.values)) return reply({ ok: false, error: 'The row is not valid' }, 400, cors);
    if (action === 'updateRow' && !(Number.isInteger(body.index) && body.index >= 0)) {
      return reply({ ok: false, error: 'The row number is not valid' }, 400, cors);
    }

    try {
      const token = await getToken(env);
      const ids = await getFileIds(token, env);
      if (action === 'getRows') return reply({ ok: true, rows: await getRows(token, ids, env) }, 200, cors);
      if (action === 'addRow') {
        await addRow(token, ids, env, body.values);
        return reply({ ok: true, action: 'added' }, 200, cors);
      }
      await updateRow(token, ids, env, body.index, body.values);
      return reply({ ok: true, action: 'updated' }, 200, cors);
    } catch (e) {
      console.error('SharePoint request failed:', e && e.message);   // details stay in the Worker log
      return reply({ ok: false, error: 'SharePoint did not answer. Try again' }, 502, cors);
    }
  },
};

// A refused read must never look like an empty sheet, and a refused write must never look saved.
async function graph(token, url, init) {
  const headers = { Authorization: 'Bearer ' + token, ...((init && init.headers) || {}) };
  const r = await fetch('https://graph.microsoft.com/v1.0' + url, { ...(init || {}), headers });
  if (!r.ok) throw new Error('Graph answered ' + r.status);
  return r.json();
}
async function getToken(env) {
  const r = await fetch(`https://login.microsoftonline.com/${env.TENANT_ID}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials', client_id: env.CLIENT_ID, client_secret: env.CLIENT_SECRET,
      scope: 'https://graph.microsoft.com/.default',
    }),
  });
  const d = await r.json().catch(() => ({}));
  if (!d.access_token) throw new Error('Microsoft sign-in failed');
  return d.access_token;
}
async function getFileIds(token, env) {
  const site = await graph(token, `/sites/${env.DRIVE_HOST}:${env.SITE_PATH}`);
  const drives = await graph(token, `/sites/${site.id}/drives`);
  const driveId = drives.value[0].id;
  const files = await graph(token, `/drives/${driveId}/root/search(q='${encodeURIComponent(env.FILE_NAME)}')`);
  const file = (files.value || []).find(f => f.name === env.FILE_NAME);
  if (!file) throw new Error('File not found');
  return { driveId, fileId: file.id };
}
const tableUrl = (ids, env) => `/drives/${ids.driveId}/items/${ids.fileId}/workbook/tables/${env.TABLE_NAME}/rows`;
async function getRows(token, ids, env) {
  return (await graph(token, tableUrl(ids, env))).value || [];
}
async function addRow(token, ids, env, values) {
  await graph(token, tableUrl(ids, env) + '/add', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ values: [values] }),
  });
}
async function updateRow(token, ids, env, index, values) {
  await graph(token, tableUrl(ids, env) + `/itemAt(index=${index})`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ values: [values] }),
  });
}
