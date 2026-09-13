import { forwardRef, useImperativeHandle, useMemo, useRef } from "react";
import { useFrame, useThree } from "@react-three/fiber";
import * as THREE from "three";

export type FlatPlaneHandle = {
  material: THREE.ShaderMaterial;
  mesh: THREE.Mesh;
};

/**
 * The product plate, shown exactly as photographed.
 *
 * No displacement, no distortion, no depth trickery: the bottle is the one
 * thing on this page that must stay pristine and readable, so it is a flat
 * quad carrying the original pixels, sized to fit rather than cover so nothing
 * of the bottle is ever cropped away.
 *
 * The packshot has to sit in the page without showing its own rectangle, and a
 * colour key cannot do that here: the faceted cap is white on a near-white
 * studio sweep, so any key tight enough to remove the background also eats the
 * cap. Instead the page is painted the packshot's own background colour and the
 * plane's edges are feathered, which leaves the studio sweep reading as page
 * lighting and never touches a single pixel of the product.
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
  uniform float uFeather;  // how far in from the edge the plate dissolves
  uniform float uOpacity;
  uniform float uExposure;
  uniform float uDeepen;   // 0 = as photographed, 1 = filled with fragrance
  uniform float uTopFade;  // dissolves the cropped top edge into the page

  varying vec2 vUv;

  void main() {
    vec4 color = texture2D(uColor, vUv);

    // The fill, done inside the bottle's own pixels. Only green-dominant
    // pixels deepen, which is the glass and nothing else: the white lettering,
    // the red monogram and the gold collar all sit at or below zero greenness
    // and come through the grade untouched. No geometry and no type is altered,
    // the liquid simply gains body.
    float greenness = color.g - max(color.r, color.b);
    float isGlass = smoothstep(0.005, 0.07, greenness);
    vec3 richer = color.rgb * vec3(0.70, 0.87, 0.60);
    vec3 graded = mix(color.rgb, richer, uDeepen * isGlass);

    vec2 edge = smoothstep(vec2(0.0), vec2(uFeather), vUv) *
                smoothstep(vec2(0.0), vec2(uFeather), 1.0 - vUv);

    // The plate is cropped at the collar, so its top edge is a cut rather than
    // a real boundary and has to dissolve rather than end.
    float top = uTopFade > 0.0 ? smoothstep(1.0, 1.0 - uTopFade, vUv.y) : 1.0;

    gl_FragColor = vec4(graded * uExposure, color.a * edge.x * edge.y * top * uOpacity);

    #include <colorspace_fragment>
  }
`;

export const FlatPlane = forwardRef<
  FlatPlaneHandle,
  {
    color: THREE.Texture;
    aspect: number;
    /** Fraction of viewport height the plate occupies. */
    heightFraction?: number;
    feather?: number;
    topFade?: number;
    z?: number;
    blending?: THREE.Blending;
    /** Fit to this exact world height instead of a viewport fraction. */
    worldHeight?: number;
  }
>(function FlatPlane(
  {
    color,
    aspect,
    heightFraction = 0.72,
    feather = 0.1,
    topFade = 0,
    z = 0,
    blending = THREE.NormalBlending,
    worldHeight,
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
        blending,
        uniforms: {
          uColor: { value: color },
          uFeather: { value: feather },
          uOpacity: { value: 1 },
          uExposure: { value: 1 },
          uDeepen: { value: 0 },
          uTopFade: { value: topFade },
        },
      }),
    [color, feather, topFade, blending],
  );

  useImperativeHandle(
    ref,
    () => ({ material, mesh: mesh.current as THREE.Mesh }),
    [material],
  );

  useFrame(() => {
    if (!mesh.current) return;
    const cam = camera as THREE.PerspectiveCamera;
    const distance = Math.abs(cam.position.z - (mesh.current.position.z || z));
    const visibleHeight =
      2 * Math.tan((cam.fov * Math.PI) / 180 / 2) * distance;
    const visibleWidth = visibleHeight * (size.width / size.height);

    if (worldHeight !== undefined) {
      mesh.current.scale.set(worldHeight * aspect, worldHeight, 1);
      return;
    }

    // Fit, not cover: the whole bottle is always in frame.
    let height = visibleHeight * heightFraction;
    let width = height * aspect;
    const maxWidth = visibleWidth * 0.86;
    if (width > maxWidth) {
      width = maxWidth;
      height = width / aspect;
    }
    mesh.current.scale.set(width, height, 1);
  });

  return (
    <mesh ref={mesh} position={[0, 0, z]} material={material}>
      <planeGeometry args={[1, 1]} />
    </mesh>
  );
});
