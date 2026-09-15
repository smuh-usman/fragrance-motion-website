# imaginary fragrances — Lost in Kashmir

A motion-first product microsite for the "Lost in Kashmir" extrait de parfum.
The whole page is one fixed stage and a tall scroll track: scroll is read as a
position in a short cinematic film — the bottle opens, its ingredients become
liquid, and it fills — and the playhead eases toward that position rather than
snapping to it. Once the film's track is exhausted, the hero releases and a
full product page (gallery, notes, pricing, description) scrolls into view
underneath it.

**Live:** https://fragrance-motion-website.bale97cook.workers.dev/

## Why this exists

This project is an example of using [Higgsfield](https://higgsfield.ai) to
generate animated/motion websites: the film's raw cinematic footage was
generated with Higgsfield's video generation, then processed by this repo's
own scripts (`scripts/depth.mjs`, `scripts/encode-plate.mjs`) into the
re-encoded, scroll-scrubbable plate that `src/film/Film.tsx` drives — a
two-frame GOP encode so seeking to an arbitrary scroll position never has to
walk forward from a distant keyframe.

## Stack

- React 18 + TypeScript, built with Vite
- Three.js / `@react-three/fiber` / `@react-three/drei` for the scene layer
- GSAP + ScrollTrigger, and Lenis for the damped scroll-to-playhead follow
- Deployed as a static SPA on Cloudflare Workers (assets-only, no server
  functions — see `wrangler.toml`)

## Structure

```
src/
  film/        the scroll-driven cinematic hero (Film.tsx, timing.ts)
  scene/       the WebGL scene layer (Three.js/react-three-fiber)
  scroll/      ScrollProvider — the single scroll clock everything reads from
  product/     the product page: gallery, notes, pricing, description, footer
public/assets/ shipped video, poster, and product imagery
brand/         raw/master source assets (gitignored, not deployed)
scripts/       depth map + video plate encoding tooling
aiteam/        the AI engineering harness used to build and review this repo
```

## Development

```
npm install
npm run dev
```

## Build

```
npm run typecheck
npm run build
npm run preview
```

## Deploy

```
npm run deploy
```

Runs `vite build && wrangler deploy`. Requires either `wrangler login` once
for a local session, or `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` set
in the environment — never committed to the repo.

## How changes get made here

Application code in this repo is implemented and independently reviewed
through the `aiteam/` harness rather than edited freely: an implementation
model builds against a written acceptance-criteria contract, and a separate
read-only reviewer model has to pass it before it merges. See
[`aiteam/README.md`](aiteam/README.md) for how the harness works, and
`aiteam/bin/task.sh list` for the record of what's been built.
