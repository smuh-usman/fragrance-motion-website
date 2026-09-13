import { forwardRef, useImperativeHandle, useMemo, useRef } from "react";
import * as THREE from "three";

export type GlowHandle = { material: THREE.ShaderMaterial; mesh: THREE.Mesh };

/**
 * Light, not an object.
 *
 * Two uses, both non-representational, both pure shader so they cost no asset:
 * the green refraction that first bleeds out from behind the bottle glass, and
 * the warm sun that later floods the studio from frame edge as the fragrance
 * world arrives.
 */
const vertexShader = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const fragmentShader = /* glsl */ `
  uniform vec3 uColor;
  uniform float uOpacity;
  uniform float uSoftness;
  uniform vec2 uOrigin;   // where the light comes from, in uv
  uniform float uSpread;

  varying vec2 vUv;

  void main() {
    vec2 d = (vUv - uOrigin);
    float r = length(d) / uSpread;
    float falloff = pow(1.0 - clamp(r, 0.0, 1.0), uSoftness);
    gl_FragColor = vec4(uColor, falloff * uOpacity);
    #include <colorspace_fragment>
  }
`;

export const Glow = forwardRef<
  GlowHandle,
  {
    color: string;
    origin?: [number, number];
    spread?: number;
    softness?: number;
    scale?: number;
    position?: [number, number, number];
    blending?: THREE.Blending;
  }
>(function Glow(
  {
    color,
    origin = [0.5, 0.5],
    spread = 0.7,
    softness = 2.4,
    scale = 6,
    position = [0, 0, -0.6],
    blending = THREE.NormalBlending,
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
        blending,
        uniforms: {
          uColor: { value: new THREE.Color(color) },
          uOpacity: { value: 0 },
          uSoftness: { value: softness },
          uOrigin: { value: new THREE.Vector2(origin[0], origin[1]) },
          uSpread: { value: spread },
        },
      }),
    [color, softness, origin, spread, blending],
  );

  useImperativeHandle(
    ref,
    () => ({ material, mesh: mesh.current as THREE.Mesh }),
    [material],
  );

  return (
    <mesh ref={mesh} position={position} scale={scale} material={material}>
      <planeGeometry args={[1, 1]} />
    </mesh>
  );
});
