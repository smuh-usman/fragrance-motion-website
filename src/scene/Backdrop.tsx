import { forwardRef, useImperativeHandle, useMemo, useRef } from "react";
import { useFrame, useThree } from "@react-three/fiber";
import * as THREE from "three";
import { coverScale } from "./cover";

export type BackdropHandle = { material: THREE.ShaderMaterial; mesh: THREE.Mesh };

/**
 * What the contained photograph bleeds into.
 *
 * The same frame, cover-scaled so it always fills the viewport, blurred past
 * legibility and pushed down in contrast. It reads as the light and colour of
 * the place spilling around the edges of the picture rather than as a letterbox
 * or a filler panel, and because it is the frame's own pixels the palette can
 * never disagree with the photograph sitting on top of it.
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
  uniform vec2 uTexel;
  uniform float uOpacity;
  uniform float uExposure;
  uniform float uSaturation;
  uniform float uLift;

  varying vec2 vUv;

  void main() {
    // A wide, cheap blur: two rings of taps at different radii read as a much
    // larger kernel than the tap count would suggest, which is all this needs
    // since nothing here is meant to be legible.
    vec2 r1 = uTexel * 14.0;
    vec2 r2 = uTexel * 30.0;

    vec3 sum = texture2D(uColor, vUv).rgb * 0.20;
    sum += texture2D(uColor, vUv + vec2( r1.x,  0.0)).rgb * 0.10;
    sum += texture2D(uColor, vUv + vec2(-r1.x,  0.0)).rgb * 0.10;
    sum += texture2D(uColor, vUv + vec2( 0.0,  r1.y)).rgb * 0.10;
    sum += texture2D(uColor, vUv + vec2( 0.0, -r1.y)).rgb * 0.10;
    sum += texture2D(uColor, vUv + vec2( r2.x,  r2.y)).rgb * 0.10;
    sum += texture2D(uColor, vUv + vec2(-r2.x,  r2.y)).rgb * 0.10;
    sum += texture2D(uColor, vUv + vec2( r2.x, -r2.y)).rgb * 0.10;
    sum += texture2D(uColor, vUv + vec2(-r2.x, -r2.y)).rgb * 0.10;

    float luma = dot(sum, vec3(0.2126, 0.7152, 0.0722));
    vec3 graded = mix(vec3(luma), sum, uSaturation) * uExposure;

    // Lifted toward light. Unlifted, the blurred foliage that dominates this
    // frame turns the two thirds of the viewport beside a portrait photograph
    // into dark sludge, which reads as a rendering fault rather than as air.
    graded = mix(graded, vec3(1.0), uLift);

    gl_FragColor = vec4(graded, uOpacity);

    // Raw shader materials get no output colour management from three, so a
    // linear value written here lands in a framebuffer that is displayed as
    // sRGB - which renders every photograph in this project about a gamma too
    // dark. Measured on the packshot: the bottle's glass came out at 75,114,65
    // against the source's 148,180,140. The page never gave it away because the
    // clear colour goes through setClearColor, which three does encode.

    #include <colorspace_fragment>
  }
`;

export const Backdrop = forwardRef<
  BackdropHandle,
  { color: THREE.Texture; aspect: number; z?: number }
>(function Backdrop({ color, aspect, z = -1.4 }, ref) {
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
          uTexel: { value: new THREE.Vector2(1 / 1082, 1 / 1440) },
          uOpacity: { value: 0 },
          uExposure: { value: 1.15 },
          uSaturation: { value: 0.45 },
          uLift: { value: 0.45 },
        },
      }),
    [color],
  );

  useImperativeHandle(
    ref,
    () => ({ material, mesh: mesh.current as THREE.Mesh }),
    [material],
  );

  useFrame(() => {
    if (!mesh.current) return;
    const { width, height } = coverScale(
      camera as THREE.PerspectiveCamera,
      z,
      size.width / size.height,
      aspect,
    );
    // Slight overscan so no edge of the blur can ever enter frame.
    mesh.current.scale.set(width * 1.12, height * 1.12, 1);
  });

  return (
    <mesh ref={mesh} position={[0, 0, z]} material={material} renderOrder={-1}>
      <planeGeometry args={[1, 1]} />
    </mesh>
  );
});
