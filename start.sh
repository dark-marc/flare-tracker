#!/usr/bin/env bash
#
# cf.sh - manage Cloudflare Workers and KV namespaces with only curl (Flare Tracker).
#

set -uo pipefail

API="https://api.cloudflare.com/client/v4"
VERSION="1.36.2"
COMPAT_DATE="${COMPAT_DATE:-2025-06-01}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CREDS_FILE="${CREDS_FILE:-$SCRIPT_DIR/.cf_sh_creds}"
PROJ_FILE="${PROJ_FILE:-$SCRIPT_DIR/.cf_sh_project}"

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
AUTH=()
MODE="none"

PROJ_KV_ID=""; PROJ_KV_TITLE=""; PROJ_TRACKER=""; PROJ_ADMIN=""; PROJ_SUBDOMAIN=""

die() { echo "ERROR: $*" >&2; exit 1; }

banner() {

  cat <<'EOF'
 _____ _                 _____               _                     .--.
|  ___| | __ _ _ __ ___ |_   _| __ __ _  ___| | _____ _ __      .-(    ).
| |_  | |/ _` | '__/ _ \  | || '__/ _` |/ __| |/ / _ \ '__|    (___.__)__)
|  _| | | (_| | | |  __/  | || | | (_| | (__|   <  __/ |
|_|   |_|\__,_|_|  \___|  |_||_|  \__,_|\___|_|\_\___|_|

EOF
  
  echo "  by Dark Marc | V${VERSION}"
  echo
}

rebuild_auth() {
  AUTH=()
  if [[ -n "$CF_API_TOKEN" ]]; then
    AUTH=(-H "Authorization: Bearer ${CF_API_TOKEN}"); MODE="scoped token"; return 0
  fi
  MODE="none"; return 1
}

require_creds() {
  rebuild_auth || { echo "No credentials set. Type 'login', or 'set token <token>'."; return 1; }
  [[ -n "$CF_ACCOUNT_ID" ]] || { echo "No account id set. Type 'set account <id>'."; return 1; }
  return 0
}

show_status() {
  rebuild_auth || true
  echo "Auth type : ${MODE}"
  echo "Account   : ${CF_ACCOUNT_ID:-<unset>}"
  [[ -f "$CREDS_FILE" ]] && echo "Saved file: ${CREDS_FILE}"
}

choose_account() {
  rebuild_auth || { echo "Set a token first ('login' or 'set token <token>')."; return 1; }
  echo "Detecting your account..."
  local resp
  resp=$(curl -sS "${AUTH[@]}" "$API/accounts?per_page=50")
  if ! is_success "$resp"; then
    echo "Could not read the account. Ensure the token includes Account Settings: Read,"
    echo "or set it manually with 'set account <id>'."
    return 1
  fi
  local lines
  lines=$(printf '%s' "$resp" | tr -d '\n' \
    | grep -oE '"id"[[:space:]]*:[[:space:]]*"[0-9a-f]{32}"[[:space:]]*,[[:space:]]*"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([0-9a-f]{32})"[[:space:]]*,[[:space:]]*"name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1 \2/')
  [[ -n "$lines" ]] || { echo "No account returned. Set it with 'set account <id>'."; return 1; }
  local ids=() names=() l
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    ids+=("${l%% *}"); names+=("${l#* }")
  done <<< "$lines"
  if [[ ${#ids[@]} -eq 1 ]]; then
    CF_ACCOUNT_ID="${ids[0]}"
    echo "Using account: ${names[0]} (${CF_ACCOUNT_ID})"
    return 0
  fi
  echo "Multiple accounts found:"
  local i
  for i in "${!ids[@]}"; do
    printf "  %d) %s  (%s)\n" "$((i+1))" "${names[$i]}" "${ids[$i]}"
  done
  local pick; read -r -p "Pick a number: " pick
  if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ids[@]} )); then
    CF_ACCOUNT_ID="${ids[$((pick-1))]}"
    echo "Using account: ${names[$((pick-1))]} (${CF_ACCOUNT_ID})"
  else
    echo "Invalid choice."; return 1
  fi
}

do_login() {
  echo "Account-owned API token (starts with cfat_)."
  local t; read -r -s -p "API token: " t; echo
  [[ -n "$t" ]] || { echo "Cancelled."; return 1; }
  CF_API_TOKEN="$t"
  rebuild_auth >/dev/null 2>&1 || true
  if [[ -z "$CF_ACCOUNT_ID" ]]; then
    choose_account || read -r -p "Account ID: " CF_ACCOUNT_ID
  fi
  if rebuild_auth; then
    echo "Credentials set. Type 'save' to remember them for next time."
  else
    echo "No token set. Type 'status' to check."
  fi
}

do_set() {
  case "${1:-}" in
    token)   [[ -n "${2:-}" ]] || { echo "Usage: set token <token>"; return 1; }
             CF_API_TOKEN="$2" ;;
    account) if [[ "${2:-}" == "auto" ]]; then
               choose_account || return 1
             else
               [[ -n "${2:-}" ]] || { echo "Usage: set account <id> | set account auto"; return 1; }
               CF_ACCOUNT_ID="$2"
             fi ;;
    *) echo "Usage: set token <token> | set account <id> | set account auto"; return 1 ;;
  esac
  rebuild_auth || true
  echo "Updated. Auth type: ${MODE}, account: ${CF_ACCOUNT_ID:-<unset>}."
}

save_creds() {
  rebuild_auth || { echo "Nothing to save yet."; return 1; }
  umask 077
  {
    printf 'CF_API_TOKEN=%q\n'  "$CF_API_TOKEN"
    printf 'CF_ACCOUNT_ID=%q\n' "$CF_ACCOUNT_ID"
  } > "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  echo "Saved to ${CREDS_FILE}."
}

load_creds() {
  if ! rebuild_auth && [[ -f "$CREDS_FILE" ]]; then
    source "$CREDS_FILE" 2>/dev/null || true
    rebuild_auth || true
  fi
}

load_project() {
  [[ -f "$PROJ_FILE" ]] && { source "$PROJ_FILE" 2>/dev/null || true; }
  return 0
}

save_project() {
  umask 077
  {
    printf 'PROJ_KV_ID=%q\n'     "$PROJ_KV_ID"
    printf 'PROJ_KV_TITLE=%q\n'  "$PROJ_KV_TITLE"
    printf 'PROJ_TRACKER=%q\n'   "$PROJ_TRACKER"
    printf 'PROJ_ADMIN=%q\n'     "$PROJ_ADMIN"
    printf 'PROJ_SUBDOMAIN=%q\n' "$PROJ_SUBDOMAIN"
  } > "$PROJ_FILE"
  chmod 600 "$PROJ_FILE"
}

logout() {
  CF_API_TOKEN=""
  rebuild_auth || true
  [[ -f "$CREDS_FILE" ]] && { rm -f "$CREDS_FILE"; echo "Removed ${CREDS_FILE}."; }
  echo "Credentials cleared for this session."
}

pretty() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool 2>/dev/null || cat
  else
    cat
  fi
}

req() { curl -sS "${AUTH[@]}" "$@"; }

is_success() { local s="${1// /}"; [[ "$s" == *'"success":true'* ]]; }

acc() { printf '%s/accounts/%s%s' "$API" "$CF_ACCOUNT_ID" "$1"; }

extract_ns_id() { grep -oE '[0-9a-f]{32}' | head -n1; }

json_str() {
  printf '%s' "$1" \
    | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 \
    | sed -E "s/.*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

ns_id_by_title() {
  printf '%s' "$1" | tr -d '\n' \
    | grep -oE "\"id\"[[:space:]]*:[[:space:]]*\"[0-9a-f]{32}\"[[:space:]]*,[[:space:]]*\"title\"[[:space:]]*:[[:space:]]*\"$2\"" \
    | grep -oE '[0-9a-f]{32}' | head -n1
}

workers_list()   { req "$(acc /workers/scripts)" | pretty; }
workers_get()    { [[ $# -ge 1 ]] || die "workers get NAME"; req "$(acc "/workers/scripts/$1")"; echo; }
workers_delete() { [[ $# -ge 1 ]] || die "workers delete NAME"; req -X DELETE "$(acc "/workers/scripts/$1")" | pretty; }

workers_deploy() {
  [[ $# -ge 2 ]] || die "workers deploy NAME FILE.js [BIND=NS_ID ...]"
  local name="$1" file="$2"; shift 2
  [[ -f "$file" ]] || die "File not found: $file"

  local bindings="" b bname bid
  for b in "$@"; do
    bname="${b%%=*}"; bid="${b#*=}"
    [[ -n "$bname" && -n "$bid" && "$bname" != "$bid" ]] \
      || die "Bad binding '$b'. Use NAME=NS_ID."
    [[ -n "$bindings" ]] && bindings+=","
    bindings+="{\"type\":\"kv_namespace\",\"name\":\"${bname}\",\"namespace_id\":\"${bid}\"}"
  done

  local meta="{\"main_module\":\"worker.js\",\"compatibility_date\":\"${COMPAT_DATE}\",\"bindings\":[${bindings}]}"
  local resp
  resp=$(req -X PUT "$(acc "/workers/scripts/${name}")" \
    -F "metadata=${meta};type=application/json" \
    -F "worker.js=@${file};filename=worker.js;type=application/javascript+module")
  is_success "$resp" \
    && echo "Deployed ${name}." \
    || { echo "$resp" | pretty; die "Deploy failed."; }
}

workers_url() {
  [[ $# -ge 2 ]] || die "workers url NAME on|off"
  local name="$1" state="$2" enabled
  case "$state" in on) enabled=true;; off) enabled=false;; *) die "Use on or off.";; esac
  req -X POST -H "content-type: application/json" \
    "$(acc "/workers/scripts/${name}/subdomain")" \
    --data "{\"enabled\":${enabled}}" | pretty
}

kv_list()   { req "$(acc '/storage/kv/namespaces?per_page=100')" | pretty; }

kv_id() {
  [[ $# -ge 1 ]] || die "kv id TITLE"
  local id
  id=$(ns_id_by_title "$(req "$(acc '/storage/kv/namespaces?per_page=100')")" "$1")
  [[ -n "${id:-}" ]] && echo "$id" || die "No namespace titled '$1'."
}

kv_create() {
  [[ $# -ge 1 ]] || die "kv create TITLE"
  req -X POST -H "content-type: application/json" \
    "$(acc '/storage/kv/namespaces')" --data "{\"title\":\"$1\"}" | pretty
}

kv_rename() {
  [[ $# -ge 2 ]] || die "kv rename NS_ID NEW_TITLE"
  req -X PUT -H "content-type: application/json" \
    "$(acc "/storage/kv/namespaces/$1")" --data "{\"title\":\"$2\"}" | pretty
}

kv_delete() {
  [[ $# -ge 1 ]] || die "kv delete NS_ID"
  req -X DELETE "$(acc "/storage/kv/namespaces/$1")" | pretty
}

kv_keys() { [[ $# -ge 1 ]] || die "kv keys NS_ID"; req "$(acc "/storage/kv/namespaces/$1/keys")" | pretty; }
kv_get()  { [[ $# -ge 2 ]] || die "kv get NS_ID KEY"; req "$(acc "/storage/kv/namespaces/$1/values/$2")"; echo; }
kv_put()  { [[ $# -ge 3 ]] || die "kv put NS_ID KEY VALUE"; req -X PUT "$(acc "/storage/kv/namespaces/$1/values/$2")" --data "$3" | pretty; }
kv_del()  { [[ $# -ge 2 ]] || die "kv del NS_ID KEY"; req -X DELETE "$(acc "/storage/kv/namespaces/$1/values/$2")" | pretty; }

tracker_worker_src() {
  cat <<'JS'
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    if (path.startsWith("/mgmt-panel")) return handleMgmtApi(request, env, path, url);
    if (path === "/admin" || path === "/panel") {
      if (await adminBlocked(request, env)) return notFound();
      return new Response(ADMIN_PAGE, { headers: { "content-type": "text/html; charset=utf-8" } });
    }
    if (path.startsWith("/collect/")) return handleEnhancedCollect(request, env, path);
    if (path.startsWith("/img/")) return serveImage(request, env, path);
    if (path.startsWith("/s/")) return handleRedirect(request, env, url, ctx);
    return new Response("Flare Tracker", { headers: { "content-type": "text/plain" } });
  }
};
function safeEqual(a, b) {
  a = a || ""; b = b || "";
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
function notFound() { return new Response("Not Found", { status: 404, headers: { "content-type": "text/plain" } }); }
// True when the admin surface should behave as if it does not exist: either the
// panel is disabled, or an IP allowlist is on and the caller is not on it.
// Returning 404 in these cases avoids revealing that anything is there.
async function adminBlocked(request, env) {
  if ((await env.FT_CACHE.get("admin_enabled")) === "false") return true;
  if ((await env.FT_CACHE.get("admin_ip_on")) === "true") {
    const raw = (await env.FT_CACHE.get("admin_ips")) || "";
    const allow = raw.split(",").map(function (s) { return s.trim(); }).filter(Boolean);
    if (allow.length > 0) {
      const ip = request.headers.get("CF-Connecting-IP") || "";
      if (!allow.includes(ip)) return true;
    }
  }
  return false;
}
function getCookie(request, name) {
  const c = request.headers.get("Cookie") || "";
  const m = c.match(new RegExp("(?:^|; )" + name + "=([^;]+)"));
  return m ? m[1] : "";
}
async function validSession(request, env) {
  const t = getCookie(request, "nx_session");
  if (!t) return false;
  return !!(await env.FT_CACHE.get("session:" + t));
}
async function authenticateAdmin(request, env) {
  // A valid session cookie or the bearer password. The IP allowlist and the
  // disabled switch are checked earlier (adminBlocked), so neither a cookie nor
  // the password can bypass them.
  if (await validSession(request, env)) return true;
  const authHeader = request.headers.get("Authorization") || "";
  if (!authHeader.startsWith("Bearer ")) return false;
  const stored = (await env.FT_CACHE.get("pwd")) || "";
  if (!stored) return false;
  return safeEqual(authHeader.slice(7).trim(), stored);
}
function sessionCookie(token, maxAge) {
  return "nx_session=" + token + "; HttpOnly; Secure; SameSite=Strict; Path=/mgmt-panel; Max-Age=" + maxAge;
}
async function handleMgmtApi(request, env, path, url) {
  // Blocked callers get 404 for everything, identical to an unknown path, so the
  // API does not confirm it exists to bots or disallowed addresses.
  if (await adminBlocked(request, env)) return notFound();
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders() });

  // Login verifies the password and mints a session cookie. It is the only
  // authenticated-panel route reachable without already being authenticated.
  if (path === "/mgmt-panel/login" && request.method === "POST") {
    const authHeader = request.headers.get("Authorization") || "";
    const provided = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
    const stored = (await env.FT_CACHE.get("pwd")) || "";
    if (!stored || !safeEqual(provided, stored)) return jsonResponse({ error: "Unauthorized" }, 401);
    const token = (crypto.randomUUID() + crypto.randomUUID()).replace(/-/g, "");
    await env.FT_CACHE.put("session:" + token, "1", { expirationTtl: 604800 });
    return new Response(JSON.stringify({ success: true }), { status: 200, headers: { "Content-Type": "application/json", "Set-Cookie": sessionCookie(token, 604800), ...corsHeaders() } });
  }
  if (path === "/mgmt-panel/logout" && request.method === "POST") {
    const t = getCookie(request, "nx_session");
    if (t) await env.FT_CACHE.delete("session:" + t);
    return new Response(JSON.stringify({ success: true }), { status: 200, headers: { "Content-Type": "application/json", "Set-Cookie": sessionCookie("", 0), ...corsHeaders() } });
  }

  if (!await authenticateAdmin(request, env)) return jsonResponse({ error: "Unauthorized access" }, 401);
  
  if (path === "/mgmt-panel/create" && request.method === "POST") {
    const payload = await request.json();
    let token = (payload.token || "").replace(/[^A-Za-z0-9._-]/g, "");
    if (!token) token = crypto.randomUUID().slice(0, 8);
    const linkConfig = { token, campaign: payload.campaign || "", redirect_to: payload.redirect_to, custom_domain: payload.custom_domain || "", analytics_level: payload.analytics_level || "standard", skip_consent: payload.skip_consent === true, og_title: payload.og_title || "", og_description: payload.og_description || "", og_image: payload.og_image || "", created_at: new Date().toISOString() };
    await env.FT_CACHE.put(`link:${token}`, JSON.stringify(linkConfig));
    return jsonResponse({ success: true, campaign_url: `https://${linkConfig.custom_domain || url.hostname}/s/${token}`, link: linkConfig }, 201);
  }
  if (path === "/mgmt-panel/links" && request.method === "GET") {
    const list = await env.FT_CACHE.list({ prefix: "link:" });
    const links = [];
    for (const key of list.keys) { const data = await env.FT_CACHE.get(key.name, { type: "json" }); if (data) links.push(data); }
    return jsonResponse({ links });
  }
  if (path.startsWith("/mgmt-panel/links/") && request.method === "PUT") {
    const tok = decodeURIComponent(path.replace("/mgmt-panel/links/", ""));
    const raw = await env.FT_CACHE.get("link:" + tok);
    if (!raw) return jsonResponse({ error: "No such link" }, 404);
    const cur = JSON.parse(raw);
    const p = await request.json();
    const pick = function (k) { return p[k] != null ? p[k] : cur[k]; };
    const upd = {
      token: cur.token, created_at: cur.created_at, custom_domain: cur.custom_domain,
      campaign: pick("campaign"), redirect_to: pick("redirect_to"),
      analytics_level: pick("analytics_level"), skip_consent: pick("skip_consent"),
      og_title: pick("og_title"), og_description: pick("og_description"), og_image: pick("og_image")
    };
    await env.FT_CACHE.put("link:" + tok, JSON.stringify(upd));
    return jsonResponse({ success: true, link: upd, campaign_url: "https://" + (upd.custom_domain || url.host) + "/s/" + upd.token });
  }
  if (path.startsWith("/mgmt-panel/links/") && request.method === "DELETE") {
    await env.FT_CACHE.delete(`link:${decodeURIComponent(path.replace("/mgmt-panel/links/", ""))}`);
    return jsonResponse({ success: true });
  }
  if (path === "/mgmt-panel/results" || path === "/mgmt-panel/logs") {
    // Map token -> current campaign name so renames show on historical results.
    const linkList = await env.FT_CACHE.list({ prefix: "link:" });
    const nameByToken = {};
    for (const k of linkList.keys) { const l = await env.FT_CACHE.get(k.name, { type: "json" }); if (l && l.token) nameByToken[l.token] = l.campaign || ""; }
    const list = await env.FT_CACHE.list({ prefix: "result:" });
    const results = [];
    for (const key of list.keys) {
      const data = await env.FT_CACHE.get(key.name, { type: "json" });
      if (data) {
        data._kv_key = key.name;
        if (nameByToken[data.token]) data.campaign = nameByToken[data.token];
        results.push(data);
      }
    }
    return jsonResponse({ results });
  }
  if (path === "/mgmt-panel/clear-logs" && request.method === "DELETE") {
    const list = await env.FT_CACHE.list({ prefix: "result:" });
    for (const key of list.keys) await env.FT_CACHE.delete(key.name);
    return jsonResponse({ success: true });
  }
  if (path === "/mgmt-panel/domains" && request.method === "GET") {
    const raw = await env.FT_CACHE.get("config:domains");
    let domains = [];
    if (raw) { try { const o = JSON.parse(raw); domains = Object.keys(o).map(function (h) { return { hostname: h, attached: !!o[h].attached }; }); } catch (e) {} }
    return jsonResponse({ domains });
  }
  if (path === "/mgmt-panel/images" && request.method === "GET") {
    const list = await env.FT_CACHE.list({ prefix: "img:" });
    const images = list.keys.map(function (k) { const key = k.name.slice(4); return { key, url: "https://" + url.host + "/img/" + key }; });
    return jsonResponse({ images });
  }
  if (path === "/mgmt-panel/upload" && request.method === "POST") {
    const key = (url.searchParams.get("key") || "").replace(/[^A-Za-z0-9._-]/g, "");
    if (!key) return jsonResponse({ error: "Missing or invalid key" }, 400);
    const buf = await request.arrayBuffer();
    const dims = imageDims(buf);
    if (!dims) return jsonResponse({ error: "Unrecognized image (use PNG, JPEG, GIF, or WEBP)" }, 400);
    if (dims.w !== 1200 || dims.h !== 630) return jsonResponse({ error: "Image must be exactly 1200x630 px, got " + dims.w + "x" + dims.h }, 400);
    await env.FT_CACHE.put("img:" + key, buf, { metadata: { ct: dims.type } });
    return jsonResponse({ success: true, key, url: "https://" + url.host + "/img/" + key });
  }
  if (path.startsWith("/mgmt-panel/images/") && request.method === "DELETE") {
    await env.FT_CACHE.delete("img:" + decodeURIComponent(path.replace("/mgmt-panel/images/", "")));
    return jsonResponse({ success: true });
  }
  return jsonResponse({ error: "Not found" }, 404);
}
// Parse image dimensions from the file header (PNG, JPEG, GIF, WEBP). No deps.
function imageDims(ab) {
  const b = new Uint8Array(ab);
  if (b.length > 24 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47) {
    return { w: ((b[16]<<24)|(b[17]<<16)|(b[18]<<8)|b[19])>>>0, h: ((b[20]<<24)|(b[21]<<16)|(b[22]<<8)|b[23])>>>0, type: "image/png" };
  }
  if (b.length > 10 && b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) {
    return { w: b[6]|(b[7]<<8), h: b[8]|(b[9]<<8), type: "image/gif" };
  }
  if (b.length > 4 && b[0] === 0xFF && b[1] === 0xD8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xFF) { i++; continue; }
      const m = b[i+1];
      if (m >= 0xC0 && m <= 0xCF && m !== 0xC4 && m !== 0xC8 && m !== 0xCC) {
        return { h: (b[i+5]<<8)|b[i+6], w: (b[i+7]<<8)|b[i+8], type: "image/jpeg" };
      }
      const len = (b[i+2]<<8)|b[i+3];
      if (len < 2) break;
      i += 2 + len;
    }
    return null;
  }
  if (b.length > 30 && b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) {
    const fmt = String.fromCharCode(b[12], b[13], b[14], b[15]);
    if (fmt === "VP8 ") return { w: (b[26]|(b[27]<<8)) & 0x3fff, h: (b[28]|(b[29]<<8)) & 0x3fff, type: "image/webp" };
    if (fmt === "VP8X") return { w: 1 + (b[24]|(b[25]<<8)|(b[26]<<16)), h: 1 + (b[27]|(b[28]<<8)|(b[29]<<16)), type: "image/webp" };
  }
  return null;
}
async function serveImage(request, env, path) {
  const key = decodeURIComponent(path.replace("/img/", ""));
  const res = await env.FT_CACHE.getWithMetadata("img:" + key, { type: "arrayBuffer" });
  if (!res || !res.value) return new Response("Not Found", { status: 404 });
  const ct = (res.metadata && res.metadata.ct) || "application/octet-stream";
  return new Response(res.value, { headers: { "content-type": ct, "cache-control": "public, max-age=86400" } });
}
async function handleRedirect(request, env, url, ctx) {
  const token = decodeURIComponent(url.pathname.replace("/s/", "").trim());
  const rawData = await env.FT_CACHE.get(`link:${token}`);
  if (!rawData) return new Response("Not Found", { status: 404 });
  const linkConfig = JSON.parse(rawData);
  // Skip the interstitial only when the operator has marked consent as obtained
  // upstream. Still records server-side telemetry (no client fingerprint, since
  // no page renders). Default behavior is unchanged: show the consent page.
  if (linkConfig.skip_consent === true && /^https?:\/\//i.test(linkConfig.redirect_to || "")) {
    if (ctx && ctx.waitUntil) ctx.waitUntil(recordTelemetry(request, env, linkConfig, {}));
    else await recordTelemetry(request, env, linkConfig, {});
    return Response.redirect(linkConfig.redirect_to, 302);
  }
  const enhanced = linkConfig.analytics_level === "enhanced";
  return new Response(disclosurePage(token, linkConfig.redirect_to, enhanced, linkConfig), {
    headers: { "Content-Type": "text/html; charset=utf-8" }
  });
}
async function handleEnhancedCollect(request, env, path) {
  const token = decodeURIComponent(path.replace("/collect/", "").trim());
  const rawData = await env.FT_CACHE.get(`link:${token}`);
  if (!rawData) return new Response("Missing", { status: 404 });
  await recordTelemetry(request, env, JSON.parse(rawData), await request.json());
  return jsonResponse({ status: "ok" });
}
async function recordTelemetry(request, env, linkConfig, clientPayload) {
  const cf = request.cf || {};
  const record = { token: linkConfig.token, campaign: linkConfig.campaign, redirect_to: linkConfig.redirect_to, timestamp: new Date().toISOString(), ip: request.headers.get("cf-connecting-ip") || "0.0.0.0", country: cf.country || "Unknown", city: cf.city || "Unknown", asn: (cf.asn != null ? cf.asn : ""), isp: cf.asOrganization || "", user_agent: request.headers.get("user-agent") || "", client_fingerprint: clientPayload };
  const rid = Date.now() + "-" + Math.random().toString(36).slice(2, 8);
  await env.FT_CACHE.put(`result:${linkConfig.token}:${rid}`, JSON.stringify(record));
}
function escapeHtml(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[c];
  });
}
function disclosurePage(token, dest, enhanced, cfg) {
  cfg = cfg || {};
  const isHttp = /^https?:\/\//i.test(dest || "");
  const navHref = isHttp ? dest : "about:blank";
  const safeNav = escapeHtml(navHref);
  const safeShown = escapeHtml(dest);
  const safeToken = escapeHtml(token);
  // Open Graph / Twitter preview tags. Their own block in <head>, independent of
  // the consent UI below. Only emitted for fields that are set.
  let og = "";
  const ogt = cfg.og_title || "", ogd = cfg.og_description || "", ogi = cfg.og_image || "";
  if (ogt) og += '<meta property="og:title" content="' + escapeHtml(ogt) + '">\n';
  if (ogd) og += '<meta property="og:description" content="' + escapeHtml(ogd) + '">\n';
  if (ogi) {
    og += '<meta property="og:image" content="' + escapeHtml(ogi) + '">\n';
    og += '<meta name="twitter:card" content="summary_large_image">\n';
  } else if (ogt || ogd) {
    og += '<meta name="twitter:card" content="summary">\n';
  }
  if (ogt) og += '<meta name="twitter:title" content="' + escapeHtml(ogt) + '">\n';
  if (ogd) og += '<meta name="twitter:description" content="' + escapeHtml(ogd) + '">\n';
  if (ogi) og += '<meta name="twitter:image" content="' + escapeHtml(ogi) + '">\n';
  const items = [
    "Your IP address",
    "Your approximate location (country and city), derived from your IP address",
    "Your internet provider and network (ISP and ASN)",
    "Your browser identification (user agent)",
    "The date and time you followed this link"
  ];
  if (enhanced) items.push("Your browser and device details (screen size, platform, and time zone)");
  const list = items.map(function (i) { return "<li>" + escapeHtml(i) + "</li>"; }).join("");
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${og}<title>Before you continue</title>
<style>
  body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; background: #0f1115; color: #e7e9ee; margin: 0; display: flex; min-height: 100vh; align-items: center; justify-content: center; padding: 24px; }
  .card { max-width: 520px; width: 100%; background: #1a1d24; border: 1px solid #2a2f3a; border-radius: 12px; padding: 28px; }
  h1 { font-size: 1.25rem; margin: 0 0 12px; }
  p { line-height: 1.5; color: #b7bdca; }
  ul { line-height: 1.6; color: #b7bdca; padding-left: 20px; }
  .dest { word-break: break-all; color: #e7e9ee; }
  .actions { display: flex; gap: 12px; margin-top: 20px; flex-wrap: wrap; }
  a.btn { text-decoration: none; padding: 10px 18px; border-radius: 8px; font-weight: 600; display: inline-block; }
  .go { background: #3b82f6; color: #fff; }
  .leave { background: transparent; color: #b7bdca; border: 1px solid #2a2f3a; }
  .fine { font-size: 0.8rem; color: #7c8494; margin-top: 16px; }
</style>
</head>
<body>
  <div class="card">
    <h1>This link records some information</h1>
    <p>You are about to be forwarded to:</p>
    <p class="dest">${safeShown}</p>
    <p>If you choose to continue, this service will record:</p>
    <ul>${list}</ul>
    <p>Nothing is recorded unless you continue.</p>
    <div class="actions">
      <a class="btn go" id="go" href="${safeNav}" data-token="${safeToken}" data-dest="${safeNav}" data-enhanced="${enhanced ? "1" : "0"}">Continue</a>
      <a class="btn leave" href="about:blank">No thanks</a>
    </div>
    <p class="fine">You are seeing this notice because this is a tracked link.</p>
  </div>
  <script>
    (function () {
      var go = document.getElementById("go");
      if (!go) return;
      go.addEventListener("click", function (e) {
        e.preventDefault();
        var dest = go.getAttribute("data-dest");
        var token = go.getAttribute("data-token");
        var enhanced = go.getAttribute("data-enhanced") === "1";
        var payload = {};
        if (enhanced) {
          payload.screen_resolution = screen.width + "x" + screen.height;
          payload.platform = navigator.platform;
          try { payload.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone; } catch (_) {}
        }
        try { navigator.sendBeacon("/collect/" + encodeURIComponent(token), JSON.stringify(payload)); } catch (_) {}
        window.location.href = dest;
      });
    })();
  <\/script>
</body>
</html>`;
}
function jsonResponse(data, status = 200) { return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...corsHeaders() } }); }
function corsHeaders() { return { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS", "Access-Control-Allow-Headers": "Content-Type, Authorization" }; }
const ADMIN_PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Flare Tracker</title>
<!--nx-build:1.36.1-->
<style>
 :root{
   color-scheme:dark;
   --bg:#0f1115; --panel:#1a1d24; --field:#12151c;
   --border:#2b313d; --border-soft:#242a34;
   --text:#e7e9ee; --muted:#8b93a7; --label:#9aa3b6;
   --accent:#5b7cf0; --accent-soft:rgba(91,124,240,.16);
   --link:#8fb0ff;
   --danger:#e08a8a; --danger-border:#4a3338; --danger-soft:rgba(224,138,138,.12);
   --new:#4fae82; --new-bg:rgba(79,174,130,.13);
 }
 body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--text);margin:0;padding:24px}
 .wrap{max-width:1000px;margin:0 auto}
 h1{font-size:1.3rem;margin:0 0 4px}.sub{color:var(--muted);font-size:.85rem;margin:0 0 20px}
 .card{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:20px;margin-bottom:20px}
 details.sect>summary{cursor:pointer;font-weight:700;font-size:1rem;list-style:none;display:flex;align-items:center;gap:8px;user-select:none;margin:-20px;padding:20px;border-radius:12px}
 details.sect[open]>summary{margin-bottom:0;border-radius:12px 12px 0 0}
 details.sect>summary:hover{background:rgba(255,255,255,.03)}
 details.sect>summary::-webkit-details-marker{display:none}
 details.sect>summary::before{content:"\\25B8";color:var(--muted);transition:transform .15s;display:inline-block}
 details.sect[open]>summary::before{transform:rotate(90deg)}
 details.sub{margin:10px 0;border:1px solid var(--border-soft);border-radius:8px;padding:8px 10px}
 details.sub>summary{cursor:pointer;color:var(--label);font-size:.8rem;list-style:none;user-select:none;margin:-8px -10px;padding:8px 10px;border-radius:8px}
 details.sub[open]>summary{margin-bottom:6px}
 details.sub>summary:hover{background:rgba(255,255,255,.03)}
 details.sub>summary::-webkit-details-marker{display:none}
 details.sub>summary::before{content:"\\25B8";margin-right:6px;transition:transform .15s;display:inline-block}
 details.sub[open]>summary::before{transform:rotate(90deg)}
 label{display:block;font-size:.72rem;color:var(--label);margin:0 0 4px}
 input,select{width:100%;box-sizing:border-box;background:var(--field);border:1px solid var(--border);color:var(--text);border-radius:8px;padding:8px;font-size:.9rem;font-family:inherit}
 input:focus,select:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
 select{appearance:none;-webkit-appearance:none;-moz-appearance:none;padding-right:30px;cursor:pointer;background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='12' viewBox='0 0 12 12'%3E%3Cpath d='M2 4l4 4 4-4' stroke='%238b93a7' stroke-width='1.6' fill='none' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");background-repeat:no-repeat;background-position:right 10px center;background-size:12px}
 select option{background:var(--panel);color:var(--text)}
 .nxwrap{position:relative}
 .nxbtn{width:100%;box-sizing:border-box;background:var(--field);border:1px solid var(--border);color:var(--text);border-radius:8px;padding:8px 30px 8px 10px;font-size:.9rem;font-family:inherit;text-align:left;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;position:relative}
 .nxbtn::after{content:"";position:absolute;right:12px;top:44%;width:7px;height:7px;border-right:2px solid var(--muted);border-bottom:2px solid var(--muted);transform:translateY(-50%) rotate(45deg)}
 .nxbtn:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
 .nxlist{position:absolute;top:100%;left:0;right:0;z-index:70;background:var(--panel);border:1px solid var(--border);border-radius:8px;margin-top:4px;max-height:260px;overflow:auto;box-shadow:0 8px 24px rgba(0,0,0,.5);display:none}
 .nxlist.open{display:block}
 .nxsearch{width:100%;box-sizing:border-box;border:0;border-bottom:1px solid var(--border);background:var(--panel);color:var(--text);padding:8px 10px;font-size:.85rem;position:sticky;top:0}
 .nxsearch:focus{outline:none}
 .nxopt{display:flex;align-items:center;gap:8px;padding:7px 10px;font-size:.9rem;cursor:pointer}
 .nxopt:hover{background:#262c38}
 .nxopt.sel{background:var(--accent-soft)}
 .nxopt .lbl{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
 .nxopt img{width:48px;height:25px;object-fit:cover;border-radius:3px;border:1px solid var(--border)}
 .nxopt .del{color:var(--danger);background:none;border:0;cursor:pointer;font-size:.9rem;padding:2px 6px;flex:none}
 .nxsel-native{display:none!important}
 .thumb{margin-top:8px;max-width:200px;border:1px solid var(--border);border-radius:6px;display:none}
 .actbtns{display:flex;gap:8px;flex-wrap:nowrap}
 .actbtns button{padding:6px 14px;font-size:.82rem}
 #linksBody td:last-child{white-space:nowrap;width:1%}
 .grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}
 button{background:var(--accent);color:#fff;border:0;border-radius:8px;padding:9px 16px;font-weight:600;cursor:pointer;font-size:.9rem}
 button:hover{filter:brightness(1.08)}
 button.sec{background:#262c38;color:#cdd3df}
 button.danger{background:transparent;color:var(--danger);border:1px solid var(--danger-border)}
 button.danger:hover{background:var(--danger-soft);filter:none}
 table{width:100%;border-collapse:collapse;font-size:.85rem;margin-top:8px}
 th,td{text-align:left;padding:8px;border-bottom:1px solid var(--border-soft);vertical-align:top}
 th{color:var(--muted);text-transform:uppercase;font-size:.7rem}
 .hidden{display:none!important}.muted{color:var(--muted);font-size:.85rem}
 .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
 a{color:var(--link);word-break:break-all}.right{margin-left:auto}
 .modalbg{position:fixed;inset:0;background:rgba(0,0,0,.6);display:flex;align-items:flex-start;justify-content:center;padding:40px 16px;overflow:auto;z-index:50}
 .modal{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:24px;max-width:640px;width:100%}
 .clink{color:var(--link);cursor:pointer;text-decoration:underline}
 .info{display:inline-block;width:15px;height:15px;line-height:15px;text-align:center;border-radius:50%;background:#2b313d;color:var(--label);font-size:10px;font-weight:700;margin-left:6px;cursor:help}
 input:disabled,select:disabled{opacity:.5;cursor:not-allowed}
 .filters{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px 14px;margin:14px 0;align-items:end}
 .filters>div{display:flex;flex-direction:column;min-width:0}
 .filters input,.filters select{width:100%;box-sizing:border-box}
 .fieldbtn{width:100%;box-sizing:border-box;background:var(--field);border:1px solid var(--border);color:var(--text);border-radius:8px;padding:8px;font-size:.9rem;font-weight:400;text-align:left;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer}
 .fieldbtn:hover{border-color:var(--accent)}
 #resBody td{white-space:normal;word-break:break-word;vertical-align:top}
 #resBody td:last-child{max-width:280px;font-size:.8rem;color:#b7bdca}
 #resBody tr.newrow td{background:var(--new-bg)}
 #resBody tr.newrow td:first-child{box-shadow:inset 3px 0 0 var(--new)}
 .pop{position:absolute;top:100%;left:0;z-index:60;background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:10px;margin-top:4px;width:232px;box-shadow:0 8px 24px rgba(0,0,0,.5)}
 .pop .cd{display:flex;justify-content:space-between;align-items:center;margin-bottom:6px}
 .pop .cd button{background:#262c38;color:#cdd3df;padding:2px 9px;font-size:1rem}
 .pop .cd span{font-size:.85rem;color:var(--text)}
 .pop .grid7{display:grid;grid-template-columns:repeat(7,1fr);gap:2px}
 .pop .dow{font-size:.6rem;color:var(--muted);text-align:center;padding:2px 0}
 .pop .day{text-align:center;font-size:.75rem;padding:5px 0;border-radius:6px;cursor:pointer}
 .pop .day:hover{background:#262c38}
 .pop .sel{background:var(--accent);color:#fff}
 .pop .inr{background:var(--accent-soft)}
 .pop .foot{display:flex;justify-content:space-between;margin-top:8px;font-size:.75rem}
 .pop .foot a{cursor:pointer;color:var(--link)}
</style></head>
<body><div class="wrap">
<h1>Flare Tracker</h1>


<div id="login" class="card hidden">
  <label>Admin password</label>
  <div class="row"><input id="pw" type="password" placeholder="password" style="max-width:280px" onkeydown="if(event.key==='Enter')connect()">
  <button onclick="connect()">Connect</button></div>
  <p id="loginErr" class="muted"></p>
</div>

<div id="panel" class="hidden">
  <div class="row" style="margin-bottom:10px;gap:14px;align-items:center">
    <a class="clink" onclick="goSection('create')">Create</a>
    <a class="clink" onclick="goSection('campaigns')">Campaigns</a>
    <a class="clink" onclick="goSection('results')">Results</a>
    <span class="right"></span><button class="sec" onclick="logout()">Log out</button>
  </div>
  <details id="create" class="card sect">
    <summary>Create tracking link</summary>
    <div class="grid" style="margin-top:12px">
      <div><label>Campaign name</label><input id="c_camp" placeholder="Summer_Promo"></div>
      <div><label>Destination URL</label><input id="c_dest" placeholder="https://example.com/landing"></div>
      <div><label>Custom token (optional)</label><input id="c_token" placeholder="auto"></div>
      <div><label>Analytics level</label><select id="c_level">
        <option value="standard">Standard (IP + location)</option>
        <option value="enhanced">Enhanced (adds screen, platform, time zone)</option></select></div>
      <div><label>Custom domain (optional)</label><select id="c_domain"><option value="">workers.dev host (default)</option></select></div>
      <div><label>Consent page <span class="info" title="Show the consent/disclosure page before redirecting (default). Choose Skip only when the visitor already consented to this tracking upstream. The tool cannot verify upstream consent.">i</span></label><select id="c_consent">
        <option value="show">Show (default)</option>
        <option value="skip">Skip - consent obtained upstream</option></select></div>
    </div>
    <div style="margin-top:16px;border-top:1px solid #232833;padding-top:14px">
      <strong>Link preview (shown when the link is shared)</strong>
      <div class="grid" style="margin-top:12px">
        <div><label>Preview title</label><input id="c_ogt" placeholder="e.g. Summer Sale"></div>
        <div><label>Preview description</label><input id="c_ogd" placeholder="Short line under the title"></div>
        <div><label>Preview image</label><select id="c_ogimg"><option value="">none</option></select><img id="c_ogimg_thumb" class="thumb" alt=""></div>
        <div><label>Or upload an image (exactly 1200x630)</label><input id="c_ogfile" type="file" accept="image/*"></div>
      </div>
      <p id="uploadMsg" class="muted"></p>
    </div>
    <div class="row" style="margin-top:12px"><button id="genBtn" onclick="createLink()">Generate link</button>
      <span id="createOut" class="muted"></span></div>
  </details>

  <details id="campaigns" class="card sect" open>
    <summary>Campaigns</summary>
    <div class="row" style="margin:8px 0"><span class="right"></span><button class="sec" onclick="loadLinks()">Refresh</button></div>
    <div style="overflow-x:auto">
      <table><thead><tr><th>Campaign</th><th>Token</th><th>Level</th><th>URL</th><th></th></tr></thead>
      <tbody id="linksBody"></tbody></table>
    </div>
  </details>

  <details id="results" class="card sect" open>
    <summary>Results</summary>
    <div class="row" style="margin:8px 0"><span class="right"></span><button id="resRefresh" class="sec" onclick="loadResults()">Refresh</button>
      <button class="danger" onclick="clearResults()">Clear all</button></div>
    <details id="filters" class="sub">
      <summary>Filters</summary>
      <div class="filters">
        <div style="position:relative"><label>Date range</label><button id="f_range" class="fieldbtn" onclick="toggleRange(event)">&#128197; Date range</button><div id="rangePop" class="pop" style="display:none"></div></div>
        <div><label>Campaign contains</label><input id="f_camp" oninput="renderResults()"></div>
        <div><label>IP is / starts with</label><input id="f_ip" placeholder="203.0.113. or full IP" oninput="renderResults()"></div>
        <div><label>Location contains</label><input id="f_loc" oninput="renderResults()"></div>
        <div><label>Details contains (comma = all)</label><input id="f_det" placeholder="e.g. MacIntel, 1680x1050" oninput="renderResults()"></div>
        <div><label>Show times in</label><select id="tzSel"></select></div>
        <div><label>&nbsp;</label><button class="sec" onclick="clearFilters()" style="width:100%">Clear filters</button></div>
      </div>
    </details>
    <div style="overflow-x:auto">
      <table><thead><tr><th>Time</th><th>Campaign</th><th>IP</th><th>Location</th><th>Details</th></tr></thead>
      <tbody id="resBody"></tbody></table>
    </div>
    <p id="resCount" class="muted"></p>
  </details>
</div>

<div id="editModal" class="modalbg" style="display:none">
  <div class="modal">
    <div class="row"><strong>Edit campaign</strong><button class="sec right" onclick="closeEdit()">Cancel</button></div>
    <div class="grid" style="margin-top:12px">
      <div><label>Campaign name</label><input id="e_camp"></div>
      <div><label>Destination URL</label><input id="e_dest"></div>
      <div><label>Token <span class="info" title="This token is the link itself (the /s/TOKEN part). Changing it would change the URL, break links already shared, and orphan this campaign's results.">i</span></label><input id="e_token" disabled></div>
      <div><label>Analytics level</label><select id="e_level">
        <option value="standard">Standard (IP + location)</option>
        <option value="enhanced">Enhanced (adds screen, platform, time zone)</option></select></div>
      <div><label>Custom domain <span class="info" title="The domain is part of the link URL. Changing it would break links already shared on the current domain.">i</span></label><input id="e_domain" disabled></div>
      <div><label>Consent page <span class="info" title="Show the consent/disclosure page before redirecting (default). Choose Skip only when the visitor already consented to this tracking upstream. The tool cannot verify upstream consent.">i</span></label><select id="e_consent">
        <option value="show">Show (default)</option>
        <option value="skip">Skip - consent obtained upstream</option></select></div>
      <div><label>Preview image</label><select id="e_ogimg"></select><img id="e_ogimg_thumb" class="thumb" alt=""></div>
      <div><label>Preview title</label><input id="e_ogt"></div>
      <div><label>Preview description</label><input id="e_ogd"></div>
      <div><label>Or upload an image (exactly 1200x630)</label><input id="e_ogfile" type="file" accept="image/*"></div>
    </div>
    <p id="editMsg" class="muted"></p>
    <div class="row" style="margin-top:12px"><button id="saveBtn" onclick="saveEdit()">Save changes</button>
      <span id="editOut" class="muted"></span></div>
  </div>
</div>

</div>
<script>
var PW="";
function val(id){return document.getElementById(id).value;}
function td(t){var c=document.createElement("td");c.textContent=(t==null?"":t);return c;}
function api(path,opts){opts=opts||{};opts.headers=opts.headers||{};if(PW)opts.headers["Authorization"]="Bearer "+PW;opts.credentials="same-origin";opts.cache="no-store";return fetch(path,opts);}
function showLogin(){ document.getElementById("login").classList.remove("hidden"); }
function showPanel(){
  document.getElementById("login").classList.add("hidden");
  document.getElementById("panel").classList.remove("hidden");
  loadDomains();loadImages();loadLinks();loadResults();
  wireUpload("c_ogfile","c_ogimg","uploadMsg");
  initSelects();
  openHash(false);
}
function scrollToEl(el){
  var go=function(){ el.scrollIntoView({behavior:"smooth",block:"start"}); };
  setTimeout(go,60);   // initial
  setTimeout(go,500);  // again after async tables load and reflow the page
}
function openHash(doRefresh){
  var h=(location.hash||"").replace("#","");
  if(!h)return;
  var el=document.getElementById(h);
  if(!el)return;
  if(doRefresh){ if(h==="results"||h==="filters")loadResults(); else if(h==="campaigns")loadLinks(); }
  // Make the linked section the only open one, then open the target's chain.
  var sects=document.querySelectorAll("details.sect");
  for(var i=0;i<sects.length;i++) sects[i].open=false;
  var p=el; while(p){ if(p.tagName==="DETAILS")p.open=true; p=p.parentNode; }
  scrollToEl(el);
}
window.addEventListener("hashchange",function(){openHash(true);});
window.addEventListener("pageshow",function(){openHash(true);});
// Jump to a section and always re-apply open/collapse + refresh, even if the
// hash is unchanged (browsers fire no hashchange for the current hash).
function goSection(id){ if(location.hash==="#"+id){ openHash(true); } else { location.hash="#"+id; } }
// On load, an existing session cookie logs you straight in; otherwise show login.
function checkSession(){
  api("/mgmt-panel/links").then(function(r){ if(r.ok) showPanel(); else showLogin(); }).catch(function(){ showLogin(); });
}
function connect(){
  PW=val("pw");
  fetch("/mgmt-panel/login",{method:"POST",headers:{"Authorization":"Bearer "+PW},credentials:"same-origin"}).then(function(r){
    if(!r.ok)throw new Error(r.status===401?"Wrong password.":(r.status===404?"Admin is not available here.":("HTTP "+r.status)));
    document.getElementById("loginErr").textContent="";
    showPanel();
  }).catch(function(e){document.getElementById("loginErr").textContent=e.message;});
}
function logout(){
  fetch("/mgmt-panel/logout",{method:"POST",credentials:"same-origin"}).then(function(){
    PW="";location.reload();
  }).catch(function(){location.reload();});
}
function ensureOption(sel,val,label){ if(!val)return; for(var i=0;i<sel.options.length;i++){if(sel.options[i].value===val)return;} var o=document.createElement("option");o.value=val;o.textContent=label;sel.appendChild(o); }
// ---- custom dropdowns (fully themed, replace native <select> chrome) --------
function enhanceSelect(sel){
  if(sel._nx)return; sel._nx=true;
  sel.classList.add("nxsel-native");
  var wrap=document.createElement("div");wrap.className="nxwrap";
  sel.parentNode.insertBefore(wrap,sel);wrap.appendChild(sel);
  var btn=document.createElement("button");btn.type="button";btn.className="nxbtn";
  var list=document.createElement("div");list.className="nxlist";
  wrap.appendChild(btn);wrap.appendChild(list);
  sel._nxbtn=btn;sel._nxlist=list;
  if(sel.id==="c_ogimg")sel._prevImg="c_ogimg_thumb";
  if(sel.id==="e_ogimg")sel._prevImg="e_ogimg_thumb";
  btn.onclick=function(e){e.stopPropagation();var open=list.classList.contains("open");closeAllNx();if(!open){buildNxList(sel);list.classList.add("open");var s=list.querySelector(".nxsearch");if(s)s.focus();}};
  nxSync(sel);
}
function buildNxList(sel){
  var list=sel._nxlist;list.innerHTML="";
  var isImg=(sel.id==="c_ogimg"||sel.id==="e_ogimg");
  var search=null;
  if(sel.options.length>8||isImg){
    search=document.createElement("input");search.className="nxsearch";search.placeholder="Search\u2026";
    search.onclick=function(e){e.stopPropagation();};
    search.oninput=function(){renderNxOpts(sel,search.value.toLowerCase());};
    list.appendChild(search);
  }
  var body=document.createElement("div");body.className="nxbody";list.appendChild(body);
  renderNxOpts(sel,"");
}
function renderNxOpts(sel,q){
  var list=sel._nxlist;var body=list.querySelector(".nxbody");if(!body)return;body.innerHTML="";
  var isImg=(sel.id==="c_ogimg"||sel.id==="e_ogimg");
  for(var i=0;i<sel.options.length;i++){(function(opt){
    if(q && (opt.textContent||"").toLowerCase().indexOf(q)<0) return;
    var o=document.createElement("div");o.className="nxopt"+(opt.selected?" sel":"");
    if(isImg && opt.value){var im=document.createElement("img");im.src=opt.value;im.alt="";o.appendChild(im);}
    var lbl=document.createElement("span");lbl.className="lbl";lbl.textContent=opt.textContent;o.appendChild(lbl);
    o.onclick=function(e){e.stopPropagation();sel.value=opt.value;list.classList.remove("open");nxSync(sel);try{sel.dispatchEvent(new Event("change"));}catch(_){}};
    if(isImg && opt.value){
      var del=document.createElement("button");del.className="del";del.textContent="\u2715";del.title="Delete image";
      del.onclick=function(e){e.stopPropagation();deleteImage(opt.value,opt.textContent);};
      o.appendChild(del);
    }
    body.appendChild(o);
  })(sel.options[i]);}
}
function nxSync(sel){ if(!sel._nxbtn)return; var o=sel.options[sel.selectedIndex]; sel._nxbtn.textContent=o?(o.textContent||"\u00a0"):"\u00a0"; if(sel._prevImg)updateThumb(sel); }
function closeAllNx(){var ls=document.querySelectorAll(".nxlist.open");for(var i=0;i<ls.length;i++)ls[i].classList.remove("open");}
document.addEventListener("click",closeAllNx);
function initSelects(){ var ss=document.querySelectorAll("select"); for(var i=0;i<ss.length;i++) enhanceSelect(ss[i]); }
function updateThumb(sel){
  var t=document.getElementById(sel._prevImg); if(!t)return;
  var v=sel.value; if(v){t.src=v;t.style.display="block";} else {t.removeAttribute("src");t.style.display="none";}
}
function deleteImage(url,key){
  if(!confirm("Delete image "+key+"? Links using it will lose their preview image."))return;
  api("/mgmt-panel/images/"+encodeURIComponent(key),{method:"DELETE"}).then(function(){
    ["c_ogimg","e_ogimg"].forEach(function(id){var s=document.getElementById(id);if(s){fillImageSelect(s,(s.value===url?"":s.value));}});
  });
}
function fillDomainSelect(sel,selected){
  return api("/mgmt-panel/domains").then(function(r){return r.json();}).then(function(d){
    sel.innerHTML="";
    var def=document.createElement("option");def.value="";def.textContent="workers.dev host (default)";sel.appendChild(def);
    (d.domains||[]).forEach(function(x){var o=document.createElement("option");o.value=x.hostname;o.textContent=x.hostname+(x.attached?"":" (not attached yet)");sel.appendChild(o);});
    if(selected!=null){ ensureOption(sel,selected,selected); sel.value=selected; }
    nxSync(sel);
  }).catch(function(){});
}
function fillImageSelect(sel,selected){
  return api("/mgmt-panel/images").then(function(r){return r.json();}).then(function(d){
    sel.innerHTML="";
    var none=document.createElement("option");none.value="";none.textContent="none";sel.appendChild(none);
    (d.images||[]).forEach(function(x){var o=document.createElement("option");o.value=x.url;o.textContent=x.key;sel.appendChild(o);});
    if(selected!=null){ ensureOption(sel,selected,(""+selected).split("/").pop()); sel.value=selected; }
    nxSync(sel);
  }).catch(function(){});
}
function loadDomains(){ var s=document.getElementById("c_domain"); return fillDomainSelect(s, s.value||""); }
function loadImages(){ var s=document.getElementById("c_ogimg"); return fillImageSelect(s, s.value||""); }
function uploadFile(file,selectId,msgId){
  var msg=document.getElementById(msgId);msg.textContent="Checking image...";
  var url=URL.createObjectURL(file);var img=new Image();
  img.onload=function(){
    URL.revokeObjectURL(url);
    if(img.naturalWidth!==1200||img.naturalHeight!==630){msg.textContent="Image must be exactly 1200x630 px. This one is "+img.naturalWidth+"x"+img.naturalHeight+".";return;}
    var key=file.name.replace(/[^A-Za-z0-9._-]/g,"_");msg.textContent="Uploading...";
    api("/mgmt-panel/upload?key="+encodeURIComponent(key),{method:"POST",headers:{"Content-Type":file.type},body:file})
      .then(function(r){return r.json();})
      .then(function(d){ if(d.success){msg.textContent="Uploaded "+d.key;var sel=document.getElementById(selectId);if(sel){ensureOption(sel,d.url,d.key);sel.value=d.url;nxSync(sel);}} else {msg.textContent=d.error||"Upload failed";} })
      .catch(function(e){msg.textContent=e.message;});
  };
  img.onerror=function(){URL.revokeObjectURL(url);msg.textContent="That file is not a readable image.";};
  img.src=url;
}
function wireUpload(fileId,selectId,msgId){
  var f=document.getElementById(fileId);
  if(f && !f._wired){ f.addEventListener("change",function(e){var file=e.target.files&&e.target.files[0];if(file)uploadFile(file,selectId,msgId);e.target.value="";}); f._wired=true; }
}
var EDIT_TOKEN="";
function openEdit(l){
  EDIT_TOKEN=l.token;
  document.getElementById("e_camp").value=l.campaign||"";
  document.getElementById("e_dest").value=l.redirect_to||"";
  document.getElementById("e_token").value=l.token||"";
  document.getElementById("e_level").value=l.analytics_level||"standard";
  document.getElementById("e_consent").value=l.skip_consent?"skip":"show";
  nxSync(document.getElementById("e_level"));nxSync(document.getElementById("e_consent"));
  document.getElementById("e_ogt").value=l.og_title||"";
  document.getElementById("e_ogd").value=l.og_description||"";
  document.getElementById("editMsg").textContent="";document.getElementById("editOut").textContent="";
  document.getElementById("e_domain").value=l.custom_domain||"workers.dev host (default)";
  fillImageSelect(document.getElementById("e_ogimg"), l.og_image||"");
  wireUpload("e_ogfile","e_ogimg","editMsg");
  document.getElementById("editModal").style.display="flex";
}
function closeEdit(){ document.getElementById("editModal").style.display="none"; }
function saveEdit(){
  var out=document.getElementById("editOut");var btn=document.getElementById("saveBtn");
  if(btn && btn.disabled) return;
  var body={campaign:val("e_camp"),redirect_to:val("e_dest"),analytics_level:val("e_level"),
    skip_consent:(val("e_consent")==="skip"),
    og_title:val("e_ogt"),og_description:val("e_ogd"),og_image:val("e_ogimg")};
  var dst=body.redirect_to||"";
  if(dst.slice(0,7)!=="http://"&&dst.slice(0,8)!=="https://"){out.textContent="Destination must start with http:// or https://";return;}
  if(btn){btn.disabled=true;btn.textContent="Saving...";}
  api("/mgmt-panel/links/"+encodeURIComponent(EDIT_TOKEN),{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)})
    .then(function(r){return r.json();})
    .then(function(d){ if(d.success){ closeEdit(); loadLinks(); loadResults(); } else { out.textContent=d.error||"Save failed"; } })
    .catch(function(e){out.textContent=e.message;})
    .then(function(){ if(btn){btn.disabled=false;btn.textContent="Save changes";} });
}
function clearCreateForm(){
  ["c_camp","c_dest","c_token","c_ogt","c_ogd"].forEach(function(id){var e=document.getElementById(id);if(e)e.value="";});
  var s;
  s=document.getElementById("c_level"); if(s)s.value="standard";
  s=document.getElementById("c_consent"); if(s)s.value="show";
  s=document.getElementById("c_domain"); if(s)s.value="";
  s=document.getElementById("c_ogimg"); if(s)s.value="";
  ["c_level","c_consent","c_domain","c_ogimg"].forEach(function(id){var e=document.getElementById(id);if(e)nxSync(e);});
  var f=document.getElementById("c_ogfile"); if(f)f.value="";
  var m=document.getElementById("uploadMsg"); if(m)m.textContent="";
}
function linkRow(l){
  var dom=l.custom_domain||location.host;var url="https://"+dom+"/s/"+l.token;
  var tr=document.createElement("tr");
  var cc=document.createElement("td");var cl=document.createElement("span");cl.className="clink";cl.textContent=l.campaign||"(unnamed)";
  cl.onclick=(function(link){return function(){openEdit(link);};})(l);cc.appendChild(cl);tr.appendChild(cc);
  tr.appendChild(td(l.token));
  tr.appendChild(td(l.analytics_level||"standard"));
  var uc=document.createElement("td");var a=document.createElement("a");a.href=url;a.textContent=url;a.target="_blank";a.rel="noopener";uc.appendChild(a);tr.appendChild(uc);
  var dc=document.createElement("td");
  var acts=document.createElement("div");acts.className="actbtns";
  var eb=document.createElement("button");eb.className="sec";eb.textContent="Edit";
  eb.onclick=(function(link){return function(){openEdit(link);};})(l);acts.appendChild(eb);
  var b=document.createElement("button");b.className="danger";b.textContent="Delete";
  b.onclick=(function(t){return function(){if(confirm("Delete "+t+"?"))api("/mgmt-panel/links/"+encodeURIComponent(t),{method:"DELETE"}).then(loadLinks);};})(l.token);
  acts.appendChild(b);dc.appendChild(acts);tr.appendChild(dc);
  return tr;
}
function addLinkRow(l){
  var tb=document.getElementById("linksBody");
  if(tb.rows.length===1 && tb.rows[0].cells.length===1) tb.innerHTML="";
  tb.insertBefore(linkRow(l), tb.firstChild);
}
function createLink(){
  var out=document.getElementById("createOut");
  var btn=document.getElementById("genBtn");
  if(btn && btn.disabled) return;               // guard against double submit
  var body={campaign:val("c_camp"),redirect_to:val("c_dest"),token:val("c_token"),
    analytics_level:val("c_level"),custom_domain:val("c_domain"),
    skip_consent:(val("c_consent")==="skip"),
    og_title:val("c_ogt"),og_description:val("c_ogd"),og_image:val("c_ogimg")};
  var dst=body.redirect_to||"";
  if(dst.slice(0,7)!=="http://"&&dst.slice(0,8)!=="https://"){out.textContent="Destination must start with http:// or https://";return;}
  if(btn){btn.disabled=true;btn.textContent="Generating...";}
  api("/mgmt-panel/create",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)})
   .then(function(r){return r.json();})
   .then(function(d){
     if(d.success){
       out.textContent="Created: "+d.campaign_url;
       addLinkRow(d.link);            // show immediately (KV list is eventually consistent)
       clearCreateForm();
       setTimeout(loadLinks,1500);    // reconcile once the list catches up
     } else { out.textContent=d.error||"Error creating link"; }
   })
   .catch(function(e){out.textContent=e.message;})
   .then(function(){ if(btn){btn.disabled=false;btn.textContent="Generate link";} });
}
function loadLinks(){
  api("/mgmt-panel/links").then(function(r){return r.json();}).then(function(d){
    var tb=document.getElementById("linksBody");tb.innerHTML="";
    var links=d.links||[];
    if(!links.length){var tr=tb.insertRow();var c=tr.insertCell();c.colSpan=5;c.className="muted";c.textContent="No campaigns.";return;}
    links.forEach(function(l){ tb.appendChild(linkRow(l)); });
  });
}
var ALL_RESULTS=[];
var NEW_KEYS=new Set();
function seenGet(){ try{ return new Set(JSON.parse(localStorage.getItem("nx_seen")||"[]")); }catch(_){ return new Set(); } }
function seenSet(keys){ try{ localStorage.setItem("nx_seen", JSON.stringify(Array.prototype.slice.call(keys))); }catch(_){} }
function getTz(){ try{ return localStorage.getItem("nx_tz") || Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC"; }catch(_){ return "UTC"; } }
function initTz(){
  var sel=document.getElementById("tzSel"); if(!sel||sel._init)return; sel._init=true;
  var zones=[]; try{ zones=Intl.supportedValuesOf("timeZone"); }catch(_){}
  if(!zones||!zones.length) zones=["UTC","America/Los_Angeles","America/Denver","America/Chicago","America/New_York","America/Sao_Paulo","Europe/London","Europe/Paris","Europe/Moscow","Asia/Dubai","Asia/Kolkata","Asia/Singapore","Asia/Tokyo","Australia/Sydney"];
  if(zones.indexOf("UTC")<0) zones.unshift("UTC");
  zones.forEach(function(z){var o=document.createElement("option");o.value=z;o.textContent=z;sel.appendChild(o);});
  sel.value=getTz();
  sel.addEventListener("change",function(){ try{localStorage.setItem("nx_tz",sel.value);}catch(_){} renderResults(); });
  nxSync(sel);
}
function fmtTime(iso,tz){ try{ return new Date(iso).toLocaleString("en-CA",{timeZone:tz,hour12:false}); }catch(_){ return iso||""; } }
function locOf(r){ return [(r.city||""),(r.country||""),(r.isp||"")].filter(Boolean).join(" "); }
function detailsOf(r){
  var p=[]; if(r.asn!==""&&r.asn!=null)p.push("AS"+r.asn);
  var fp=r.client_fingerprint||{};
  if(fp.screen_resolution)p.push(fp.screen_resolution);
  if(fp.platform)p.push(fp.platform);
  if(fp.timezone)p.push(fp.timezone);
  if(r.user_agent)p.push(r.user_agent);
  return p.join(", ");
}
function renderResults(){
  var tz=getTz();
  var from=RANGE_FROM||"";
  var to=RANGE_TO||"";
  var fcamp=((document.getElementById("f_camp")||{}).value||"").toLowerCase();
  var fip=((document.getElementById("f_ip")||{}).value||"").trim();
  var floc=((document.getElementById("f_loc")||{}).value||"").toLowerCase();
  var fdetTerms=((document.getElementById("f_det")||{}).value||"").toLowerCase().split(",").map(function(s){return s.trim();}).filter(Boolean);
  var fromT=from?new Date(from+"T00:00:00").getTime():null;
  var toT=to?new Date(to+"T23:59:59.999").getTime():null;
  var rows=ALL_RESULTS.filter(function(r){
    var t=new Date(r.timestamp||0).getTime();
    if(fromT!==null&&t<fromT)return false;
    if(toT!==null&&t>toT)return false;
    if(fcamp&&(""+(r.campaign||r.token||"")).toLowerCase().indexOf(fcamp)<0)return false;
    if(fip){ var ip=r.ip||""; if(ip!==fip&&ip.indexOf(fip)!==0)return false; }
    if(floc && locOf(r).toLowerCase().indexOf(floc)<0)return false;
    if(fdetTerms.length){ var dd=detailsOf(r).toLowerCase(); for(var _i=0;_i<fdetTerms.length;_i++){ if(dd.indexOf(fdetTerms[_i])<0) return false; } }
    return true;
  });
  rows.sort(function(a,b){return (b.timestamp||"").localeCompare(a.timestamp||"");});
  var tb=document.getElementById("resBody");tb.innerHTML="";
  if(!rows.length){var tr=tb.insertRow();var c=tr.insertCell();c.colSpan=5;c.className="muted";c.textContent="No records.";document.getElementById("resCount").textContent="";return;}
  var newShown=0;
  rows.forEach(function(r){
    var tr=tb.insertRow();
    if(r._kv_key && NEW_KEYS.has(r._kv_key)){ tr.className="newrow"; newShown++; }
    tr.appendChild(td(fmtTime(r.timestamp,tz)));
    tr.appendChild(td(r.campaign||r.token||""));
    tr.appendChild(td(r.ip||""));
    tr.appendChild(td(locOf(r)||"?"));
    tr.appendChild(td(detailsOf(r)||"standard"));
  });
  var msg=rows.length+" of "+ALL_RESULTS.length+" shown - times in "+tz;
  if(newShown>0) msg+=" - "+newShown+" new since last view";
  document.getElementById("resCount").textContent=msg;
}
var RANGE_FROM="",RANGE_TO="",_vy,_vm,_selS,_selE;
function pad2(n){return (n<10?"0":"")+n;}
function ymd(y,m,d){return y+"-"+pad2(m+1)+"-"+pad2(d);}
function toggleRange(ev){
  ev.stopPropagation();
  var p=document.getElementById("rangePop");
  if(p.style.display==="none"){ var b=RANGE_FROM?new Date(RANGE_FROM):new Date(); _vy=b.getFullYear(); _vm=b.getMonth(); _selS=RANGE_FROM; _selE=RANGE_TO; buildCal(); p.style.display="block"; }
  else { p.style.display="none"; }
}
function moveMonth(delta){ _vm+=delta; if(_vm<0){_vm=11;_vy--;} if(_vm>11){_vm=0;_vy++;} buildCal(); }
function buildCal(){
  var p=document.getElementById("rangePop");p.innerHTML="";
  var names=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  var cd=document.createElement("div");cd.className="cd";
  var prev=document.createElement("button");prev.type="button";prev.textContent="\u2039";prev.onclick=function(e){e.stopPropagation();moveMonth(-1);};
  var lbl=document.createElement("span");lbl.textContent=names[_vm]+" "+_vy;
  var nxt=document.createElement("button");nxt.type="button";nxt.textContent="\u203a";nxt.onclick=function(e){e.stopPropagation();moveMonth(1);};
  cd.appendChild(prev);cd.appendChild(lbl);cd.appendChild(nxt);p.appendChild(cd);
  var g=document.createElement("div");g.className="grid7";
  ["S","M","T","W","T","F","S"].forEach(function(d){var e=document.createElement("div");e.className="dow";e.textContent=d;g.appendChild(e);});
  var first=new Date(_vy,_vm,1).getDay();
  var dim=new Date(_vy,_vm+1,0).getDate();
  for(var i=0;i<first;i++){g.appendChild(document.createElement("div"));}
  for(var day=1;day<=dim;day++){
    (function(dnum){
      var ds=ymd(_vy,_vm,dnum);
      var c=document.createElement("div");c.className="day";c.textContent=dnum;
      if(ds===_selS||ds===_selE)c.className+=" sel";
      else if(_selS&&_selE&&ds>_selS&&ds<_selE)c.className+=" inr";
      c.onclick=function(e){e.stopPropagation();pickDay(ds);};
      g.appendChild(c);
    })(day);
  }
  p.appendChild(g);
  var foot=document.createElement("div");foot.className="foot";
  var cl=document.createElement("a");cl.textContent="Clear";cl.onclick=function(e){e.stopPropagation();clearRange();};
  var cs=document.createElement("a");cs.textContent="Close";cs.onclick=function(e){e.stopPropagation();closeRange();};
  foot.appendChild(cl);foot.appendChild(cs);p.appendChild(foot);
}
function pickDay(ds){
  if(!_selS||(_selS&&_selE)){ _selS=ds; _selE=""; }
  else { if(ds<_selS){ _selE=_selS; _selS=ds; } else { _selE=ds; } }
  buildCal();
  if(_selS&&_selE) applyRange();
}
function applyRange(){
  RANGE_FROM=_selS;RANGE_TO=_selE;
  document.getElementById("f_range").textContent="\uD83D\uDCC5 "+RANGE_FROM+" \u2192 "+RANGE_TO;
  document.getElementById("rangePop").style.display="none";
  renderResults();
}
function clearRange(){ RANGE_FROM="";RANGE_TO="";_selS="";_selE=""; var fr=document.getElementById("f_range"); if(fr)fr.textContent="\uD83D\uDCC5 Date range"; var p=document.getElementById("rangePop"); if(p&&p.style.display!=="none") buildCal(); renderResults(); }
function closeRange(){ document.getElementById("rangePop").style.display="none"; }
document.addEventListener("click",function(e){ var p=document.getElementById("rangePop"); if(p&&p.style.display!=="none"&&!p.parentNode.contains(e.target)) p.style.display="none"; });
function clearFilters(){
  ["f_camp","f_ip","f_loc","f_det"].forEach(function(id){var e=document.getElementById(id);if(e)e.value="";});
  clearRange();
}
function loadResults(){
  var rc=document.getElementById("resCount"); if(rc)rc.textContent="Checking for results\u2026";
  var rf=document.getElementById("resRefresh"); if(rf){rf.disabled=true;rf.textContent="Checking\u2026";}
  api("/mgmt-panel/results").then(function(r){return r.json();}).then(function(d){
    ALL_RESULTS=d.results||[];
    var prev=seenGet();
    var firstView=prev.size===0;
    var curKeys=[];
    NEW_KEYS=new Set();
    ALL_RESULTS.forEach(function(r){
      if(!r._kv_key)return;
      curKeys.push(r._kv_key);
      if(!firstView && !prev.has(r._kv_key)) NEW_KEYS.add(r._kv_key);
    });
    seenSet(curKeys);   // everything currently present counts as seen now
    initTz(); renderResults();
  }).catch(function(){ if(rc)rc.textContent="Could not load results. Try Refresh."; })
    .then(function(){ if(rf){rf.disabled=false;rf.textContent="Refresh";} });
}
function clearResults(){
  if(!confirm("Delete all telemetry?"))return;
  api("/mgmt-panel/clear-logs",{method:"DELETE"}).then(loadResults);
}
checkSession();
<\/script>
</body></html>`;
JS
}

get_or_create_kv() {
  local title="$1" id
  id=$(ns_id_by_title "$(req "$(acc '/storage/kv/namespaces?per_page=100')")" "$title")
  if [[ -z "$id" ]]; then
    id=$(req -X POST -H "content-type: application/json" \
      "$(acc '/storage/kv/namespaces')" --data "{\"title\":\"$title\"}" | extract_ns_id)
  fi
  [[ -n "$id" ]] && echo "$id" || return 1
}

account_subdomain() {
  local resp s
  resp=$(req "$(acc '/workers/subdomain')")
  s=$(json_str "$resp" subdomain)
  [[ "$s" == "null" ]] && s=""
  printf '%s' "$s"
}

register_subdomain() {
  local want="$1" resp
  resp=$(req -X PUT -H "content-type: application/json" \
    "$(acc '/workers/subdomain')" --data "{\"subdomain\":\"${want}\"}")
  if is_success "$resp"; then echo "$want"; return 0; fi
  local msg; msg=$(json_str "$resp" message)
  echo "__ERR__:${msg:-registration failed}"
  return 1
}

ensure_subdomain() {
  local sub; sub=$(account_subdomain)
  if [[ -n "$sub" ]]; then echo "$sub"; return 0; fi

  echo "This account has no workers.dev subdomain yet." >&2
  local want out
  while :; do
    read -r -p "Desired workers.dev subdomain (blank to skip): " want
    [[ -z "$want" ]] && { echo ""; return 0; }
    want=$(printf '%s' "$want" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')
    [[ -n "$want" ]] || continue
    out=$(register_subdomain "$want")
    if [[ "$out" == "$want" ]]; then
      echo "$want"; return 0
    fi
  done
}

do_setup() {
  require_creds || return 1
  local workername kvtitle
  if [[ $# -ge 1 ]]; then
    # Non-interactive: setup WORKER [KV_TITLE]
    workername=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')
    [[ -n "$workername" ]] || { echo "Invalid worker name."; return 1; }
    kvtitle="${2:-FT_CACHE}"
  else
    echo "Setup:"
    echo "  1) Quick setup   (worker: ft-worker, KV: FT_CACHE)"
    echo "  2) Custom setup  (choose the worker and KV names)"
    local choice; read -r -p "Choose [1]: " choice
    if [[ "$choice" == "2" ]]; then
      read -r -p "Worker name [ft-worker]: " workername
      workername=$(printf '%s' "${workername:-ft-worker}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')
      [[ -n "$workername" ]] || workername="ft-worker"
      local defkv="FT_CACHE"
      read -r -p "KV namespace title [${defkv}]: " kvtitle
      kvtitle=$(printf '%s' "${kvtitle:-$defkv}" | tr -cd 'A-Za-z0-9._-')
      [[ -n "$kvtitle" ]] || kvtitle="$defkv"
    else
      workername="ft-worker"; kvtitle="FT_CACHE"
    fi
  fi
  echo "Worker name : ${workername}"
  echo "KV title    : ${kvtitle}"
  local ns_id
  ns_id=$(get_or_create_kv "$kvtitle") || { echo "Could not create the KV namespace."; return 1; }

  # Admin password: keep an existing one, else prompt or generate. The worker
  # reads this from KV at request time, so it can be rotated with 'admin pwd'
  # without a redeploy.
  local code pwd
  code=$(curl -sS "${AUTH[@]}" \
    "$(acc "/storage/kv/namespaces/${ns_id}/values/pwd")" -o /dev/null -w '%{http_code}')
  if [[ "$code" == "200" ]]; then
    echo "Admin password already set, leaving it."
  else
    read -r -s -p "Set admin password (blank to auto-generate): " pwd; echo
    if [[ -z "$pwd" ]]; then
      pwd=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
      echo "Generated admin password: ${pwd}"
    fi
    req -X PUT "$(acc "/storage/kv/namespaces/${ns_id}/values/pwd")" --data "$pwd" >/dev/null
  fi

  deploy_worker "$workername" "$ns_id" || die "Deploy failed."

  # Default admin flags (do not clobber existing values on re-run).
  [[ "$(curl -sS "${AUTH[@]}" "$(acc "/storage/kv/namespaces/${ns_id}/values/admin_enabled")" -o /dev/null -w '%{http_code}')" == "200" ]] \
    || req -X PUT "$(acc "/storage/kv/namespaces/${ns_id}/values/admin_enabled")" --data "true" >/dev/null
  [[ "$(curl -sS "${AUTH[@]}" "$(acc "/storage/kv/namespaces/${ns_id}/values/admin_ip_on")" -o /dev/null -w '%{http_code}')" == "200" ]] \
    || req -X PUT "$(acc "/storage/kv/namespaces/${ns_id}/values/admin_ip_on")" --data "false" >/dev/null

  local sub; sub=$(ensure_subdomain)
  if [[ -n "$sub" ]]; then
    ( workers_url "$workername" on ) >/dev/null 2>&1 || true
  fi

  PROJ_KV_ID="$ns_id"; PROJ_KV_TITLE="$kvtitle"
  PROJ_TRACKER="$workername"; PROJ_ADMIN="$workername"; PROJ_SUBDOMAIN="$sub"
  save_project
  echo "Done setup. Endpoint: https://${workername}.${sub}.workers.dev"
}

# ---- worker deploy (shared by setup and admin redeploy) --------------------
deploy_worker() {
  local workername="$1" ns_id="$2"
  local tmp; tmp=$(mktemp -d)
  tracker_worker_src > "${tmp}/worker.js"
  local meta="{\"main_module\":\"worker.js\",\"compatibility_date\":\"${COMPAT_DATE}\",\"bindings\":[{\"type\":\"kv_namespace\",\"name\":\"FT_CACHE\",\"namespace_id\":\"${ns_id}\"}]}"
  local resp
  resp=$(req -X PUT "$(acc "/workers/scripts/${workername}")" \
    -F "metadata=${meta};type=application/json" \
    -F "worker.js=@${tmp}/worker.js;filename=worker.js;type=application/javascript+module")
  rm -rf "$tmp"
  is_success "$resp" && { echo "Deployed ${workername}."; return 0; } || { echo "$resp" | pretty; return 1; }
}

# ---- admin management ------------------------------------------------------
# KV helpers scoped to a namespace id (separate from the user-facing kv_* cmds).
kvput() { req -X PUT "$(acc "/storage/kv/namespaces/$1/values/$2")" --data "$3" >/dev/null; }
kvget() {
  local out; out=$(curl -sS "${AUTH[@]}" "$(acc "/storage/kv/namespaces/$1/values/$2")")
  [[ "$out" == *'"success":false'* ]] && return 1
  printf '%s' "$out"
}

# Resolve the project's KV namespace id, from saved config or by title lookup.
admin_ns() {
  local id="${PROJ_KV_ID:-}"
  if [[ -z "$id" ]]; then
    local title="${PROJ_KV_TITLE:-FT_CACHE}"
    id=$(ns_id_by_title "$(req "$(acc '/storage/kv/namespaces?per_page=100')")" "$title")
  fi
  [[ -n "$id" ]] || { echo "No project found. Run 'setup' first, or 'admin use <kv_title> <worker_name>'." >&2; return 1; }
  echo "$id"
}

admin_link() {
  local name="${PROJ_ADMIN:-ft-worker}" sub="${PROJ_SUBDOMAIN:-}"
  [[ -z "$sub" ]] && sub=$(account_subdomain)
  if [[ -n "$sub" ]]; then
    echo "  Dashboard: https://${name}.${sub}.workers.dev/admin"
  else
    echo "  (no workers.dev subdomain; set one in the dashboard or via setup)"
  fi
}

admin_show() {
  local ns="$1" en ipon ips
  en=$(kvget "$ns" admin_enabled)  || en=""
  ipon=$(kvget "$ns" admin_ip_on)  || ipon=""
  ips=$(kvget "$ns" admin_ips)     || ips=""
  echo "Admin enabled : ${en:-true (default)}"
  echo "IP filter     : ${ipon:-false}"
  echo "Allowed IPs   : ${ips:-<none>}"
  admin_link
}

admin_setpwd() {
  local ns="$1"; shift || true
  local p="${1:-}"
  if [[ -z "$p" ]]; then read -r -s -p "New admin password (min 6): " p; echo; fi
  if [[ ${#p} -lt 6 ]]; then echo "Password too short (minimum 6 characters)."; return 1; fi
  kvput "$ns" pwd "$p"
  echo "Admin password updated. Use it to log in at the dashboard."
}

admin_ip() {
  local ns="$1"; shift || true
  case "${1:-}" in
    on)  kvput "$ns" admin_ip_on true; echo "IP filtering enabled."
         local ips; ips=$(kvget "$ns" admin_ips) || ips=""
         [[ -z "$ips" ]] && echo "Note: no IPs set yet, so nobody is blocked. Use 'admin ip set <csv>'." ;;
    off) kvput "$ns" admin_ip_on false; echo "IP filtering disabled." ;;
    set) shift || true
         [[ $# -ge 1 ]] || { echo "Usage: admin ip set 1.2.3.4,5.6.7.8"; return 1; }
         local csv; csv=$(printf '%s' "$*" | tr -d ' ')
         [[ -n "$csv" ]] || { echo "Usage: admin ip set 1.2.3.4,5.6.7.8"; return 1; }
         kvput "$ns" admin_ips "$csv"; echo "Allowed IPs set: ${csv}" ;;
    clear) kvput "$ns" admin_ips ""; echo "Allowed IP list cleared." ;;
    show|"") local ipon ips; ipon=$(kvget "$ns" admin_ip_on) || ipon=""
             ips=$(kvget "$ns" admin_ips) || ips=""
             echo "IP filter   : ${ipon:-false}"
             echo "Allowed IPs : ${ips:-<none>}" ;;
    *) echo "Usage: admin ip on|off|set <csv>|clear|show"; return 1 ;;
  esac
}

admin_redeploy() {
  local ns="$1" name="${PROJ_ADMIN:-ft-worker}"
  deploy_worker "$name" "$ns"
}

admin_use() {
  [[ $# -ge 2 ]] || { echo "Usage: admin use <kv_title> <worker_name>"; return 1; }
  PROJ_KV_TITLE="$1"; PROJ_ADMIN="$2"; PROJ_TRACKER="$2"
  PROJ_KV_ID=$(ns_id_by_title "$(req "$(acc '/storage/kv/namespaces?per_page=100')")" "$PROJ_KV_TITLE")
  PROJ_SUBDOMAIN=$(account_subdomain)
  save_project
  echo "Project set: kv=${PROJ_KV_TITLE} (${PROJ_KV_ID:-unresolved}), worker=${PROJ_ADMIN}."
}

do_admin() {
  require_creds || return 1
  local cmd="${1:-}"; shift || true
  # 'use' configures the project and does not need a resolved namespace yet.
  if [[ "$cmd" == "use" ]]; then admin_use "$@"; return; fi
  local ns; ns=$(admin_ns) || return 1
  case "$cmd" in
    enable)  kvput "$ns" admin_enabled true;  echo "Admin panel enabled."; admin_link ;;
    disable) kvput "$ns" admin_enabled false; echo "Admin panel disabled. The management API now refuses all requests." ;;
    link)    admin_link ;;
    status)  admin_show "$ns" ;;
    pwd)     admin_setpwd "$ns" "$@" ;;
    ip)      admin_ip "$ns" "$@" ;;
    redeploy|update) admin_redeploy "$ns" ;;
    *) echo "admin: enable | disable | link | status | pwd [NEW] | ip on|off|set <csv>|clear|show | redeploy | use <kv_title> <worker_name>"; return 1 ;;
  esac
}

# ---- campaigns / links -----------------------------------------------------
# These read and write the same KV keys the worker uses (link:<token> and
# result:<token>:<ts>) directly through the API, so they do not depend on the
# management panel being reachable or the password being in sync.

endpoint_host() {
  local worker="${PROJ_ADMIN:-ft-worker}" sub="${PROJ_SUBDOMAIN:-}"
  [[ -z "$sub" ]] && sub=$(account_subdomain)
  printf '%s.%s.workers.dev' "$worker" "$sub"
}

# Echo the KV key names matching a prefix, one per line.
kv_names_with_prefix() {
  local ns="$1" prefix="$2" resp
  resp=$(req "$(acc "/storage/kv/namespaces/${ns}/keys?prefix=${prefix}&limit=1000")")
  is_success "$resp" || { echo "$resp" | pretty >&2; return 1; }
  printf '%s' "$resp" \
    | grep -oE "\"name\"[[:space:]]*:[[:space:]]*\"${prefix}[^\"]*\"" \
    | sed -E "s/.*\"(${prefix}[^\"]*)\".*/\1/" || true
}

link_create() {
  local ns; ns=$(admin_ns) || return 1
  local dest="${1:-}" campaign="${2:-}" token level domain ans
  [[ -n "$dest" ]] || read -r -p "Destination URL: " dest
  case "$dest" in
    http://*|https://*) ;;
    *) echo "Destination must start with http:// or https://."; return 1 ;;
  esac
  [[ -n "$campaign" ]] || read -r -p "Campaign name (optional): " campaign
  read -r -p "Custom token (blank to auto-generate): " token
  token=$(printf '%s' "$token" | tr -cd 'A-Za-z0-9_-')
  [[ -n "$token" ]] || token=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 8)
  read -r -p "Enhanced analytics (screen/platform via the consent page)? [y/N]: " ans
  case "$ans" in y|Y|yes|YES) level="enhanced" ;; *) level="standard" ;; esac
  local skip="false"
  read -r -p "Skip the consent page? Only if visitors already consented upstream [y/N]: " ans
  case "$ans" in y|Y|yes|YES) skip="true" ;; *) skip="false" ;; esac

  # Custom domain: pick from hostnames currently attached to the worker (live).
  domain=""
  local dlist; dlist=$(attached_hostnames)
  if [[ -n "$dlist" ]]; then
    echo "Custom domain:"
    local i=1 darr=() d
    while IFS= read -r d; do [[ -z "$d" ]] && continue; darr+=("$d"); printf "  %d) %s\n" "$i" "$d"; i=$((i+1)); done <<< "$dlist"
    echo "  0) workers.dev host (default)"
    local pick; read -r -p "Choose [0]: " pick
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#darr[@]} )); then domain="${darr[$((pick-1))]}"; fi
  fi

  # Link preview (Open Graph): title, description, image.
  local ogt ogd ogimg=""
  read -r -p "Preview title (blank for none): " ogt
  read -r -p "Preview description (blank for none): " ogd
  local ilist; ilist=$(image_urls "$ns")
  echo "Preview image:"
  local ii=1 iarr=() iu
  if [[ -n "$ilist" ]]; then
    while IFS= read -r iu; do [[ -z "$iu" ]] && continue; iarr+=("$iu"); printf "  %d) %s\n" "$ii" "$iu"; ii=$((ii+1)); done <<< "$ilist"
  fi
  echo "  0) none"
  echo "  or paste an external image URL (must be 1200x630)"
  local ipick; read -r -p "Choose [0]: " ipick
  if [[ "$ipick" =~ ^[0-9]+$ ]]; then
    (( ipick >= 1 && ipick <= ${#iarr[@]} )) && ogimg="${iarr[$((ipick-1))]}"
  elif [[ "$ipick" == http*://* ]]; then
    ogimg="$ipick"
  fi

  local host cfg resp dom
  host=$(endpoint_host)
  cfg=$(CAMP="$campaign" DEST="$dest" TOKEN="$token" LEVEL="$level" DOMAIN="$domain" SKIP="$skip" OGT="$ogt" OGD="$ogd" OGIMG="$ogimg" python3 - <<'PY'
import json, os, datetime
print(json.dumps({
  "token": os.environ["TOKEN"],
  "campaign": os.environ["CAMP"],
  "redirect_to": os.environ["DEST"],
  "custom_domain": os.environ["DOMAIN"],
  "analytics_level": os.environ["LEVEL"],
  "skip_consent": os.environ["SKIP"] == "true",
  "og_title": os.environ["OGT"],
  "og_description": os.environ["OGD"],
  "og_image": os.environ["OGIMG"],
  "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
}))
PY
)
  resp=$(req -X PUT "$(acc "/storage/kv/namespaces/${ns}/values/link:${token}")" --data "$cfg")
  is_success "$resp" || { echo "$resp" | pretty; echo "Could not create the link."; return 1; }
  dom="${domain:-$host}"
  echo "Created."
  echo "  Campaign : ${campaign:-(unnamed)}"
  echo "  Token    : ${token}"
  echo "  Level    : ${level}"
  echo "  Consent  : $([[ "$skip" == "true" ]] && echo "skipped (obtained upstream)" || echo "shown")"
  echo "  URL      : https://${dom}/s/${token}"
}

link_list() {
  local ns; ns=$(admin_ns) || return 1
  local names; names=$(kv_names_with_prefix "$ns" "link:") || return 1
  [[ -n "$names" ]] || { echo "No campaigns found."; return 0; }
  local tmp k; tmp=$(mktemp)
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    req "$(acc "/storage/kv/namespaces/${ns}/values/${k}")"; echo
  done <<< "$names" > "$tmp"
  HOST="$(endpoint_host)" python3 - "$tmp" <<'PY'
import json, os, sys
host = os.environ.get("HOST", "")
rows = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    token = d.get("token", "")
    camp = d.get("campaign", "") or "(unnamed)"
    lvl = d.get("analytics_level", "standard")
    dom = d.get("custom_domain", "") or host
    url = "https://%s/s/%s" % (dom, token)
    rows.append((camp, token, lvl, url, d.get("redirect_to", "")))
if not rows:
    print("No campaigns found."); sys.exit(0)
rows.sort(key=lambda r: r[0].lower())
hdr = ("CAMPAIGN", "TOKEN", "LEVEL", "CAMPAIGN URL", "DESTINATION")
cols = list(zip(*([hdr] + rows)))
w = [max(len(str(x)) for x in c) for c in cols]
def fmt(r): return "  ".join(str(r[i]).ljust(w[i]) for i in range(len(r)))
print(fmt(hdr)); print(fmt(tuple("-" * w[i] for i in range(len(hdr)))))
for r in rows: print(fmt(r))
print(); print("%d campaign(s)." % len(rows))
PY
  rm -f "$tmp"
}

link_get() {
  local ns; ns=$(admin_ns) || return 1
  [[ $# -ge 1 ]] || { echo "Usage: link get <token>"; return 1; }
  local v; v=$(req "$(acc "/storage/kv/namespaces/${ns}/values/link:$1")")
  printf '%s' "$v" | grep -q '"success"[[:space:]]*:[[:space:]]*false' && { echo "No link with token '$1'."; return 1; }
  printf '%s' "$v" | pretty; echo
  link_url "$1"
}

link_url() {
  local ns; ns=$(admin_ns) || return 1
  [[ $# -ge 1 ]] || { echo "Usage: link url <token>"; return 1; }
  local v; v=$(req "$(acc "/storage/kv/namespaces/${ns}/values/link:$1")")
  printf '%s' "$v" | grep -q '"success"[[:space:]]*:[[:space:]]*false' && { echo "No link with token '$1'."; return 1; }
  local dom; dom=$(json_str "$v" custom_domain)
  [[ -z "$dom" ]] && dom=$(endpoint_host)
  echo "https://${dom}/s/$1"
}

link_delete() {
  local ns; ns=$(admin_ns) || return 1
  [[ $# -ge 1 ]] || { echo "Usage: link delete <token>"; return 1; }
  req -X DELETE "$(acc "/storage/kv/namespaces/${ns}/values/link:$1")" | pretty
}

# ---- results / telemetry ---------------------------------------------------
results_view() {
  local ns; ns=$(admin_ns) || return 1
  local tok="${1:-}" prefix="result:"
  [[ -n "$tok" ]] && prefix="result:${tok}:"
  local names; names=$(kv_names_with_prefix "$ns" "$prefix") || return 1
  [[ -n "$names" ]] || { echo "No telemetry records${tok:+ for token $tok}."; return 0; }
  local tmp k; tmp=$(mktemp)
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    req "$(acc "/storage/kv/namespaces/${ns}/values/${k}")"; echo
  done <<< "$names" > "$tmp"
  python3 - "$tmp" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    ts = d.get("timestamp", "")
    camp = d.get("campaign", "") or d.get("token", "")
    ip = d.get("ip", "")
    loc = "%s, %s" % (d.get("city", "?"), d.get("country", "?"))
    if d.get("isp"): loc += " - " + str(d.get("isp"))
    fp = d.get("client_fingerprint")
    parts = []
    if d.get("asn") not in ("", None): parts.append("AS" + str(d.get("asn")))
    if fp: parts.append(json.dumps(fp))
    if d.get("user_agent"): parts.append(str(d.get("user_agent")))
    det = " | ".join(parts) if parts else "standard"
    rows.append((ts, camp, ip, loc, det))
if not rows:
    print("No telemetry records."); sys.exit(0)
rows.sort(reverse=True)
hdr = ("TIME (UTC)", "CAMPAIGN", "IP", "LOCATION", "DETAILS")
cols = list(zip(*([hdr] + rows)))
w = [max(len(str(x)) for x in c) for c in cols]
def fmt(r): return "  ".join(str(r[i]).ljust(w[i]) for i in range(len(r)))
print(fmt(hdr)); print(fmt(tuple("-" * w[i] for i in range(len(hdr)))))
for r in rows: print(fmt(r))
print(); print("%d record(s)." % len(rows))
PY
  rm -f "$tmp"
}

results_clear() {
  local ns; ns=$(admin_ns) || return 1
  local tok="${1:-}" prefix="result:"
  [[ -n "$tok" ]] && prefix="result:${tok}:"
  local names; names=$(kv_names_with_prefix "$ns" "$prefix") || return 1
  [[ -n "$names" ]] || { echo "Nothing to clear."; return 0; }
  local scope="all campaigns"; [[ -n "$tok" ]] && scope="token $tok"
  local ans; read -r -p "Delete telemetry for ${scope}? [y/N]: " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "Cancelled."; return 0 ;; esac
  local n=0 k
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    req -X DELETE "$(acc "/storage/kv/namespaces/${ns}/values/${k}")" >/dev/null && n=$((n+1))
  done <<< "$names"
  echo "Deleted ${n} record(s)."
}

# ---- preview images (KV-backed; must be exactly 1200x630) -------------------
# Open Graph preview images live in KV under img:<key> and are served at /img/<key>.
IMG_W=1200
IMG_H=630

# Print "WIDTH HEIGHT CONTENT_TYPE" for an image file, or fail. No deps beyond python3.
image_probe() {
  F="$1" python3 - <<'PY'
import os, struct, sys
p = os.environ["F"]
d = open(p, "rb").read(64)
w = h = None; ct = None
if d[:8] == b"\x89PNG\r\n\x1a\n":
    w, h = struct.unpack(">II", d[16:24]); ct = "image/png"
elif d[:6] in (b"GIF87a", b"GIF89a"):
    w, h = struct.unpack("<HH", d[6:10]); ct = "image/gif"
elif d[:2] == b"\xff\xd8":
    with open(p, "rb") as f:
        f.read(2)
        while True:
            b = f.read(1)
            if not b: break
            if b != b"\xff": continue
            m = f.read(1)
            while m == b"\xff": m = f.read(1)
            if not m: break
            mv = m[0]
            if 0xC0 <= mv <= 0xCF and mv not in (0xC4, 0xC8, 0xCC):
                f.read(3); hh, ww = struct.unpack(">HH", f.read(4)); w, h = ww, hh; ct = "image/jpeg"; break
            ln = struct.unpack(">H", f.read(2))[0]
            f.seek(ln - 2, 1)
elif d[:4] == b"RIFF" and d[8:12] == b"WEBP":
    fmt = d[12:16]
    if fmt == b"VP8 ":
        w = struct.unpack("<H", d[26:28])[0] & 0x3fff; h = struct.unpack("<H", d[28:30])[0] & 0x3fff; ct = "image/webp"
    elif fmt == b"VP8X":
        w = 1 + (d[24] | d[25] << 8 | d[26] << 16); h = 1 + (d[27] | d[28] << 8 | d[29] << 16); ct = "image/webp"
if w is None or ct is None:
    sys.stderr.write("Unrecognized image (use PNG, JPEG, GIF, or WEBP).\n"); sys.exit(1)
print(w, h, ct)
PY
}

image_urls() {   # ns -> one image URL per line
  local ns="$1" host; host=$(endpoint_host)
  kv_names_with_prefix "$ns" "img:" | while IFS= read -r k; do [[ -z "$k" ]] && continue; echo "https://${host}/img/${k#img:}"; done
}

image_add() {
  local ns; ns=$(admin_ns) || return 1
  local file="$1"
  [[ -n "$file" ]] || { echo "Usage: image add <file>  (must be exactly ${IMG_W}x${IMG_H} px)"; return 1; }
  [[ -f "$file" ]] || { echo "File not found: ${file}"; return 1; }
  local probe w h ct
  probe=$(image_probe "$file") || return 1
  read -r w h ct <<< "$probe"
  if [[ "$w" != "$IMG_W" || "$h" != "$IMG_H" ]]; then
    echo "Image must be exactly ${IMG_W}x${IMG_H} px. This one is ${w}x${h}."; return 1
  fi
  local key; key=$(basename "$file" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9._-')
  [[ -n "$key" ]] || { echo "Could not derive a key from the filename."; return 1; }
  local resp
  resp=$(req -X PUT "$(acc "/storage/kv/namespaces/${ns}/values/img:${key}")" \
    -F "value=@${file};type=${ct}" -F "metadata={\"ct\":\"${ct}\"}")
  is_success "$resp" || { echo "$resp" | pretty; echo "Upload failed."; return 1; }
  echo "Uploaded ${key} (${w}x${h})."
  echo "  URL: https://$(endpoint_host)/img/${key}"
}

image_list() {
  local ns; ns=$(admin_ns) || return 1
  local names; names=$(kv_names_with_prefix "$ns" "img:") || return 1
  [[ -n "$names" ]] || { echo "No images uploaded. Add one with:  image add <file>"; return 0; }
  local host; host=$(endpoint_host)
  local k; while IFS= read -r k; do [[ -z "$k" ]] && continue; printf '  %-24s https://%s/img/%s\n' "${k#img:}" "$host" "${k#img:}"; done <<< "$names"
}

image_remove() {
  local ns; ns=$(admin_ns) || return 1
  [[ $# -ge 1 ]] || { echo "Usage: image remove <key>"; return 1; }
  req -X DELETE "$(acc "/storage/kv/namespaces/${ns}/values/img:$1")" | pretty
}

do_image() {
  require_creds || return 1
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    add)       image_add "$@" ;;
    list)      image_list ;;
    remove|rm) image_remove "$@" ;;
    *) echo "image: add <file> | list | remove <key>   (images must be exactly ${IMG_W}x${IMG_H} px)"; return 1 ;;
  esac
}

# ---- custom domains (menu-driven; Cloudflare is the source of truth) --------
# Zones and attached hostnames are read live from Cloudflare. The worker has no
# API credentials, so the panel dropdown reads a KV mirror that the CLI refreshes
# from the live attached list on every change (config:domains). Nothing here is a
# hand-maintained list.

cf_zones() {   # -> lines "zone_id<TAB>name<TAB>status"
  req "$API/zones?per_page=50&account.id=${CF_ACCOUNT_ID}" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
for z in (d.get("result") or []):
    print("\t".join([z.get("id",""),z.get("name",""),z.get("status","")]))
'
}

cf_zone_ns() {   # zone_id -> nameservers, one per line
  req "$API/zones/$1" | python3 -c '
import json,sys
for n in ((json.load(sys.stdin).get("result") or {}).get("name_servers") or []): print(n)
'
}

cf_worker_domains() {   # -> lines "domain_id<TAB>hostname<TAB>zone_id" for our worker
  req "$(acc '/workers/domains')" | SVC="${PROJ_ADMIN:-ft-worker}" python3 -c '
import json,sys,os
svc=os.environ["SVC"]
try: d=json.load(sys.stdin)
except Exception: d={}
for x in (d.get("result") or []):
    if x.get("service")==svc:
        print("\t".join([x.get("id",""),x.get("hostname",""),x.get("zone_id","")]))
'
}

attached_hostnames() { cf_worker_domains | cut -f2; }

worker_domain_attach() {   # hostname zone_id zone_name -> domain_id
  local resp
  resp=$(req -X PUT -H "content-type: application/json" "$(acc '/workers/domains')" \
    --data "{\"hostname\":\"$1\",\"service\":\"${PROJ_ADMIN:-ft-worker}\",\"environment\":\"production\",\"zone_id\":\"$2\",\"zone_name\":\"$3\"}")
  is_success "$resp" || { echo "$resp" | pretty >&2; return 1; }
  printf '%s' "$resp" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"].get("id",""))'
}

# Refresh the KV mirror the panel reads, from the live attached list.
domains_sync_mirror() {
  local ns="$1" json
  json=$(attached_hostnames | python3 -c '
import json,sys
hosts=[l.strip() for l in sys.stdin if l.strip()]
print(json.dumps({h:{"attached":True} for h in hosts}))
')
  kvput "$ns" config:domains "$json"
}

domain_zone_add() {   # create a brand-new primary domain (must be typed once)
  local name
  read -r -p "New primary domain (e.g. brand.com): " name
  name=$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9.-')
  [[ -n "$name" && "$name" == *.* ]] || { echo "That does not look like a domain."; return 1; }
  local resp
  resp=$(req -X POST -H "content-type: application/json" "$API/zones" \
    --data "{\"name\":\"$name\",\"account\":{\"id\":\"${CF_ACCOUNT_ID}\"},\"type\":\"full\"}")
  is_success "$resp" || { echo "$resp" | pretty; return 1; }
  echo "Created ${name}. Set these nameservers at your registrar:"
  printf '%s' "$resp" | python3 -c 'import json,sys
for n in (json.load(sys.stdin)["result"].get("name_servers") or []): print("  "+n)'
  echo "It goes active once the registrar update propagates. Pick it from the list to check."
}

domain_sub_add() {   # ns zone_id zone_name : add a subdomain by label (or apex)
  local ns="$1" zid="$2" zname="$3" label host
  read -r -p "Subdomain label (blank = apex ${zname}): " label
  label=$(printf '%s' "$label" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')
  if [[ -z "$label" ]]; then host="$zname"; else host="${label}.${zname}"; fi
  printf 'Attaching %s ... ' "$host"
  if worker_domain_attach "$host" "$zid" "$zname" >/dev/null; then echo "ok"; else echo "failed"; return 1; fi
  domains_sync_mirror "$ns"
  echo "${host} is linked to the worker. HTTPS may take a few minutes while the certificate is issued."
}

domain_sub_del() {   # ns zone_id zone_name : pick a subdomain to detach
  local ns="$1" zid="$2" dlines
  dlines=$(cf_worker_domains | awk -F'\t' -v z="$zid" '$3==z')
  [[ -n "$dlines" ]] || { echo "No subdomains to delete."; return 0; }
  local dids=() dhosts=() did host i=1
  while IFS=$'\t' read -r did host _; do
    [[ -z "$did" ]] && continue
    dids+=("$did"); dhosts+=("$host"); printf "  %d) %s\n" "$i" "$host"; i=$((i+1))
  done <<< "$dlines"
  local pick; read -r -p "Delete which number (blank cancels): " pick
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick>=1 && pick<=${#dids[@]} )) || { echo "Cancelled."; return 0; }
  printf 'Detaching %s ... ' "${dhosts[$((pick-1))]}"
  is_success "$(req -X DELETE "$(acc "/workers/domains/${dids[$((pick-1))]}")")" && echo "ok" || echo "failed"
  domains_sync_mirror "$ns"
}

domain_zone_menu() {   # ns zone_id zone_name
  local ns="$1" zid="$2" zname="$3" zst
  zst=$(req "$API/zones/${zid}" | python3 -c 'import json,sys;print((json.load(sys.stdin).get("result") or {}).get("status",""))')
  if [[ "$zst" != "active" ]]; then
    echo
    echo "${zname} is ${zst:-pending}, not active yet. Set these nameservers at your registrar:"
    cf_zone_ns "$zid" | while read -r n; do echo "  $n"; done
    local a; read -r -p "Re-check activation now? [Y/n]: " a
    case "$a" in n|N|no|NO) ;; *) req -X PUT "$API/zones/${zid}/activation_check" >/dev/null 2>&1 || true; echo "Re-check triggered. Give it a moment, then pick the domain again." ;; esac
    return 0
  fi
  while true; do
    echo
    echo "Subdomains linked to the worker under ${zname}:"
    local dlines; dlines=$(cf_worker_domains | awk -F'\t' -v z="$zid" '$3==z')
    if [[ -n "$dlines" ]]; then
      local host i=1
      while IFS=$'\t' read -r _ host _; do [[ -z "$host" ]] && continue; printf "  - %s\n" "$host"; done <<< "$dlines"
    else
      echo "  (none yet)"
    fi
    echo "  a) add a subdomain"
    echo "  d) delete a subdomain"
    echo "  b) back"
    local choice; read -r -p "Choose: " choice
    case "$choice" in
      b|B|"") return 0 ;;
      a|A) domain_sub_add "$ns" "$zid" "$zname" ;;
      d|D) domain_sub_del "$ns" "$zid" "$zname" ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

do_domain() {
  require_creds || return 1
  local ns; ns=$(admin_ns) || return 1
  while true; do
    echo
    echo "Primary domains on this account:"
    local zlines; zlines=$(cf_zones)
    local zids=() znames=() zid zname zst i=1
    if [[ -n "$zlines" ]]; then
      while IFS=$'\t' read -r zid zname zst; do
        [[ -z "$zid" ]] && continue
        zids+=("$zid"); znames+=("$zname")
        printf "  %d) %s  [%s]\n" "$i" "$zname" "$zst"; i=$((i+1))
      done <<< "$zlines"
    else
      echo "  (none yet)"
    fi
    echo "  a) add a new primary domain"
    echo "  q) back"
    local choice; read -r -p "Choose: " choice
    case "$choice" in
      q|Q|"") return 0 ;;
      a|A) domain_zone_add ;;
      *) if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#zids[@]} )); then
           domain_zone_menu "$ns" "${zids[$((choice-1))]}" "${znames[$((choice-1))]}"
         else echo "Invalid choice."; fi ;;
    esac
  done
}

open_url() {
  local u="$1"
  if command -v open >/dev/null; then open "$u"
  elif command -v xdg-open >/dev/null; then xdg-open "$u"
  elif command -v start >/dev/null; then start "$u"
  else echo "Open this URL in your browser: ${u}"; fi
}

do_dashboard() {
  load_project
  local worker="${PROJ_ADMIN:-ft-worker}"
  local sub="${PROJ_SUBDOMAIN:-}"
  [[ -z "$sub" ]] && sub=$(account_subdomain)
  local host="${worker}.${sub}.workers.dev"
  local url="https://${host}/admin"

  echo "Dashboard URL: ${url}"

  local ns="${PROJ_KV_ID:-}"

  # Fetch the page body, not just the status: the worker's catch-all returns
  # 200 for unknown paths, so a bare 200 does not prove /admin exists.
  local resp code body
  resp=$(curl -sS "$url" -w $'\n%{http_code}' 2>/dev/null || printf '\n000')
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$code" == "200" && "$body" == *"nx-build:"* ]]; then
    echo "Page reachable. Log in with your admin password."
  elif [[ "$body" == *"App is Active"* ]]; then
    echo "Warning: the live worker does not serve the hosted dashboard yet." >&2
    echo "  It is running older code. Push the current version with:  admin redeploy" >&2
  elif [[ "$code" == "404" ]]; then
    # New code hides the page (404) when disabled or IP-gated. Explain which.
    local en="" ipon=""
    if [[ -n "$ns" ]]; then en=$(kvget "$ns" admin_enabled 2>/dev/null) || en=""; ipon=$(kvget "$ns" admin_ip_on 2>/dev/null) || ipon=""; fi
    if [[ "$en" == "false" ]]; then
      echo "The dashboard is hidden: admin is disabled. Re-enable with:  admin enable" >&2
    elif [[ "$ipon" == "true" ]]; then
      echo "The dashboard is hidden by the IP allowlist; this machine's address is not on it." >&2
      echo "  Add your current IP with:  admin ip set <your-ip>   or turn it off:  admin ip off" >&2
    else
      echo "The /admin page returned 404. If the worker is current this is unexpected; try:  admin redeploy" >&2
    fi
  elif [[ "$code" == "000" ]]; then
    echo "Warning: could not reach ${host}." >&2
    echo "  Deploy/enable the worker first:  admin redeploy   then:  workers url ${worker} on" >&2
  else
    echo "Warning: /admin returned HTTP ${code}. If this persists, run:  admin redeploy" >&2
  fi

  # If no password is set, offer to set one now, since login will fail without it.
  if [[ -n "$ns" ]]; then
    local pw; pw=$(kvget "$ns" pwd) || pw=""
    if [[ -z "$pw" ]]; then
      echo "No admin password is set for this project yet."
      local ans; read -r -p "Set one now? [Y/n]: " ans
      case "$ans" in
        n|N|no|NO) echo "Skipped. Login will fail until you set one with:  admin pwd <password>" >&2 ;;
        *) admin_setpwd "$ns" || true ;;
      esac
    fi
  fi

  open_url "$url"
}

# ---- account reset (destructive) -------------------------------------------
# Deletes every worker and KV namespace on the account. Account-wide, not just
# this tool's resources, so it is gated behind typing the account id.
do_reset() {
  require_creds || return 1
  echo "Fetching current workers and KV namespaces for account ${CF_ACCOUNT_ID}..."
  local wresp kresp workers kvs
  wresp=$(req "$(acc /workers/scripts)")
  kresp=$(req "$(acc '/storage/kv/namespaces?per_page=100')")

  workers=$(printf '%s' "$wresp" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
for it in (d.get("result") or []):
    n=it.get("id","")
    if n: print(n)
')
  kvs=$(printf '%s' "$kresp" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
for it in (d.get("result") or []):
    i=it.get("id","")
    if i: print(i+"\t"+(it.get("title","") or ""))
')

  local wcount kcount
  wcount=$(printf '%s' "$workers" | grep -c . || true)
  kcount=$(printf '%s' "$kvs" | grep -c . || true)

  echo
  echo "Workers (${wcount}):"
  if [[ -n "$workers" ]]; then while IFS= read -r n; do [[ -z "$n" ]] && continue; echo "  ${n}"; done <<< "$workers"; else echo "  <none>"; fi
  echo "KV namespaces (${kcount}):"
  if [[ -n "$kvs" ]]; then while IFS=$'\t' read -r id title; do [[ -z "$id" ]] && continue; printf '  %s  %s\n' "$id" "${title:-(untitled)}"; done <<< "$kvs"; else echo "  <none>"; fi
  echo

  if [[ "$wcount" -eq 0 && "$kcount" -eq 0 ]]; then echo "Nothing to delete."; return 0; fi

  echo "You are about to permanently delete all ${wcount} worker(s) and all ${kcount}"
  echo "KV namespace(s) listed above on account ${CF_ACCOUNT_ID}."
  echo "This includes any resources not created by this tool, and it cannot be undone."
  local confirm
  read -r -p "Type DELETE to proceed (anything else cancels): " confirm
  [[ "$confirm" == "DELETE" ]] || { echo "Cancelled."; return 1; }

  local n id title
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    printf 'Deleting worker %s ... ' "$n"
    is_success "$(req -X DELETE "$(acc "/workers/scripts/${n}")")" && echo "ok" || echo "failed"
  done <<< "$workers"

  while IFS=$'\t' read -r id title; do
    [[ -z "$id" ]] && continue
    printf 'Deleting KV %s (%s) ... ' "$id" "${title:-untitled}"
    is_success "$(req -X DELETE "$(acc "/storage/kv/namespaces/${id}")")" && echo "ok" || echo "failed"
  done <<< "$kvs"

  # Clear saved project state so the next setup starts clean.
  PROJ_KV_ID=""; PROJ_KV_TITLE=""; PROJ_TRACKER=""; PROJ_ADMIN=""; PROJ_SUBDOMAIN=""
  [[ -f "$PROJ_FILE" ]] && rm -f "$PROJ_FILE"
  echo "Done. Project state cleared. Run 'setup' to start fresh."
}

usage() {
  cat <<'TXT'
Credentials & Configuration:
  login                   enter an account-owned token; account auto-detected
  set token <token>       use an account-owned API token (cfat_...)
  set account <id>        set the account id manually
  set account auto        auto-detect the account id from the token
  save                    remember credentials on this machine
  logout                  clear credentials
  status                  show current auth type and account

Setup & dashboard:
  setup                            interactive setup: quick (defaults) or custom (choose names)
  setup [WORKER_NAME] [KV_TITLE]   non-interactive setup with explicit names
  dashboard                        open the hosted admin dashboard (/admin) in your browser
  reset                            DELETE all workers and KV namespaces on the account (asks to confirm)

Admin (controls access to the /mgmt-panel API; public /s/ links are unaffected):
  admin enable            turn the management panel on
  admin disable           turn the management panel off (refuses all mgmt requests)
  admin link              print the management-panel URL
  admin status            show enabled state, IP filter, allowed IPs
  admin pwd [NEW]         set/rotate the panel password (prompts if omitted)
  admin ip on|off         enable/disable the IP allowlist
  admin ip set <csv>      set allowed IPs, comma separated
  admin ip clear          empty the allowed IP list
  admin ip show           show IP filter state and list
  admin redeploy          push the latest worker code
  admin use <kv> <name>   point admin commands at an existing deployment

Custom domains (menu-driven; pick a primary domain, then CRUD subdomains):
  domain                          open the domain manager: list account domains,
                                  add a primary domain, and add/remove subdomains
                                  (linked to the worker automatically)

Link previews (Open Graph image + text shown when a link is shared):
  image add <file>                upload a preview image (must be exactly 1200x630 px)
  image list                      list uploaded images and their URLs
  image remove <key>              delete an uploaded image
  (title, description, and image are set per link in 'link create' or the dashboard)

Campaigns (tracking links):
  link create [DEST] [CAMPAIGN]   create a link (prompts for anything omitted), prints the URL
  link list                       list all campaigns with their tokens and URLs
  link get <token>                show one campaign's full config
  link url <token>                print just the campaign URL
  link delete <token>             delete a campaign link

Results (visitor telemetry):
  results                         show all recorded visits
  results <token>                 show visits for one campaign
  results clear [<token>]         delete telemetry (all, or one campaign)

Workers:
  workers list | get <name> | delete <name> | url <name> on|off

KV:
  kv list | id <title> | create <title> | delete <id> | get <id> <key> | put <id> <key> <val>

  help
  exit | quit
TXT
}

handle_meta() {
  case "${1:-}" in
    login)          shift; do_login "$@" || true ;;
    set)            shift; do_set  "$@" || true ;;
    save)           save_creds || true ;;
    logout)         logout ;;
    status|whoami)  show_status ;;
    help|-h|--help) usage ;;
    dashboard)      do_dashboard ;;
    *) return 2 ;;
  esac
  return 0
}

dispatch() {
  [[ $# -ge 1 ]] || { usage; return 1; }
  require_creds || return 1
  load_project
  local group="$1"; shift || true
  case "$group" in
    setup) do_setup "$@" ;;
    reset) do_reset ;;
    dashboard) do_dashboard ;;
    admin) do_admin "$@" ;;
    domain) do_domain ;;
    image)
      local cmd="${1:-}"; shift || true
      case "$cmd" in
        add)       image_add "$@" ;;
        list)      image_list ;;
        remove|rm) image_remove "$@" ;;
        *) echo "image: add <file> | list | remove <key>   (must be exactly 1200x630 px)" ;;
      esac ;;
    link)
      local cmd="${1:-}"; shift || true
      case "$cmd" in
        create) link_create "$@" ;;
        list)   link_list ;;
        get)    link_get "$@" ;;
        url)    link_url "$@" ;;
        delete) link_delete "$@" ;;
        *) echo "link: create [DEST] [CAMPAIGN] | list | get <token> | url <token> | delete <token>" ;;
      esac ;;
    results|logs)
      local cmd="${1:-}"
      case "$cmd" in
        clear) shift || true; results_clear "$@" ;;
        "")    results_view ;;
        *)     results_view "$cmd" ;;
      esac ;;
    workers)
      local cmd="${1:-}"; shift || true
      case "$cmd" in
        list)   workers_list ;;
        get)    workers_get "$@" ;;
        delete) workers_delete "$@" ;;
        url)    workers_url "$@" ;;
        *) die "Unknown workers command '$cmd'." ;;
      esac ;;
    kv)
      local cmd="${1:-}"; shift || true
      case "$cmd" in
        list)   kv_list ;;
        id)     kv_id "$@" ;;
        create) kv_create "$@" ;;
        delete) kv_delete "$@" ;;
        get)    kv_get "$@" ;;
        put)    kv_put "$@" ;;
        *) die "Unknown kv command '$cmd'." ;;
      esac ;;
    help|-h|--help) usage ;;
    *) die "Unknown group '$group'." ;;
  esac
}

repl() {
  banner
  if rebuild_auth && [[ -n "$CF_ACCOUNT_ID" ]]; then
    echo "Signed in with ${MODE}, account ${CF_ACCOUNT_ID}."
  else
    echo "No credentials yet. Type 'login' to set them."
  fi
  echo "Type 'help' for commands, 'exit' to quit."

  local line
  local -a parts
  while true; do
    if ! IFS= read -r -e -p "cf> " line; then echo; break; fi
    [[ -z "${line//[[:space:]]/}" ]] && continue

    parts=()
    eval "parts=($line)" 2>/dev/null || { echo "Could not parse that line."; continue; }
    [[ ${#parts[@]} -eq 0 ]] && continue

    case "${parts[0]}" in
      exit|quit) break ;;
    esac

    if handle_meta "${parts[@]}"; then continue; fi
    ( dispatch "${parts[@]}" ) || true
  done
  echo "bye"
}

main() {
  command -v curl >/dev/null || die "curl is required."
  load_creds
  load_project

  if [[ $# -eq 0 || "${1:-}" == "shell" || "${1:-}" == "repl" ]]; then
    repl
    return
  fi

  if handle_meta "$@"; then return; fi
  dispatch "$@"
}

main "$@"