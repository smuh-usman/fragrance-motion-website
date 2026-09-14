import { useState } from "react";

type Image = {
  src: string;
  alt: string;
  width: number;
  height: number;
};

const IMAGES: Image[] = [
  {
    src: "/assets/lost-in-kashmir/product/gallery-1.png",
    alt: "Lost in Kashmir extrait de parfum, 100 ml bottle",
    width: 1080,
    height: 1080,
  },
  {
    src: "/assets/lost-in-kashmir/product/gallery-2.png",
    alt: "Lost in Kashmir extrait de parfum, 50 ml bottle",
    width: 1080,
    height: 1080,
  },
  {
    src: "/assets/lost-in-kashmir/product/gallery-3.png",
    alt: "Lost in Kashmir bottle standing beside its presentation box",
    width: 1800,
    height: 1800,
  },
  {
    src: "/assets/lost-in-kashmir/product/gallery-4.png",
    alt: "Lost in Kashmir bottle and box, second view",
    width: 1800,
    height: 1800,
  },
];

/**
 * The product gallery. One main image with the four views beneath it; picking a
 * view swaps the main image. The selected view is carried by `aria-pressed` as
 * well as its border, so the state is not a colour and not a shape alone.
 */
export function Gallery() {
  const [active, setActive] = useState(0);
  const image = IMAGES[active];

  return (
    <section className="gallery" aria-label="Product gallery">
      <figure className="gallery__stage">
        <img
          className="gallery__image"
          src={image.src}
          alt={image.alt}
          width={image.width}
          height={image.height}
        />
      </figure>

      <ul className="gallery__thumbs">
        {IMAGES.map((item, index) => (
          <li key={item.src}>
            <button
              type="button"
              className="gallery__thumb"
              aria-pressed={index === active}
              aria-label={`Show view ${index + 1}: ${item.alt}`}
              onClick={() => setActive(index)}
            >
              <img src={item.src} alt="" width={item.width} height={item.height} />
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}
