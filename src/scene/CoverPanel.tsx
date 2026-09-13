import { forwardRef, useImperativeHandle, useMemo, useRef } from "react";
import * as THREE from "three";

export type CoverHandle = {
  mesh: THREE.Mesh;
  u: Record<string, THREE.IUniform>;
};

/**
 * One half of the printed cover, hinged at the bottle's own edge.
 *
 * The cover is not a new graphic. It is the packshot's glass body, cut down the
 * centre of the bottle at u = 0.5 - which measurement puts exactly on the axis
 * of the bottle, not merely near it - and each half pivoted about the silhouette
 * edge it already occupies. So the type, the monogram and the moulding are the
 * photographed pixels throughout: they are carried, never redrawn, and when the
 * halves shut the two rejoin into the original frame.
 *
 * They open toward the viewer rather than away. Swinging back would bury most of
 * each half behind the bottle standing between them, and the reveal would read
 * as the cover vanishing rather than as the cover opening.
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
  uniform vec2 uUvMin;
  uniform vec2 uUvMax;
  uniform float uShade;    // the face turning out of the key light
  uniform float uOpacity;
  varying vec2 vUv;

  void main() {
    vec4 c = texture2D(uMap, mix(uUvMin, uUvMax, vUv));
    if (c.a < 0.02) discard;
    gl_FragColor = vec4(c.rgb * uShade, c.a * uOpacity);
    #include <colorspace_fragment>
  }
`;

export const CoverHalf = forwardRef<
  CoverHandle,
  {
    map: THREE.Texture;
    /** -1 hinges on the bottle's left edge, +1 on its right. */
    side: -1 | 1;
    /** The half's world size: half the glass width, the full glass height. */
    width: number;
    height: number;
    /** The texture rectangle this half covers. */
    uvMin: [number, number];
    uvMax: [number, number];
    renderOrder?: number;
  }
>(function CoverHalf(
  { map, side, width, height, uvMin, uvMax, renderOrder = 4 },
  ref,
) {
  const mesh = useRef<THREE.Mesh>(null);

  // The pivot has to sit on the hinge, so the quad is built extending inward
  // from its own origin rather than centred on it.
  const geometry = useMemo(() => {
    const g = new THREE.PlaneGeometry(1, 1);
    g.translate(-side * 0.5, 0, 0);
    return g;
  }, [side]);

  const material = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader,
        fragmentShader,
        transparent: true,
        depthWrite: false,
        depthTest: true,
        // A half turned past square still has to be drawn; without this it
        // would blink out at the top of its swing.
        side: THREE.DoubleSide,
        uniforms: {
          uMap: { value: map },
          uUvMin: { value: new THREE.Vector2(...uvMin) },
          uUvMax: { value: new THREE.Vector2(...uvMax) },
          uShade: { value: 1 },
          uOpacity: { value: 1 },
        },
      }),
    [map, uvMin, uvMax],
  );

  useImperativeHandle(
    ref,
    () => ({ mesh: mesh.current as THREE.Mesh, u: material.uniforms }),
    [material],
  );

  return (
    <mesh
      ref={mesh}
      geometry={geometry}
      material={material}
      scale={[width, height, 1]}
      renderOrder={renderOrder}
    />
  );
});
