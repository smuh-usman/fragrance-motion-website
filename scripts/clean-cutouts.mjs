/**
 * Removes the debris from the ingredient mattes.
 *
 * These were matted by segmentation, which is excellent on the object and messy
 * around it: a vanilla pod comes back with a handful of stray fragments of the
 * flat-lay still attached, and a low-alpha grey halo along every edge. On a
 * near-white page the halo reads as a grey outline and the fragments read as
 * broken glass drifting beside the fruit.
 *
 * Two passes: drop every connected region that is not a real part of the
 * subject, then pull the remaining alpha away from the middle of its range so
 * edges are either in or out rather than a soft grey rim.
 */
import sharp from "sharp";

const FILES = [
  "pineapple", "grapefruit", "grapefruit-half", "vanilla", "palosanto",
].map((n) => `public/assets/lost-in-kashmir/ingredients/${n}.png`);

const CUT = 0.42;      // what counts as part of the subject
const KEEP = 0.04;     // a region smaller than this share of the largest is debris

for (const file of FILES) {
  let img;
  try {
    img = sharp(file);
    await img.metadata();
  } catch {
    continue;
  }
  const { data, info } = await img.raw().toBuffer({ resolveWithObject: true });
  const { width: W, height: H } = info;
  const n = W * H;

  const solid = new Uint8Array(n);
  for (let p = 0; p < n; p++) solid[p] = data[p * 4 + 3] / 255 > CUT ? 1 : 0;

  // Label the regions, iteratively so a long pod cannot blow the stack.
  const label = new Int32Array(n).fill(-1);
  const sizes = [];
  for (let seed = 0; seed < n; seed++) {
    if (!solid[seed] || label[seed] >= 0) continue;
    const id = sizes.length;
    let size = 0;
    const stack = [seed];
    label[seed] = id;
    while (stack.length) {
      const p = stack.pop();
      size++;
      const x = p % W, y = (p / W) | 0;
      for (const q of [x > 0 ? p - 1 : -1, x < W - 1 ? p + 1 : -1, y > 0 ? p - W : -1, y < H - 1 ? p + W : -1]) {
        if (q < 0 || !solid[q] || label[q] >= 0) continue;
        label[q] = id;
        stack.push(q);
      }
    }
    sizes.push(size);
  }

  const largest = Math.max(...sizes, 1);
  const dropped = sizes.filter((s) => s < largest * KEEP).length;

  const out = Buffer.from(data);
  let cleared = 0;
  for (let p = 0; p < n; p++) {
    const id = label[p];
    if (id >= 0 && sizes[id] >= largest * KEEP) {
      // Push the remaining alpha toward its ends: a segmentation edge that sits
      // at a third of opacity is a grey outline, not a soft edge.
      const a = data[p * 4 + 3] / 255;
      out[p * 4 + 3] = Math.round(255 * Math.min(1, Math.max(0, (a - 0.30) / 0.45)));
    } else {
      out[p * 4 + 3] = 0;
      if (data[p * 4 + 3] > 8) cleared++;
    }
  }

  await sharp(out, { raw: { width: W, height: H, channels: 4 } }).png().toFile(file + ".tmp");
  await sharp(file + ".tmp").toFile(file);
  console.log(
    file.split("/").pop().padEnd(20),
    sizes.length + " regions,", dropped, "dropped,", cleared, "px cleared",
  );
}
