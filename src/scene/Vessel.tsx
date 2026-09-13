import { forwardRef, useImperativeHandle, useMemo, useRef } from "react";
import * as THREE from "three";
import { BOTTLE, plateV } from "./bottle";

export type VesselHandle = {
  mesh: THREE.Mesh;
  u: Record<string, THREE.IUniform>;
};

/**
 * The bottle behind the cover: the same glass, empty, filling.
 *
 * There is no photograph of this bottle empty, and inventing one would mean
 * regenerating the product. So it is derived instead, from the real packshot
 * with its printed type lifted off by a harmonic fill.
 *
 * The empty state is written as transparency rather than as colour. Grading the
 * plate toward grey only ever produces a grey card in the shape of a bottle -
 * tried both too light and too dark, and both read as card - because what makes
 * glass look like glass is that it is mostly the thing behind it. So the plate's
 * own luminance is used to say where there is glass to see: the silhouette,
 * where the light path is longest, the specular highlights, and the darker
 * facets. Everywhere else the page shows through.
 *
 * What comes back as the liquid rises is not a tint but the original
 * photographed pixels, so a full bottle is the packshot and nothing else.
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
  uniform vec3 uGround;     // the page colour, which is the studio sweep
  uniform float uSurface;   // the liquid surface, in texture coordinates
  uniform float uBodyTop;   // where the glass ends and the neck begins
  uniform float uFilling;   // 1 while liquid is moving, for the meniscus
  uniform float uOpacity;
  uniform float uTime;
  uniform float uMeanLuma;  // the glass's own average, so the grade is centred

  varying vec2 vUv;

  void main() {
    vec4 src = texture2D(uMap, vUv);
    if (src.a < 0.01) discard;

    float l = dot(src.rgb, vec3(0.2126, 0.7152, 0.0722));
    float rel = l / uMeanLuma;

    // What you see of an empty bottle is not a surface, it is the edges where
    // the light path through the glass is longest, the highlights, and the
    // darker facets. Everywhere else it is simply the page behind it. Grading
    // the plate to a colour can only ever produce a card of that colour, so the
    // empty state is written as transparency instead, and the shape survives
    // because the photograph's own luminance says where the glass is thick.
    float rim = 1.0 - min(
      min(texture2D(uMap, vUv + vec2(-0.010, 0.0)).a, texture2D(uMap, vUv + vec2(0.010, 0.0)).a),
      min(texture2D(uMap, vUv + vec2(0.0, -0.014)).a, texture2D(uMap, vUv + vec2(0.0, 0.014)).a));
    // Thresholds taken off the plate's own distribution: the glass runs 0.54 to
    // 1.60 of its mean, with the middle half inside 0.70 to 1.31. The dark
    // response is deliberately narrow, because most of what is dark in the
    // photograph is dark from green glass absorbing light rather than from the
    // shape of the bottle - read literally it turns the whole front panel into
    // a grey card, which is the one thing an empty bottle must not look like.
    float spec = smoothstep(1.15, 1.45, rel);
    float shade = smoothstep(0.78, 0.55, rel);
    float glassA = clamp(0.13 + rim * 0.78 + spec * 0.62 + shade * 0.46, 0.0, 1.0);
    // The highlight stays a tint of the page rather than going pure white: at
    // the moment the cover first parts, the slit lands exactly on the bottle's
    // brightest specular, and pure white there reads as a bar of light laid
    // across the label.
    vec3 glassC = mix(uGround * 0.62, uGround * 1.34, spec);

    // The surface is never perfectly flat while it is moving.
    float wob = sin(vUv.x * 13.0 + uTime * 1.7) * 0.0032 * uFilling;
    float below = smoothstep(uSurface + 0.005, uSurface - 0.005, vUv.y + wob);

    // Below the surface the photographed pixels come back exactly as they are,
    // so a full bottle is the packshot rather than a tint of it.
    vec3 shown = mix(glassC, src.rgb, below);
    float a = mix(glassA, 1.0, below);

    // The neck is metal and geometry, not liquid, and has to look the same at
    // every level - it is also what the cover's top edge meets, so any change
    // there would show as a seam across a closed bottle.
    float isBody = smoothstep(uBodyTop + 0.015, uBodyTop - 0.008, vUv.y);
    shown = mix(src.rgb, shown, isBody);
    a = mix(1.0, a, isBody);

    // The meniscus: a bright line where the liquid meets the glass, present
    // only while there is a surface to catch the light.
    float edge = exp(-pow((vUv.y + wob - uSurface) / 0.007, 2.0));
    float visible = step(0.004, uSurface - ${plateV(BOTTLE.level.empty).toFixed(4)});
    shown += vec3(0.76, 0.95, 0.66) * edge * isBody * visible * 0.30;
    a = max(a, edge * isBody * visible * 0.7);

    gl_FragColor = vec4(shown, a * src.a * uOpacity);

    #include <colorspace_fragment>
  }
`;

export const Vessel = forwardRef<
  VesselHandle,
  {
    map: THREE.Texture;
    ground: THREE.Color;
    /** World size of the whole plate, so it registers with the cover. */
    width: number;
    height: number;
    z?: number;
    renderOrder?: number;
  }
>(function Vessel({ map, ground, width, height, z = 0, renderOrder = 2 }, ref) {
  const mesh = useRef<THREE.Mesh>(null);

  const material = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader,
        fragmentShader,
        transparent: true,
        // The cover swings toward the viewer, so it is always in front and
        // nothing here needs to sort in three dimensions. Leaving depth alone
        // also lets an ingredient passing behind an empty bottle show faintly
        // through it, which is what glass does.
        depthWrite: false,
        depthTest: true,
        uniforms: {
          uMap: { value: map },
          uGround: { value: ground },
          uSurface: { value: plateV(BOTTLE.level.empty) },
          uBodyTop: { value: plateV(BOTTLE.glass.y0) },
          uFilling: { value: 0 },
          uOpacity: { value: 1 },
          uTime: { value: 0 },
          // Measured off the glass in bottle-clean.png, not guessed: the grade
          // is centred on this, so a value that is off shifts the whole vessel
          // toward white or toward black.
          uMeanLuma: { value: 0.571 },
        },
      }),
    [map, ground],
  );

  useImperativeHandle(
    ref,
    () => ({ mesh: mesh.current as THREE.Mesh, u: material.uniforms }),
    [material],
  );

  return (
    <mesh
      ref={mesh}
      position={[0, 0, z]}
      scale={[width, height, 1]}
      material={material}
      renderOrder={renderOrder}
    >
      <planeGeometry args={[1, 1]} />
    </mesh>
  );
});
