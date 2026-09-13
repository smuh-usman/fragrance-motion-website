import { forwardRef, useImperativeHandle, useMemo, useRef } from "react";
import { useFrame, useThree } from "@react-three/fiber";
import * as THREE from "three";
import { containScale, coverScale } from "./cover";

/**
 * A photograph rebuilt as shallow geometry, kept alive by its own edges.
 *
 * The colour source is the untouched campaign still: full resolution, real
 * bottle, real label. Motion arrives as environment plates blended back in at
 * the exact UV rectangles they were cropped from, so the generated pixels only
 * ever land on foliage, water and shadow, and never on the product. One mesh,
 * one draw, and the overlays inherit the same depth displacement as the frame
 * they belong to.
 *
 * Displacement is deliberately shallow: enough that foreground leaves, the
 * bottle, the ocean and the cliffs travel at different speeds, not enough to
 * tear the photograph open at its depth discontinuities and show the trick.
 */
const vertexShader = /* glsl */ `
  uniform sampler2D uDepth;
  uniform float uDepthScale;
  uniform vec2 uTexel;

  varying vec2 vUv;
  varying float vDepth;

  // Five taps across the depth map. A hard depth edge is what produces the
  // rubber-sheet stretch between a near leaf and far sky; softening the sample
  // trades a little crispness for an edge that reads as shallow focus.
  float sampleDepth(vec2 uv) {
    float d  = texture2D(uDepth, uv).r * 0.40;
    d += texture2D(uDepth, uv + vec2(uTexel.x, 0.0)).r * 0.15;
    d += texture2D(uDepth, uv - vec2(uTexel.x, 0.0)).r * 0.15;
    d += texture2D(uDepth, uv + vec2(0.0, uTexel.y)).r * 0.15;
    d += texture2D(uDepth, uv - vec2(0.0, uTexel.y)).r * 0.15;
    return d;
  }

  void main() {
    vUv = uv;

    float depth = sampleDepth(uv);
    vDepth = depth;

    // White is near in the depth map, so this pushes the far field back and
    // leaves the near field forward, around an undisplaced mid ground.
    vec3 displaced = position;
    displaced.z += (depth - 0.5) * uDepthScale;

    gl_Position = projectionMatrix * modelViewMatrix * vec4(displaced, 1.0);
  }
`;

const fragmentShader = /* glsl */ `
  uniform sampler2D uColor;

  // Environment plates. Each carries the UV rectangle of the still it was cut
  // from, as (u0, v0, u1, v1), so it lands back exactly where it came from.
  uniform sampler2D uPlateA;
  uniform vec4 uRectA;
  uniform float uMixA;
  uniform float uFeatherA;

  uniform sampler2D uPlateB;
  uniform vec4 uRectB;
  uniform float uMixB;
  uniform float uFeatherB;

  uniform float uOpacity;
  uniform float uExposure;
  uniform float uFocus;      // the depth the virtual lens is focused on
  uniform float uBlurAmount; // 0 keeps the whole photograph sharp
  uniform float uEdge;       // how far in from the border the frame dissolves
  uniform vec2 uTexel;

  varying vec2 vUv;
  varying float vDepth;

  vec3 blendPlate(vec3 base, sampler2D plate, vec4 rect, float amount, float feather) {
    if (amount < 0.001) return base;

    vec2 local = (vUv - rect.xy) / (rect.zw - rect.xy);
    if (local.x < 0.0 || local.x > 1.0 || local.y < 0.0 || local.y > 1.0) return base;

    // Feathered on all four sides so the plate dissolves into the still rather
    // than announcing its rectangle.
    vec2 edge = smoothstep(vec2(0.0), vec2(feather), local) *
                smoothstep(vec2(0.0), vec2(feather), 1.0 - local);

    vec3 moving = texture2D(plate, local).rgb;
    return mix(base, moving, edge.x * edge.y * amount);
  }

  void main() {
    vec4 color = texture2D(uColor, vUv);

    // Depth of field, used only while a transition is running, so the campaign
    // photography stays pristine whenever the viewer is actually reading it.
    float defocus = clamp(abs(vDepth - uFocus) * uBlurAmount, 0.0, 1.0);
    if (defocus > 0.001) {
      vec2 r = uTexel * defocus * 6.0;
      vec4 blurred = color;
      blurred += texture2D(uColor, vUv + vec2( r.x,  r.y));
      blurred += texture2D(uColor, vUv + vec2(-r.x,  r.y));
      blurred += texture2D(uColor, vUv + vec2( r.x, -r.y));
      blurred += texture2D(uColor, vUv + vec2(-r.x, -r.y));
      color = mix(color, blurred / 5.0, defocus);
    }

    vec3 rgb = color.rgb;
    rgb = blendPlate(rgb, uPlateA, uRectA, uMixA, uFeatherA);
    rgb = blendPlate(rgb, uPlateB, uRectB, uMixB, uFeatherB);

    // Displacing a flat grid in Z leaves a ragged silhouette at the plane's own
    // border, where neighbouring vertices sit at very different depths. Covered
    // framing hides that off-screen; contained framing does not, and it reads
    // as the photograph being torn. Dissolving the border makes the frame end
    // in air instead of in a jagged edge.
    vec2 edge = smoothstep(vec2(0.0), vec2(uEdge), vUv) *
                smoothstep(vec2(0.0), vec2(uEdge), 1.0 - vUv);

    gl_FragColor = vec4(rgb * uExposure, color.a * uOpacity * edge.x * edge.y);

    #include <colorspace_fragment>
  }
`;

export type DepthPlaneHandle = {
  material: THREE.ShaderMaterial;
  mesh: THREE.Mesh;
};

/** A plate and the rectangle of the still it was cropped from. */
export type Plate = {
  texture: THREE.Texture | null;
  /** (u0, v0, u1, v1) in the base image's UV space. */
  rect: [number, number, number, number];
  feather?: number;
};

type Props = {
  color: THREE.Texture;
  depth: THREE.Texture;
  /** Aspect ratio of the source photograph. */
  aspect: number;
  depthScale?: number;
  segments?: number;
  /** Distance from camera the plane sits at, in world units. */
  z?: number;
  /**
   * `contain` shows the whole frame, `cover` fills the viewport and crops.
   * Portrait campaign photography is contained: its depth story runs vertically
   * and cropping to a landscape viewport would cut both ends off it.
   */
  fit?: "cover" | "contain";
  /** How much of the viewport a contained frame fills. */
  fill?: number;
  plateA?: Plate;
  plateB?: Plate;
};

const EMPTY = new THREE.Texture();

export const DepthPlane = forwardRef<DepthPlaneHandle, Props>(function DepthPlane(
  {
    color,
    depth,
    aspect,
    depthScale = 0.55,
    segments = 320,
    z = 0,
    fit = "cover",
    fill = 1,
    plateA,
    plateB,
  },
  ref,
) {
  const mesh = useRef<THREE.Mesh>(null);
  const { size, camera } = useThree();

  const material = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader,
        fragmentShader,
        transparent: true,
        uniforms: {
          uColor: { value: color },
          uDepth: { value: depth },
          uDepthScale: { value: depthScale },
          uTexel: { value: new THREE.Vector2(1 / 1082, 1 / 1440) },
          uOpacity: { value: 1 },
          uExposure: { value: 1 },
          uFocus: { value: 0.5 },
          uBlurAmount: { value: 0 },
          uEdge: { value: 0.05 },
          uPlateA: { value: EMPTY },
          uRectA: { value: new THREE.Vector4(0, 0, 1, 1) },
          uMixA: { value: 0 },
          uFeatherA: { value: 0.18 },
          uPlateB: { value: EMPTY },
          uRectB: { value: new THREE.Vector4(0, 0, 1, 1) },
          uMixB: { value: 0 },
          uFeatherB: { value: 0.25 },
        },
      }),
    [color, depth, depthScale],
  );

  useImperativeHandle(
    ref,
    () => ({ material, mesh: mesh.current as THREE.Mesh }),
    [material],
  );

  useFrame(() => {
    if (!mesh.current) return;

    const fitter = fit === "cover" ? coverScale : containScale;
    const { width, height } = fitter(
      camera as THREE.PerspectiveCamera,
      mesh.current.position.z,
      size.width / size.height,
      aspect,
      fill,
    );
    mesh.current.scale.set(width, height, 1);

    // Plates arrive asynchronously: a video texture exists only once decoding
    // has begun, so binding is done per frame rather than at material build.
    bind(material, "A", plateA);
    bind(material, "B", plateB);
  });

  return (
    <mesh ref={mesh} position={[0, 0, z]} material={material}>
      <planeGeometry args={[1, 1, segments, segments]} />
    </mesh>
  );
});

function bind(
  material: THREE.ShaderMaterial,
  slot: "A" | "B",
  plate: Plate | undefined,
) {
  if (!plate?.texture) return;
  const u = material.uniforms;
  if (u[`uPlate${slot}`].value !== plate.texture) {
    u[`uPlate${slot}`].value = plate.texture;
    (u[`uRect${slot}`].value as THREE.Vector4).set(...plate.rect);
    u[`uFeather${slot}`].value = plate.feather ?? 0.18;
  }
}
