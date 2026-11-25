# ITsmart Fleet – diegimas nuo pradžios iki galo

## Reikalinga
Cloudflare paskyra su `itsmart.lt` domenu/DNS Cloudflare, Node.js LTS ir Home Assistant OS.

## 1. Patikrinkite konfigūraciją
`wrangler.toml` nurodo D1 ID `8e53abd4-b99d-4d95-9e33-183a9a19981a`, `status.itsmart.lt` ir `fleet-api.itsmart.lt`. Įsitikinkite, kad D1 priklauso jūsų Cloudflare paskyrai; jei ne, sukurkite savo D1 ir pakeiskite `database_id`.

## 2. Įkelkite į GitHub
Sukurkite privatų repository ir įkelkite visą ZIP turinį. `haos_addon/repository.json` pakeiskite `YOUR_GITHUB_USERNAME/YOUR_REPOSITORY` tikru `owner/repo`.

## 3. Įdiekite Worker
Projekto kataloge:
```bash
npm install
npx wrangler login
npx wrangler d1 migrations apply itsmart-fleet --remote
npx wrangler secret put BOOTSTRAP_SECRET
npm run typecheck
npm run deploy
```
`BOOTSTRAP_SECRET` įveskite ilgą atsitiktinę reikšmę (32+ simbolių). Nedėkite jos į GitHub.

## 4. Prijunkite domenus
Cloudflare → Workers & Pages → `itsmart-fleet` → Settings → Domains & Routes → Add Custom Domain. Pridėkite `status.itsmart.lt` ir `fleet-api.itsmart.lt` (jei jau pridėti, nekartokite).

## 5. Apsaugokite administravimą
Cloudflare Zero Trust → Access → Applications → Add application → Self-hosted. Domain `status.itsmart.lt`, Path `*`; Allow politika tik jūsų el. paštui. `fleet-api.itsmart.lt` neužrakinkite interaktyviu prisijungimu – agentas turi pasiekti heartbeat API.

## 6. Užregistruokite klientą
Atidarykite `https://status.itsmart.lt`, prisijunkite per Access. Skiltyje Registruoti įveskite kliento pavadinimą, unikalų ID (pvz. `n1`) ir `BOOTSTRAP_SECRET`. Spauskite Registruoti diegimą ir išsisaugokite vieną kartą rodomą tokeną.

## 7. Prijunkite Home Assistant
Home Assistant → Settings → Add-ons → Add-on Store → ⋮ → Repositories. Įveskite GitHub repository URL. Įdiekite ITsmart Fleet Agent. Konfigūruokite:
- `fleet_url`: `https://fleet-api.itsmart.lt`
- `node_id`: tas pats ID kaip registracijoje
- `node_token`: gautas tokenas
- `heartbeat_interval`: `60`
- `report_interval_hours`: `24`

Išsaugokite ir paleiskite add-on. Po minutės skydelyje patikrinkite PRISIJUNGĘS būseną ir CPU/RAM/Disk.

## 8. Saugumas ir kasdienis valdymas
`BOOTSTRAP_SECRET` po pradinių registracijų galima išjungti: `npx wrangler secret delete BOOTSTRAP_SECRET`. Kiekvienam klientui naudokite atskirą tokeną. Pašalinus klientą iš skydelio ištrinamas ir jo heartbeat istorijos įrašas, tačiau pats Home Assistant add-on automatiškai nesustabdomas – jį sustabdykite arba pašalinkite atskirai.
