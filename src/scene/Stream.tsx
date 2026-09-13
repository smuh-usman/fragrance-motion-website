import { forwardRef, useImperativeHandle, useMemo, useRef } from "react";
import * as THREE from "three";

export type StreamHandle = {
  mesh: THREE.Mesh;
  u: Record<string, THREE.IUniform>;
};

/**
 * The pour: what carries the mixed liquid from the neck down into the glass.
 *
 * It is not drawn procedurally. A hand-written column of liquid always reads as
 * shader work, so this samples the same liquid plate the ribbons use - real
 * footage, shot on black with no product in frame - scrolling it downward
 * through a narrow soft-edged column. The plate supplies the texture and the
 * highlights; the column supplies only the shape and the wobble.
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
  uniform float uTime;
  uniform float uHead;     // how far down the stream has reached, 0..1
  uniform float uOpacity;
  varying vec2 vUv;

  void main() {
    // Take a slim strip out of the middle of the plate and run it downward.
    vec2 uv = vec2(0.34 + vUv.x * 0.32, fract(vUv.y * 0.62 + uTime * 0.58));
    vec3 c = texture2D(uMap, uv).rgb;
    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));

    // Two frequencies of sway, so it falls rather than hangs.
    float sway = sin(vUv.y * 15.0 - uTime * 4.4) * 0.055
               + sin(vUv.y * 6.0 + uTime * 2.3) * 0.035;
    float d = abs(vUv.x - 0.5 + sway) / 0.5;
    // Narrows as it falls, the way a real stream draws out under gravity.
    float column = smoothstep(1.0, 0.30, d / mix(1.0, 0.62, vUv.y));

    // The head travels down from the neck; nothing exists ahead of it.
    float head = smoothstep(1.0 - uHead - 0.07, 1.0 - uHead + 0.02, vUv.y);

    float a = clamp(l * 2.7, 0.0, 1.0) * column * head * uOpacity;
    // Unpremultiply, then pull toward the fragrance's own green so the pour and
    // the liquid already in the bottle read as the same substance.
    vec3 rgb = l > 0.02 ? c / max(l, 0.09) * l : c;
    gl_FragColor = vec4(mix(rgb, vec3(0.44, 0.59, 0.33), 0.62), a);
    #include <colorspace_fragment>
  }
`;

export const Stream = forwardRef<
  StreamHandle,
  { map: THREE.Texture; renderOrder?: number }
>(function Stream({ map, renderOrder = 7 }, ref) {
  const mesh = useRef<THREE.Mesh>(null);

  const material = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader,
        fragmentShader,
        transparent: true,
        depthWrite: false,
        depthTest: false,
        uniforms: {
          uMap: { value: map },
          uTime: { value: 0 },
          uHead: { value: 0 },
          uOpacity: { value: 0 },
        },
      }),
    [map],
  );

  useImperativeHandle(
    ref,
    () => ({ mesh: mesh.current as THREE.Mesh, u: material.uniforms }),
    [material],
  );

  return (
    <mesh ref={mesh} material={material} renderOrder={renderOrder}>
      <planeGeometry args={[1, 1]} />
    </mesh>
  );
});
