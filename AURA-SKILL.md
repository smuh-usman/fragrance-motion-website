---
name: aura-landing
description: >-
  Conventions and ready-made recipes for the AURA scroll-driven product landing
  site at /Users/david/Desktop/adobe/activetheory-remake (a premium 360Â° home
  speaker; brand AURA, slogan "Sound. Elevated."). USE THIS SKILL whenever
  working on that site â€” any request touching its sections (hero, impact,
  showcase, the "Why AURA" gallery, buy, specs, footer), the scroll-scrubbed
  background video, the tubes cursor, glass panels/cards, GSAP ScrollTrigger
  pins, Lenis scroll, the brand type/colour, or "swap the background video / add
  a section / change the scroll animation" â€” even if the user doesn't name the
  file or the stack. It captures the architecture, brand tokens, the exact
  ffmpeg video-swap command, the pinned-scrub pattern, the one-card gallery,
  glass + gold conventions, the video freeze math, and the preview-verification
  quirks so you don't re-derive them.
---

# AURA landing site

A single-page, scroll-driven landing for a premium 360Â° home speaker.
Brand **AURA**, slogan **"Sound. Elevated."** Dark, warm, premium: a full-screen
background video that scrubs with scroll, a neon "tubes" cursor, and frosted
glass UI with a gold accent.

## Project facts

- **Root:** `/Users/david/Desktop/adobe/activetheory-remake`
- **Stack:** Vite 5 Â· vanilla JS (ES modules) Â· GSAP + `gsap/ScrollTrigger` Â· Lenis (smooth scroll) Â· `threejs-components` tubes cursor (lazy-loaded)
- **Files that matter:**
  - `index.html` â€” all section markup + Google Fonts link
  - `src/main.js` â€” scroll wiring, section logic, video scrub, tubes, gallery
  - `src/style.css` â€” layout + sections + brand type rule
  - `src/glass.css` â€” glass surfaces, buttons, chips (loaded **after** style.css)
  - `public/bg.mp4` â€” the scroll-scrubbed background video
  - `public/img/product-{1,2,3}.jpg` â€” macro shots (1=fabric weave, 2=top controls, 3=wood base + glow)
- **Run:** `npm run dev` (port 5173) Â· **Build:** `npm run build` (add `-- --base=./` for a portable static build to zip/host)
- **Section order (topâ†’bottom):** `#home` (hero) â†’ `#impact` â†’ `#showcase` â†’ `#process` (gallery) â†’ `#contact` (buy) â†’ `#studio` (specs, ends on black) â†’ `footer`

## Brand tokens

- **Name** AURA Â· **slogan** "Sound. Elevated." (hero is the two-line slogan).
- **Type:** headings = **Manrope ExtraBold**, body = **Inter** â€” loaded from Google Fonts in `<head>`. `:root` has `--font` (Inter) and `--font-head` (Manrope); a rule in `style.css` applies `--font-head` to display elements (`.nav__logo, .hero__title, .impact__head, .showcase__line, .section-head h2, .hslide__name, .buy__title, .buy__amount, .stat__num, .preloader__word, .footer__big`). Add new headings to that selector.
- **Colour:** gold accent `--accent:#d4af37`, bronze `--accent-2:#8a6d3b` (close to the brand Amber/Walnut). The primary glass button gradient is built from these via `color-mix`, so changing the accent re-themes buttons + numbers + underlines automatically.

## Layer architecture (z-index)

Background is fixed; content scrolls over it. Keep this stack intact:

| element | z | role |
|---|---|---|
| `.bg-video` (`#bgv`) | 0 | fixed full-screen video, `object-fit:cover`, scrubbed by scroll |
| `.bg-tint` | 1 | radial darken for text legibility |
| `#bg` â†’ `#tubes` | 2 | tubes cursor canvas. **`mix-blend-mode: screen` on `#bg`** (the wrapper, not the canvas) so its black bg drops out and only the neon adds over the video. `#bg` is a fixed viewport-sized wrapper so the tubes lib measures the viewport, not the tall body. |
| `#page` (sections) | 10 | all content |
| `#cursor` | 100 | custom cursor ring (`mix-blend-mode:difference`) |

The **footer** is a sibling of the sections (full-bleed black band); the video dissolves to black above it via a CSS gradient (recipe 5). No fixed black overlay.

## Verifying in Claude Preview (important quirk)

The preview tab often runs **backgrounded**, so `requestAnimationFrame` throttles to ~1 fps: the gsap preloader crawls, Lenis desyncs from the real document scroll, scroll-driven `onUpdate` callbacks don't fire reliably, and screenshots lag.

- **Dev hooks** (dev mode): `window.__lenis`, `window.__ST` (ScrollTrigger), `window.__bgv` (the video). Use them.
- To inspect a pinned/scrub state, **force the render yourself** in an eval: replicate the section's `render(progress)` math and set the inline styles, then screenshot.
- To move the viewport into a pin, native `window.scrollTo(0, y)` + `window.__ST.update()` beats `lenis.scrollTo`. Compute `y` from `element.offsetTop` + a fraction of the pin length, not from `ScrollTrigger.start` (stale on jumps with multiple pins).
- The hero text may look blank in screenshots â€” that's the gsap intro stuck in its from-state, not a bug. Force the spans to `transform:none` / sub opacity 1 to capture.
- Verify **math via eval** when screenshots are unreliable. Always `npm run build` after edits â€” best correctness check when visual verification is flaky.
- The preview viewport sometimes collapses to ~9px wide (a panel glitch) â€” `preview_resize` back to 1280Ã—800.

## Recipes

### 1. Swap the background video

Re-encode to **all-keyframe** so scrubbing seeks are smooth (raw AI/H.264 clips jerk on scrub). Keep the clip's native resolution & fps for full quality. Use the bundled script:

```bash
scripts/swap-bg-video.sh "/path/to/new-clip.mp4"
```

It runs (native res/fps, every frame a keyframe, near-lossless, no audio):

```bash
ffmpeg -y -i "<input>" -an -c:v libx264 -preset slow -crf 18 \
  -g 1 -keyint_min 1 -sc_threshold 0 -pix_fmt yuv420p -movflags +faststart public/bg.mp4
```

Full-quality 1080p/120fps all-keyframe is large (~110 MB) â€” fine for local; pass a scale/fps to the script for a lighter file. The scrub maps scroll â†’ `currentTime` automatically; no code change. After swapping, confirm `__bgv.readyState===4` and `__bgv.duration`.

### 2. Add a pinned, scroll-scrubbed section

The signature interaction (see `setupImpact`, `setupGallery`):

```js
function setupThing() {
  function render(p) { /* p 0â†’1; set transforms/opacity/blur from p */ }
  render(0);
  ScrollTrigger.create({
    trigger: '#thing', start: 'top top',
    end: () => '+=' + (innerHeight * 1.7), // pin length = scroll distance
    pin: '.thing__pin', scrub: 1,
    onUpdate: (self) => render(self.progress),
  });
}
```
Call it in the boot block with the other `setup*()`s, then `ScrollTrigger.refresh()`. Pinned element: `height:100vh; overflow:hidden; position:relative`.

Word-by-word reveal (impact): split the headline into `<span class="word">`s; per word `o = clamp((p - i/N*0.75)/0.12)`; set opacity `0.12+o*0.88`, `blur((1-o)*8px)`, `translateY((1-o)*18px)`. Accent a key word with a `word--accent` span.

### 3. "Why AURA" gallery â€” one card at a time, parked left

Cards are absolutely positioned, **parked on the LEFT** so the right half shows the scrubbing video; you scroll through them one at a time (current swipes out left, next in from right). Build slides into `#hgallery-track`, then:

```js
const slides = [...TRACK.querySelectorAll('.hslide')];
const N = slides.length;
function render(p) {
  const pos = p * (N - 1);                 // one card centred at a time
  slides.forEach((el, i) => {
    const d = pos - i, ad = Math.abs(d);
    el.style.opacity = Math.max(0, 1 - ad / 0.6);
    el.style.transform = `translate(${-d * 130}px, -50%) scale(${1 - Math.min(ad,1)*0.06})`;
    el.style.filter = `blur(${Math.min(ad*10,14)}px)`;
    el.style.zIndex = String(100 - Math.round(ad*10));
    el.style.pointerEvents = el.style.opacity > 0.6 ? 'auto' : 'none';
  });
  // counter "0N / 0M": cur = round(pos)+1
}
// pin end â‰ˆ (N-1)*innerHeight*0.62
```
CSS: cards `position:absolute; top:50%; left:clamp(1.5rem,6vw,7rem); width:min(400px,44vw)`. **See gotcha #1 â€” positioning selector must out-specify `.glass`.** Slides mix an intro card, feature cards (`glass`), and photo cards (`.hslide--photo`, no glass, `aspect-ratio:4/5`).

### 4. Glass panels / cards + hover

Add `glass` (frosted surface, from `glass.css`) + a layout class. Direct children need `position:relative; z-index:2` to sit above the glass `::before` sheen. Hover lift: `translateY(-10px)` + accent border/glow via `color-mix(in srgb, var(--accent) 55%, transparent)`. Buttons: `glass glass-btn glass-btn--primary|--ghost`. Chips: `glass glass-chip`. The buy card uses `background: rgba(12,14,20,.55)` so copy stays legible over bright video frames.

### 5. Footer dissolve-to-black

Footer lives **outside** the padded sections (full-bleed). Solid black bg + a gradient above it does the dissolve â€” robust, no ScrollTrigger:

```css
.footer { position: relative; margin-top: 30vh; padding: 16vh clamp(1.25rem,5vw,6rem) 8vh; background: var(--bg); }
.footer::before { content:""; position:absolute; left:0; right:0; bottom:100%; height:45vh;
  background: linear-gradient(to bottom, transparent, var(--bg)); pointer-events:none; }
```

### 6. Freeze / slow the video during a pin

The bg scrub is driven in the Lenis `scroll` handler. To hold or slow it while a section is pinned, map an **effective scroll** that excludes (a fraction of) the pin's length. `galleryST` is captured for this; `k` controls speed:

```js
const k = 1; // 1 = normal scrub Â· 0 = freeze Â· 0.12 â‰ˆ 8Ã— slower
let eff = s, removed = 0;
if (galleryST) {
  const gs = galleryST.start, ge = galleryST.end, gl = ge - gs;
  removed = gl * (1 - k);
  if (s >= ge) eff = s - removed;          // resume smoothly after the pin
  else if (s > gs) eff = gs + (s - gs) * k; // slow/hold during the pin
}
const p = eff / Math.max(1, lenis.limit - removed);
const t = p * (bgVideo.duration - 0.05);
if (Math.abs(t - lastVideoT) > 0.008) { bgVideo.currentTime = t; lastVideoT = t; } // skip redundant seeks
```
Continuity holds at `s=ge` for any `k` (both branches equal `gs + gl*k`).

## Gotchas

1. **`.glass{position:relative}` beats `.hslide{position:absolute}`.** Feature cards carry `glass`, and `glass.css` loads after `style.css` (equal specificity â†’ later wins), so cards fall back to `relative`, stack in flow, and later cards slide off-screen. Fix by out-specifying: `.hgallery .hslide { position:absolute; ... }`.
2. **Tubes lib sizes to the canvas's parent** â†’ keep `#tubes` inside the fixed, viewport-sized `#bg` wrapper.
3. **Tubes context is opaque** â€” can't make the canvas transparent post-init; composite with `mix-blend-mode: screen` on the wrapper.
4. **Lazy tubes** â€” `import()`-ed on idle to keep initial JS ~140 KB instead of ~900 KB. Don't move it back to a static import.
5. **Adding a pin shifts later pins** â€” anything reading `ScrollTrigger.start/end` uses live values; recompute on refresh and prefer `invalidateOnRefresh:true`.
6. **Don't open the static build via `file://`** â€” ES modules + video need HTTP (`npx serve dist`).