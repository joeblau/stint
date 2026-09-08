# Stint

Monorepo for the Stint race viewer, managed with [Turborepo](https://turborepo.dev) and Bun workspaces.

## Layout

- **`apple/`** — the native Mac and iPad app (SwiftUI, MapKit, SceneKit). See `apple/README.md` for details.
- **`telemetry/`** — standalone historical OpenF1 normalization and benchmarks. See [the telemetry audit and integration limits](telemetry/README.md).
- **`workers/`** — the landing page, a Next.js site deployed to Cloudflare Workers via OpenNext (`@opennextjs/cloudflare`).

## Commands (from the repo root)

```sh
bun install       # install workspace dependencies (once)
bun dev           # landing page dev server → http://localhost:3000
bun mac:stint     # build and launch the Mac app
bun ipad:stint    # build and deploy to a physical iPad
bun ipad:stint:sim # build and deploy to an iPad simulator
```

## Workers

```sh
cd workers
bun run preview   # build with OpenNext and preview in workerd → http://localhost:8787
bun run deploy    # build and deploy to Cloudflare Workers (needs wrangler auth)
```
