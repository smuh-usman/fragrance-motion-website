/**
 * Monocular depth map generation for the 2.5D campaign-photo scenes.
 *
 * Runs Depth Anything V2 (small, ONNX) locally through Transformers.js so the
 * pipeline stays inside the Node toolchain: no Python, no torch.
 *
 *   node scripts/depth.mjs public/assets/lost-in-kashmir/campaign.jpg
 *
 * Writes <name>-depth.png beside the source: 8-bit grayscale, white = near,
 * black = far, matched to the source resolution so the shader can sample it
 * with the same UVs as the colour plate.
 */
import { RawImage, pipeline } from "@huggingface/transformers";
import { dirname, extname, join, basename } from "node:path";

const inputs = process.argv.slice(2);
if (inputs.length === 0) {
  console.error("usage: node scripts/depth.mjs <image> [image...]");
  process.exit(1);
}

console.log("loading depth-anything-v2-small (first run downloads ~100MB)...");
const estimate = await pipeline(
  "depth-estimation",
  "onnx-community/depth-anything-v2-small",
  { dtype: "fp32" },
);

for (const input of inputs) {
  const source = await RawImage.read(input);
  console.log(`${input}: ${source.width}x${source.height}`);

  const { depth } = await estimate(source);

  // The model runs at its own working resolution; resample back so depth and
  // colour share one UV space.
  const matched =
    depth.width === source.width && depth.height === source.height
      ? depth
      : await depth.resize(source.width, source.height);

  const out = join(
    dirname(input),
    `${basename(input, extname(input))}-depth.png`,
  );
  await matched.save(out);
  console.log(`  -> ${out}`);
}
