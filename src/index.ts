// ITsmart Fleet Worker — heartbeat-only reporting + daily info report.
export interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  BOOTSTRAP_SECRET?: string;
  DASHBOARD_HOST: string;
  AGENT_API_HOST: string;
  /** Comma-separated origins allowed to call the admin API (e.g. the Lovable dashboard URL). */
  DASHBOARD_ORIGINS?: string;
}

const RETENTION_DAYS = 35;
const now = () => new Date().toISOString();
const json = (d: unknown, s = 200, h: HeadersInit = {}) =>
  new Response(JSON.stringify(d), { status: s, headers: { "content-type": "application/json", ...h } });

async function sha256(s: string) {
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
}
function safeEq(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
async function authNode(env: Env, req: Request, nodeId: unknown) {
  const tok = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!tok || typeof nodeId !== "string") return false;
  const row = await env.DB.prepare("SELECT token_hash FROM nodes WHERE id=?").bind(nodeId).first<{ token_hash: string }>();
  return !!row && safeEq(row.token_hash, await sha256(tok));
}
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v: unknown) => (typeof v === "string" && v.length < 64 ? v : null);

function cors(env: Env, req: Request): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";
  const allowed = (env.DASHBOARD_ORIGINS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (!allowed.includes(origin)) return {};
  return { "access-control-allow-origin": origin, "access-control-allow-credentials": "true",
    "access-control-allow-headers": "content-type", "access-control-allow-methods": "GET,POST,OPTIONS", vary: "origin" };
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const host = url.hostname;
    const p = url.pathname;
    if (p === "/health") return json({ ok: true });

    // ---------- Agent host ----------
    if (host === env.AGENT_API_HOST) {
      if (req.method !== "POST") return json({ error: "not found" }, 404);
      const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
      if (!(await authNode(env, req, body.node_id))) return json({ error: "unauthorized" }, 401);
      const id = body.node_id as string, t = now();

      if (p === "/api/v1/heartbeat") {
        // Heartbeat: node_id + optional live metrics (cpu/ram/disk %). Versions come in the daily report.
        const cpu = num(body.cpu_percent), mem = num(body.memory_percent), disk = num(body.disk_percent);
        await env.DB.batch([
          env.DB.prepare(`UPDATE nodes SET last_seen=?, cpu_percent=COALESCE(?,cpu_percent),
            memory_percent=COALESCE(?,memory_percent), disk_percent=COALESCE(?,disk_percent) WHERE id=?`).bind(t, cpu, mem, disk, id),
          env.DB.prepare("INSERT INTO beats(node_id, received_at, cpu, mem, disk) VALUES(?,?,?,?,?)").bind(id, t, cpu, mem, disk),
        ]);
        return json({ ok: true });
      }
      if (p === "/api/v1/report") {
        // Daily info report: versions + metrics. Also counts as a heartbeat.
        await env.DB.prepare(`UPDATE nodes SET core_version=?, supervisor_version=?, os_version=?, cpu_percent=?, memory_percent=?,
          disk_percent=?, info_reported_at=?, last_seen=? WHERE id=?`)
          .bind(str(body.core_version), str(body.supervisor_version), str(body.os_version), num(body.cpu_percent),
            num(body.memory_percent), num(body.disk_percent), t, t, id).run();
        return json({ ok: true });
      }
      return json({ error: "not found" }, 404);
    }

    // ---------- Dashboard host (behind Cloudflare Access) ----------
    if (host !== env.DASHBOARD_HOST) return json({ error: "not found" }, 404);
    const ch = cors(env, req);
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });

    if (p === "/api/v1/admin/nodes" && req.method === "GET") {
      const { results } = await env.DB.prepare(`SELECT id, name, ha_url, last_seen, core_version, supervisor_version, os_version,
        cpu_percent, memory_percent, disk_percent, info_reported_at FROM nodes ORDER BY id`).all();
      return json({ nodes: results }, 200, ch);
    }
    const hm = p.match(/^\/api\/v1\/admin\/nodes\/([^/]+)\/history$/);
    if (hm && req.method === "GET") {
      const hours = Math.min(744, Math.max(1, Number(url.searchParams.get("hours")) || 24));
      const since = new Date(Date.now() - hours * 3600_000).toISOString();
      const { results } = await env.DB.prepare("SELECT received_at FROM beats WHERE node_id=? AND received_at>=? ORDER BY received_at")
        .bind(decodeURIComponent(hm[1]!), since).all<{ received_at: string }>();
      return json({ heartbeats: results.map((r) => r.received_at) }, 200, ch);
    }
    const deleteMatch = p.match(/^\\/api\\/v1\\/admin\\/nodes\\/([^/]+)$/);
    if (deleteMatch && req.method === "DELETE") {
      const nodeId = decodeURIComponent(deleteMatch[1]!);
      const exists = await env.DB.prepare("SELECT id FROM nodes WHERE id=?").bind(nodeId).first<{ id: string }>();
      if (!exists) return json({ error: "node not found" }, 404, ch);
      await env.DB.batch([
        env.DB.prepare("DELETE FROM beats WHERE node_id=?").bind(nodeId),
        env.DB.prepare("DELETE FROM nodes WHERE id=?").bind(nodeId),
      ]);
      return json({ ok: true, node_id: nodeId }, 200, ch);
    }
    if (p === "/api/v1/admin/bootstrap" && req.method === "POST") {
      const b = (await req.json().catch(() => ({}))) as Record<string, string>;
      if (!env.BOOTSTRAP_SECRET || !b.secret || !safeEq(b.secret, env.BOOTSTRAP_SECRET)) return json({ error: "forbidden" }, 403, ch);
      if (!/^[a-z0-9-]{1,32}$/i.test(b.node_id ?? "") || !b.name) return json({ error: "invalid node_id or name" }, 400, ch);
      const raw = crypto.getRandomValues(new Uint8Array(32));
      const token = [...raw].map((x) => x.toString(16).padStart(2, "0")).join("");
      try {
        await env.DB.prepare("INSERT INTO nodes(id, name, ha_url, token_hash) VALUES(?,?,?,?)")
          .bind(b.node_id, b.name.slice(0, 80), b.ha_url || null, await sha256(token)).run();
      } catch { return json({ error: "node already exists" }, 409, ch); }
      return json({ node_id: b.node_id, token }, 200, ch);
    }
    if (p.startsWith("/api/")) return json({ error: "not found" }, 404, ch);
    return env.ASSETS.fetch(req);
  },

  // Daily cleanup of old heartbeats. Add to wrangler.toml: [triggers] crons = ["15 3 * * *"]
  async scheduled(_e: ScheduledController, env: Env) {
    const cutoff = new Date(Date.now() - RETENTION_DAYS * 86400_000).toISOString();
    await env.DB.prepare("DELETE FROM beats WHERE received_at < ?").bind(cutoff).run();
  },
};
