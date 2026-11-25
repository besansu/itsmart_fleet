# ITSmart Home Assistant Fleet Monitor (Cloudflare)

A starter monitoring platform for multiple Home Assistant OS installations.

## Included

- Cloudflare Worker API (TypeScript)
- Cloudflare D1 schema and migration
- Static dashboard served by the Worker
- Cloudflare Access protection guidance
- Home Assistant OS add-on agent for heartbeat/version reporting
- GitHub Actions deployment workflow

This is a monitoring starter, not a production-certified service. Test it with one non-critical HA installation before adding the rest.

## Architecture

- `https://status.itsmart.lt` — dashboard and admin API. Protect this hostname with Cloudflare Access.
- `https://fleet-api.itsmart.lt` — public heartbeat endpoint. Each node authenticates with its own random bearer token.
- Cloudflare Worker — API and dashboard host.
- Cloudflare D1 — node registry and heartbeat history.
- HAOS add-on — calls the local Supervisor API and sends heartbeat data to Cloudflare.

The Worker rejects admin endpoints on `fleet-api.itsmart.lt`. The dashboard and admin endpoints are only served on `status.itsmart.lt`, which must be protected by Cloudflare Access.

## 1. Create the Cloudflare resources

From the project root, install dependencies:

```bash
npm install
```

Authenticate Wrangler:

```bash
npx wrangler login
```

Create the D1 database:

```bash
npx wrangler d1 create itsmart-fleet
```

Copy the returned `database_id` into `wrangler.toml`.

Apply the schema:

```bash
npx wrangler d1 migrations apply itsmart-fleet --remote
```

Set the admin bootstrap secret as a Worker secret:

```bash
npx wrangler secret put BOOTSTRAP_SECRET
```

Use a long random value (at least 32 random characters). This secret is only used to create the first node token through the one-time bootstrap endpoint. Do not put it in GitHub source files.

Deploy:

```bash
npm run deploy
```

## 2. Configure hostnames

In Cloudflare DNS, add the Worker custom domains:

- `status.itsmart.lt`
- `fleet-api.itsmart.lt`

In the Cloudflare dashboard, open **Workers & Pages → itsmart-fleet → Settings → Domains & Routes** and add both custom domains. Cloudflare manages DNS/TLS for Worker custom domains.

If your account UI offers custom domains directly, use that rather than manually creating a Worker route.

## 3. Protect the dashboard

In **Cloudflare Zero Trust → Access → Applications**, create a self-hosted application:

- Application domain: `status.itsmart.lt`
- Path: `*`
- Policy: allow only your email address or your chosen identity group.

Do not put an Access login policy over `fleet-api.itsmart.lt/api/v1/heartbeat`; the HA agents need to reach that endpoint without an interactive login. Node bearer tokens protect heartbeat submissions.

The Worker also enforces hostname separation:
- `status.itsmart.lt`: dashboard and admin endpoints.
- `fleet-api.itsmart.lt`: heartbeat endpoint only.

## 4. Create the first node

After deployment and Access setup, open:

`https://status.itsmart.lt`

Use the bootstrap section in the dashboard:
1. Enter the `BOOTSTRAP_SECRET`.
2. Enter a node ID such as `n1`.
3. Enter a display name such as `Home Assistant 1`.
4. Optionally enter the HA URL, e.g. `https://n1.itsmart.lt`.
5. Click **Register node**.
6. Copy the generated node token immediately and store it safely.

The token is shown only once. The database stores only its SHA-256 hash.

Repeat for `n2`, `n3`, etc. Do not reuse node tokens.

## 5. Install the HAOS add-on

1. Push this project to a GitHub repository.
2. Edit `haos_addon/repository.json` and replace `YOUR_GITHUB_USERNAME/YOUR_REPOSITORY`.
3. Commit and push.
4. In Home Assistant, go to **Settings → Add-ons → Add-on Store → ⋮ → Repositories**.
5. Add your GitHub repository URL.
6. Find **ITSmart Fleet Agent**, install it, and open its Configuration tab.
7. Set:
   - `fleet_url`: `https://fleet-api.itsmart.lt`
   - `node_id`: the ID you registered (e.g. `n1`)
   - `node_token`: the token shown once during registration
   - `heartbeat_interval`: `60`
8. Save and start the add-on. Check its logs.

The agent reads Core, Supervisor and OS versions using the local Supervisor API. CPU/RAM/disk metrics are currently sent as null; they are not fabricated.

## 6. Add automatic GitHub deployment

Create these GitHub repository secrets:

- `CLOUDFLARE_API_TOKEN` — token with permission to edit Workers and D1 for this account.
- `CLOUDFLARE_ACCOUNT_ID` — your Cloudflare account ID.

The included workflow deploys on pushes to `main`. Before relying on it, run the manual deployment once and verify that the D1 database and custom domains are configured.

## Status rules

The dashboard derives status from `last_seen`:
- Online: heartbeat received within 120 seconds.
- Stale: more than 120 seconds ago.
- Offline: more than 300 seconds ago.

The thresholds are in `src/index.ts` and can be adjusted.

## API

### Heartbeat

`POST https://fleet-api.itsmart.lt/api/v1/heartbeat`

Header:

```http
Authorization: Bearer NODE_TOKEN
Content-Type: application/json
```

Example body:

```json
{
  "node_id": "n1",
  "core_version": "2026.11.0",
  "supervisor_version": "2026.11.2",
  "os_version": "17.0",
  "cpu_percent": null,
  "memory_percent": null,
  "disk_percent": null
}
```

### Admin

The following endpoints are only accepted on `status.itsmart.lt`, protected by Cloudflare Access:

- `POST /api/v1/admin/bootstrap`
- `GET /api/v1/admin/nodes`
- `GET /api/v1/admin/nodes/:id/history`

### Health

`GET /health` returns a small health response. It does not expose secrets or node data.

## Security notes

- Use Cloudflare Access on the entire `status.itsmart.lt` hostname.
- Never protect the public agent heartbeat endpoint with an interactive Access login.
- Never expose the Home Assistant Supervisor API to the internet.
- Each node has its own token. Rotate a token by re-registering/replacing it in a future admin feature; this starter does not yet include token rotation or node deletion.
- Keep `BOOTSTRAP_SECRET` private. After registering your nodes, you can remove it with `npx wrangler secret delete BOOTSTRAP_SECRET`; the dashboard bootstrap action will then stop working.
- Use HTTPS only.
- D1 heartbeat history is retained indefinitely in this starter. Add a retention policy before operating a large fleet for a long time.
- The Worker checks hostnames but does not independently validate the Access JWT. Access enforcement is configured at Cloudflare's edge. Keep the `status` Access application enabled and test it from a logged-out browser.

## Future maintenance actions

The project intentionally does not trigger updates yet. A safe future design is:
1. An authenticated administrator creates a maintenance command.
2. The HAOS agent polls for commands over HTTPS.
3. The agent validates the command against a strict allowlist.
4. The agent invokes the local Supervisor API.
5. The agent reports the result.

Do not expose Supervisor endpoints or tokens to the central Worker.

## v0.2 changes (heartbeat-only reporting)

- `POST /api/v1/heartbeat` body is now just `{"node_id":"n1"}` — sent every `heartbeat_interval` seconds.
- `POST /api/v1/report` carries versions/metrics — sent once every `report_interval_hours` (default 24) and on add-on start.
- Heartbeats are stored in a small `beats` table; a daily cron deletes rows older than 30 days.
- `GET /api/v1/admin/nodes` → `{ nodes: [...] }`, `GET /api/v1/admin/nodes/:id/history?hours=24` → `{ heartbeats: [iso, ...] }`.
- Set `DASHBOARD_ORIGINS` in `wrangler.toml` to the dashboard's address so it can read the admin API with your Cloudflare Access login.
- Apply: `npm run db:migrate:remote` then `npm run deploy`. If your old D1 already has some of the new columns, remove those `ALTER` lines from `migrations/0002_*.sql`.

## v0.3 changes

- Heartbeat now also carries live `cpu_percent`, `memory_percent`, `disk_percent` (host CPU/RAM from /proc, disk from Supervisor `/host/info`).
- Each heartbeat row stores those metrics (`migrations/0003_beat_metrics.sql`).
- History endpoint accepts up to `hours=744` (31 days) for the dashboard's History page; heartbeats are kept 35 days.
- Apply: `npm run db:migrate:remote`, `npm run deploy`, then update the add-on to 0.3.0 in Home Assistant.

## v0.4 dashboard and node removal

`public/index.html` is the dashboard served by the Worker. It uses the same-origin admin API, shows CPU/RAM/Disk alongside availability, and adds node deletion with a confirmation dialog. `DELETE /api/v1/admin/nodes/:id` deletes the node and its heartbeat history. No new D1 migration is required.

Deploy:
```bash
npm install
npx wrangler d1 migrations apply itsmart-fleet --remote
npm run typecheck
npm run deploy
```
