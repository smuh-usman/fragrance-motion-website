/**
 * Derives the ceremony's bottle plates from the packshot, without generating a
 * single pixel of new imagery.
 *
 *   bottle-body-cut.png  the bottle matted off the studio sweep, cropped at the
 *                        collar so the original cap is never in the picture
 *   bottle-clean.png     the same plate with the printed type lifted off it, so
 *                        an empty vessel can be shown once the cover opens
 *   nozzle.png           a sprayer built from the collar's own gold pixels
 *
 * The matte is found by scanning, not by thresholding. No single cue separates
 * this bottle from this background: on the left the pale glass is barely greener
 * than the studio sweep but clearly darker, and on the right the cast shadow is
 * both darker AND slightly green, so it survives every threshold the glass does.
 * What holds everywhere is that the bottle's edge is a step and the shadow's is
 * a ramp - chroma jumps ~22 levels across a few pixels at the silhouette and
 * drifts ~6 levels across eighty at the shadow. So each row is scanned inward
 * from both borders for that step, and the span between the two is the bottle.
 *
 * The printed type is white and the monogram red, so both fall outside a green
 * key and come back as holes; lifting them off is a harmonic fill, which is
 * invisible here because the surface under them is a smooth gradient with no
 * texture to invent - only a slope to continue.
 */
import sharp from "sharp";
import { mkdir } from "node:fs/promises";

const SRC = "public/assets/lost-in-kashmir/packshot.png";
const OUT = "public/assets/lost-in-kashmir/";
const W = 820, H = 898;
const BODY_TOP = 296;

/** The gold collar, measured off the frame. It is neutral, so the green key
 *  misses it, and it sits on the crop line where a flood fill would eat it. */
const COLLAR = { x0: 326, x1: 488, y0: 312, y1: 348 };

const { data: px } = await sharp(SRC).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
const idx = (x, y) => (y * W + x) * 4;
const luma = (i) => (0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2]) / 255;
const green = (i) => (px[i + 1] - Math.max(px[i], px[i + 2])) / 255;

// --- 1. the matte ---------------------------------------------------------
const GLASS_TOP = 316, GLASS_BOT = 868;
const alpha = new Float32Array(W * H);

// Chroma, smoothed along the row so a single noisy pixel cannot pass for an
// edge, and the edge test: a step of this size only happens at the silhouette.
const STEP = 11, INSIDE = 15, SOFT = 1.6;
const row = new Float32Array(W);

for (let y = GLASS_TOP; y < GLASS_BOT; y++) {
  for (let x = 0; x < W; x++) {
    let s = 0, n = 0;
    for (let d = -1; d <= 1; d++) {
      const q = x + d;
      if (q < 0 || q >= W) continue;
      s += green(idx(q, y)) * 255; n++;
    }
    row[x] = s / n;
  }
  let lo = -1, hi = -1;
  for (let x = 6; x < W - 6; x++) {
    if (row[x + 4] - row[x - 4] > STEP && row[x + 6] > INSIDE) { lo = x; break; }
  }
  for (let x = W - 7; x > 6; x--) {
    if (row[x - 4] - row[x + 4] > STEP && row[x - 6] > INSIDE) { hi = x; break; }
  }
  if (lo < 0 || hi < 0 || hi - lo < 60) continue;
  for (let x = lo; x <= hi; x++) {
    // Feather only the two pixels either side, so the silhouette stays crisp
    // when this plate is scaled to fill a viewport.
    const edge = Math.min(smoothstep(-SOFT, SOFT, x - lo), smoothstep(-SOFT, SOFT, hi - x));
    alpha[y * W + x] = edge;
  }
}

// The collar is neutral gold, so no chroma step marks its edges. Keying it warm
// finds its lit metal but drops the shaded metal between, so take the span each
// row covers instead of the pixels themselves.
for (let y = COLLAR.y0; y <= COLLAR.y1; y++) {
  let lo = -1, hi = -1;
  for (let x = COLLAR.x0; x <= COLLAR.x1; x++) {
    const i = idx(x, y);
    if (px[i] > 120 && px[i] - px[i + 2] > 24 && luma(i) > 0.42) { if (lo < 0) lo = x; hi = x; }
  }
  if (lo < 0 || hi - lo < 40) continue;
  for (let x = lo; x <= hi; x++) alpha[y * W + x] = 1;
}

// Close the one-row gaps the scan leaves where the silhouette turns horizontal
// - the shoulders and the base - by carrying a row's span onto its neighbours.
for (let pass = 0; pass < 2; pass++) {
  const next = Float32Array.from(alpha);
  for (let y = GLASS_TOP + 1; y < GLASS_BOT - 1; y++) for (let x = 1; x < W - 1; x++) {
    const p = y * W + x;
    if (alpha[p] > 0.5) continue;
    if (alpha[p - W] > 0.5 && alpha[p + W] > 0.5) next[p] = 1;
  }
  alpha.set(next);
}

// --- 2. the printed type, lifted off ---------------------------------------
// White type on a smooth green gradient is the one case where a diffusion fill
// is genuinely invisible: there is no texture to invent, only a gradient to
// continue. The mask is deliberately generous - a half-covered edge pixel left
// behind reads as a ghost of the letter.
const isType = new Uint8Array(W * H);
// Below the collar only: the collar is bright and neutral, so a white-type test
// would mask the metal and fill it in with the glass around it.
const TYPE_TOP = 366;
for (let y = TYPE_TOP; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const p = y * W + x, i = idx(x, y);
    if (alpha[p] < 0.9) continue;
    const white = luma(i) > 0.76 && green(i) < 0.10;
    const red = px[i] - px[i + 1] > 55;
    if (white || red) isType[p] = 1;
  }
}
dilate(isType, 7);

const clean = Float32Array.from(px, (v) => v);
const known = new Uint8Array(W * H);
for (let p = 0; p < W * H; p++) known[p] = alpha[p] > 0.5 && !isType[p] ? 1 : 0;

// Grow the surrounding gradient inward until the type is gone, then relax the
// result so the seams between growth fronts disappear.
for (let pass = 0; pass < 60; pass++) {
  const added = [];
  for (let y = TYPE_TOP; y < H; y++) {
    for (let x = 1; x < W - 1; x++) {
      const p = y * W + x;
      if (known[p] || !isType[p] || alpha[p] < 0.5) continue;
      let r = 0, g = 0, b = 0, n = 0;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        const q = p + dy * W + dx;
        if (!known[q]) continue;
        r += clean[q * 4]; g += clean[q * 4 + 1]; b += clean[q * 4 + 2]; n++;
      }
      if (n < 2) continue;
      added.push(p, r / n, g / n, b / n);
    }
  }
  if (!added.length) break;
  for (let k = 0; k < added.length; k += 4) {
    const p = added[k];
    clean[p * 4] = added[k + 1]; clean[p * 4 + 1] = added[k + 2]; clean[p * 4 + 2] = added[k + 3];
    known[p] = 1;
  }
}
for (let pass = 0; pass < 600; pass++) relax(clean, isType, alpha);

// --- 3. write the plates ---------------------------------------------------
const bodyH = H - BODY_TOP;
const cut = Buffer.alloc(W * bodyH * 4);
const cln = Buffer.alloc(W * bodyH * 4);
for (let y = 0; y < bodyH; y++) {
  for (let x = 0; x < W; x++) {
    const p = (y + BODY_TOP) * W + x, o = (y * W + x) * 4;
    const a = Math.round(Math.min(1, alpha[p]) * 255);
    cut[o] = px[p * 4]; cut[o + 1] = px[p * 4 + 1]; cut[o + 2] = px[p * 4 + 2]; cut[o + 3] = a;
    cln[o] = clean[p * 4]; cln[o + 1] = clean[p * 4 + 1]; cln[o + 2] = clean[p * 4 + 2]; cln[o + 3] = a;
  }
}
const raw = { raw: { width: W, height: bodyH, channels: 4 } };
await sharp(cut, raw).png().toFile(OUT + "bottle-body-cut.png");
await sharp(cln, raw).png().toFile(OUT + "bottle-clean.png");

// --- 4. the sprayer --------------------------------------------------------
// A stem and an actuator, shaded from a column of the collar's own gold. No
// part of this is invented colour: it is the product's metal, reshaped.
const NW = 120, NH = 112;
const ACT = { w: 80, h: 34, r: 11 };   // the actuator the thumb presses
const STEM = { w: 38, top: 30 };       // the tube it rides on
const RING = { w: 52, y: 96, h: 14 };  // the crimped ferrule at the collar

// A column of the collar's own metal, which is the only colour this part uses.
const column = [];
for (let y = COLLAR.y0 + 4; y < COLLAR.y1 - 6; y++) {
  const i = idx(404, y);
  column.push([px[i], px[i + 1], px[i + 2]]);
}
const metal = (f) => column[Math.min(column.length - 1, Math.max(0, Math.round(f * (column.length - 1))))];

const noz = Buffer.alloc(NW * NH * 4);
for (let y = 0; y < NH; y++) {
  for (let x = 0; x < NW; x++) {
    const o = (y * NW + x) * 4;
    const dx = x - NW / 2;

    let half = 0, cover = 0, shade = 1, tone = 0.5;
    if (y < ACT.h) {
      // Rounded rectangle, so the actuator reads as a moulded part rather than
      // the crossbar of a letter T.
      half = ACT.w / 2;
      const ix = Math.max(0, Math.abs(dx) - (half - ACT.r));
      const iy = Math.max(0, ACT.r - y) + Math.max(0, y - (ACT.h - ACT.r * 0.5));
      cover = smoothstep(ACT.r + 0.9, ACT.r - 0.9, Math.hypot(ix, iy) + (ACT.r - Math.min(ACT.r, half)));
      // Seen slightly from above: the top face catches the light, the front
      // falls away into shadow.
      shade = 1.18 - 0.5 * smoothstep(0.25, 1.0, y / ACT.h);
      tone = 0.1 + 0.35 * (y / ACT.h);
    } else if (y >= RING.y) {
      half = RING.w / 2;
      cover = smoothstep(half + 0.9, half - 0.9, Math.abs(dx));
      shade = 1.0;
      tone = 0.86;
    } else {
      half = STEM.w / 2;
      cover = smoothstep(half + 0.9, half - 0.9, Math.abs(dx));
      // Darker just under the actuator, where it sits in its own shadow.
      shade = 0.72 + 0.28 * smoothstep(ACT.h, ACT.h + 26, y);
      tone = 0.45 + 0.4 * ((y - ACT.h) / (RING.y - ACT.h));
    }
    if (cover <= 0.002) continue;

    // Lateral cosine falloff is what turns a flat strip into a cylinder.
    const u = Math.min(1, Math.abs(dx) / Math.max(1, half));
    const round = 0.34 + 0.66 * Math.pow(Math.max(0, 1 - u * u), 0.42);
    // A specular line just left of centre, matching the collar's own highlight.
    const spec = 0.30 * Math.exp(-Math.pow((dx + half * 0.28) / (half * 0.22), 2));

    const src = metal(tone);
    const k = shade * round + spec;
    noz[o] = clamp255(src[0] * k);
    noz[o + 1] = clamp255(src[1] * k);
    noz[o + 2] = clamp255(src[2] * k * 0.93);
    noz[o + 3] = clamp255(255 * cover);
  }
}
await sharp(noz, { raw: { width: NW, height: NH, channels: 4 } }).png().toFile(OUT + "nozzle.png");

// --- diagnostics -----------------------------------------------------------
const dir = process.env.DIAG;
if (dir) {
  await mkdir(dir, { recursive: true });
  const m = Buffer.alloc(W * H * 4);
  for (let p = 0; p < W * H; p++) {
    const a = Math.round(Math.min(1, alpha[p]) * 255);
    m[p * 4] = m[p * 4 + 1] = m[p * 4 + 2] = a; m[p * 4 + 3] = 255;
  }
  await sharp(m, { raw: { width: W, height: H, channels: 4 } }).png().toFile(dir + "/matte.png");
  const t = Buffer.alloc(W * H * 4);
  for (let p = 0; p < W * H; p++) {
    const v = isType[p] ? 255 : 0;
    t[p * 4] = v; t[p * 4 + 1] = v; t[p * 4 + 2] = v; t[p * 4 + 3] = 255;
  }
  await sharp(t, { raw: { width: W, height: H, channels: 4 } }).png().toFile(dir + "/type-mask.png");
  // The cleaned plate over the studio grey, which is how it will be seen.
  await sharp({ create: { width: W, height: bodyH, channels: 4, background: "#e0dedd" } })
    .composite([{ input: cln, raw: { width: W, height: bodyH, channels: 4 } }])
    .png().toFile(dir + "/clean-on-grey.png");
  await sharp({ create: { width: W, height: bodyH, channels: 4, background: "#e0dedd" } })
    .composite([{ input: cut, raw: { width: W, height: bodyH, channels: 4 } }])
    .png().toFile(dir + "/cut-on-grey.png");
  await sharp({ create: { width: NW + 40, height: NH + 40, channels: 4, background: "#e0dedd" } })
    .composite([{ input: noz, raw: { width: NW, height: NH, channels: 4 }, top: 20, left: 20 }])
    .png().toFile(dir + "/nozzle-on-grey.png");
}

const covered = alpha.reduce((n, a) => n + (a > 0.5 ? 1 : 0), 0);
const typed = isType.reduce((n, v) => n + v, 0);
console.log("matte     ", covered, "px", (100 * covered / (W * H)).toFixed(1) + "% of frame");
console.log("type mask ", typed, "px");
console.log("wrote     bottle-body-cut.png, bottle-clean.png, nozzle.png");

function smoothstep(a, b, x) {
  const t = Math.max(0, Math.min(1, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
}
function clamp255(v) { return Math.max(0, Math.min(255, Math.round(v))); }
function dilate(mask, r) {
  for (let pass = 0; pass < r; pass++) {
    const next = Uint8Array.from(mask);
    for (let y = 1; y < H - 1; y++) for (let x = 1; x < W - 1; x++) {
      const p = y * W + x;
      if (mask[p]) continue;
      if (mask[p - 1] || mask[p + 1] || mask[p - W] || mask[p + W]) next[p] = 1;
    }
    mask.set(next);
  }
}
function relax(buf, mask, a) {
  const src = Float32Array.from(buf);
  for (let y = TYPE_TOP + 1; y < H - 1; y++) for (let x = 1; x < W - 1; x++) {
    const p = y * W + x;
    if (!mask[p] || a[p] < 0.5) continue;
    for (let c = 0; c < 3; c++) {
      buf[p * 4 + c] =
        (src[(p - 1) * 4 + c] + src[(p + 1) * 4 + c] + src[(p - W) * 4 + c] + src[(p + W) * 4 + c] + src[p * 4 + c] * 2) / 6;
    }
  }
}
