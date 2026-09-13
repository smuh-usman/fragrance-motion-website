import { forwardRef, useImperativeHandle, useMemo, useRef } from "react";
import { useFrame, useThree } from "@react-three/fiber";
import * as THREE from "three";

export type KeyedPlaneHandle = {
  material: THREE.ShaderMaterial;
  mesh: THREE.Mesh;
};

/**
 * A foreground element cropped straight out of the campaign photography.
 *
 * The leaf that sweeps past the lens and the citrus that swells into a macro
 * field are both real pixels from the shoot, not generated stand-ins. They need
 * an alpha channel the source JPEG does not have, so it is derived here:
 *
 *   foliage - keyed on green dominance, g - max(r, b). Leaves are the only
 *             thing in this photograph where green beats both other channels:
 *             blue sky goes negative on b, tan wicker and pale stone go
 *             negative on r. A luma key cannot do this, because the leaves
 *             span from sunlit-bright to shadow-dark and overlap every other
 *             surface in the frame on brightness alone.
 *   oval    - a feathered ellipse, for elements like the citrus macro that
 *             fill their crop and only need their rectangle edges hidden
 *
 * Both feather generously. These elements travel fast and close to the lens,
 * where a soft edge reads as focus falloff rather than as a bad matte.
 */
const vertexShader = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const fragmentShader = /* glsl */ `
  uniform sampler2D uColor;
  uniform float uMode;      // 0 = foliage key, 1 = oval mask
  uniform float uThreshold; // green dominance required to keep a pixel
  uniform float uSoftness;
  uniform float uFeather;   // rectangle-edge feather, in uv
  uniform float uOpacity;
  uniform float uExposure;

  varying vec2 vUv;

  void main() {
    vec4 color = texture2D(uColor, vUv);

    float alpha = 1.0;

    if (uMode < 0.5) {
      float greenness = color.g - max(color.r, color.b);
      alpha = smoothstep(uThreshold - uSoftness, uThreshold + uSoftness, greenness);
    } else if (uMode > 1.5) {
      // The asset carries its own matte, baked offline. A key derived live in
      // the shader always leaves fringe around a rectangular crop; a baked
      // channel can be cleaned, choked and softened once, in advance.
      alpha = color.a;
    } else {
      vec2 c = (vUv - 0.5) * 2.0;
      float r = length(c);
      alpha = 1.0 - smoothstep(1.0 - uFeather * 2.0, 1.0, r);
    }

    // Never let the crop's own rectangle edge become a visible hard line.
    vec2 edge = smoothstep(vec2(0.0), vec2(uFeather), vUv) *
                smoothstep(vec2(0.0), vec2(uFeather), 1.0 - vUv);
    alpha *= edge.x * edge.y;

    gl_FragColor = vec4(color.rgb * uExposure, alpha * uOpacity);

    #include <colorspace_fragment>
  }
`;

export const KeyedPlane = forwardRef<
  KeyedPlaneHandle,
  {
    color: THREE.Texture;
    aspect: number;
    mode?: "foliage" | "oval" | "alpha";
    threshold?: number;
    softness?: number;
    feather?: number;
    /** Fraction of viewport height at scale 1. */
    heightFraction?: number;
    position?: [number, number, number];
  }
>(function KeyedPlane(
  {
    color,
    aspect,
    mode = "foliage",
    // Green dominance is a small quantity: even a vivid sunlit leaf only clears
    // its nearest channel by around 0.15, and a shadowed one by 0.03. The
    // threshold lives down here, not up in luma territory.
    threshold = 0.045,
    softness = 0.035,
    feather = 0.14,
    heightFraction = 1,
    position = [0, 0, 0],
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
        depthWrite: false,
        uniforms: {
          uColor: { value: color },
          uMode: { value: mode === "foliage" ? 0 : mode === "oval" ? 1 : 2 },
          uThreshold: { value: threshold },
          uSoftness: { value: softness },
          uFeather: { value: feather },
          uOpacity: { value: 0 },
          uExposure: { value: 1 },
        },
      }),
    [color, mode, threshold, softness, feather],
  );

  useImperativeHandle(
    ref,
    () => ({ material, mesh: mesh.current as THREE.Mesh }),
    [material],
  );

  const base = useRef({ width: 1, height: 1 });

  useFrame(() => {
    if (!mesh.current) return;
    const cam = camera as THREE.PerspectiveCamera;
    const distance = Math.abs(cam.position.z - mesh.current.position.z);
    const visibleHeight =
      2 * Math.tan((cam.fov * Math.PI) / 180 / 2) * distance;

    base.current.height = visibleHeight * heightFraction;
    base.current.width = base.current.height * aspect;

    // Scale is driven by the act timeline, so only the base size is set here.
    const s = mesh.current.userData.scale ?? 1;
    mesh.current.scale.set(
      base.current.width * s,
      base.current.height * s,
      1,
    );
    void size;
  });

  return (
    <mesh ref={mesh} position={position} material={material} renderOrder={10}>
      <planeGeometry args={[1, 1]} />
    </mesh>
  );
});
