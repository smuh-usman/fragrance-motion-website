import { forwardRef, useImperativeHandle, useMemo, useRef } from "react";
import { useFrame } from "@react-three/fiber";
import * as THREE from "three";

export type CutoutHandle = {
  mesh: THREE.Mesh;
  u: Record<string, THREE.IUniform>;
};

/**
 * A matted element from the shoot, free to be flown around the scene, and to
 * come apart into the liquid it becomes.
 *
 * Two ways in: `alpha` uses the matte baked into the file, which is how the
 * ingredients arrive; `luma` derives one from a plate shot on black, which is
 * how the liquid does. Additive blending is the usual answer for liquid on
 * black, but it only works over a dark ground - over a near-white studio it adds
 * white to white and blows out to a pale smear. Taking alpha from luminance
 * instead lets the plate keep its real colour on a light page, and here it is
 * exact rather than approximate, because everything in the source that is not
 * liquid is genuinely black.
 *
 * The dissolve is what makes an ingredient become liquid rather than simply
 * stop being there. It erodes the matte along a noise field biased toward the
 * bottom of the cutout, so the thing melts from below, and it lights the moving
 * boundary with the fragrance's own colour, so the last thing seen of a fruit is
 * the liquid it turned into.
 */
const vertexShader = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const fragmentShader = /* glsl */ `
  uniform sampler2D uMap;
  uniform float uOpacity;
  uniform float uGain;      // luma mode: how hard to key
  uniform float uDissolve;  // 0 = whole, 1 = entirely gone to liquid
  uniform float uColorize;  // pulls a keyed plate toward the fragrance's colour
  uniform vec3 uTint;       // the colour the boundary glows
  uniform float uLuma;      // 1 = derive the matte, 0 = use the baked one
  varying vec2 vUv;

  float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
  }

  float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
  }

  void main() {
    vec4 src = texture2D(uMap, vUv);
    float l = dot(src.rgb, vec3(0.2126, 0.7152, 0.0722));

    float keyed = clamp(l * uGain, 0.0, 1.0);
    // Unpremultiply so thin, dark edges keep their hue instead of washing to
    // grey as the derived alpha falls away.
    vec3 lifted = l > 0.01 ? src.rgb / max(l, 0.08) * l : src.rgb;

    float a = mix(src.a, keyed, uLuma);
    vec3 rgb = mix(src.rgb, lifted, uLuma);
    // The liquid plate is near-white at its highlights, which over a light page
    // reads as steam rather than as perfume. Grading it toward the fragrance's
    // own green is what makes it the same substance as what ends up in the
    // bottle.
    rgb = mix(rgb, uTint, uColorize * uLuma);

    if (uDissolve > 0.0) {
      // Two octaves so the break-up has both blobs and grain, weighted toward
      // the bottom edge so it melts downward rather than evaporating evenly.
      float n = noise(vUv * 11.0) * 0.52 + noise(vUv * 29.0) * 0.22
              + (1.0 - vUv.y) * 0.26;
      // The threshold sweeps past both ends of the noise field, so nothing is
      // eroded at zero and nothing survives at one. Sweeping it only as far as
      // the field's own range leaves the cutout whole at full dissolve - and
      // leaves the whole of it lit by the boundary colour, which is a fruit
      // turning green rather than a fruit turning into liquid.
      float d = mix(-0.20, 1.20, uDissolve);
      float keep = smoothstep(d, d + 0.17, n);
      float edge = keep * (1.0 - smoothstep(d + 0.17, d + 0.42, n));
      rgb = mix(rgb, uTint, edge * 0.65);
      a *= keep;
    }

    if (a < 0.004) discard;
    gl_FragColor = vec4(rgb, a * uOpacity);
    #include <colorspace_fragment>
  }
`;

export const Cutout = forwardRef<
  CutoutHandle,
  {
    map: THREE.Texture;
    aspect: number;
    /** Height in world units at scale 1. */
    worldHeight: number;
    /** `alpha` uses the texture's own matte; `luma` derives one from black. */
    mode?: "alpha" | "luma";
    gain?: number;
    colorize?: number;
    tint?: [number, number, number];
    renderOrder?: number;
  }
>(function Cutout(
  {
    map,
    aspect,
    worldHeight,
    mode = "alpha",
    gain = 1.6,
    colorize = 0,
    tint = [0.52, 0.68, 0.38],
    renderOrder = 5,
  },
  ref,
) {
  const mesh = useRef<THREE.Mesh>(null);

  const material = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader,
        fragmentShader,
        transparent: true,
        depthWrite: false,
        depthTest: true,
        uniforms: {
          uMap: { value: map },
          uOpacity: { value: 0 },
          uGain: { value: gain },
          uDissolve: { value: 0 },
          uColorize: { value: colorize },
          uTint: { value: new THREE.Color(...tint) },
          uLuma: { value: mode === "luma" ? 1 : 0 },
        },
      }),
    [map, mode, gain, colorize, tint],
  );

  useImperativeHandle(
    ref,
    () => ({ mesh: mesh.current as THREE.Mesh, u: material.uniforms }),
    [material],
  );

  useFrame(() => {
    if (!mesh.current) return;
    const s = (mesh.current.userData.scale as number) ?? 1;
    // A flat cutout cannot turn edge-on, so a lateral squash stands in for the
    // tumble - which is what the eye actually reads as a piece of fruit
    // revolving rather than sliding.
    const stretch = (mesh.current.userData.stretch as number) ?? 1;
    mesh.current.scale.set(worldHeight * aspect * s * stretch, worldHeight * s, 1);
  });

  return (
    <mesh ref={mesh} material={material} renderOrder={renderOrder}>
      <planeGeometry args={[1, 1]} />
    </mesh>
  );
});
