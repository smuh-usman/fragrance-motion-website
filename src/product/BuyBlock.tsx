import { useState } from "react";

const TITLE = "LOST IN KASHMIR";

type Variant = {
  id: string;
  label: string;
  price: string;
};

const VARIANTS: Variant[] = [
  { id: "100ml", label: "100ml", price: "Rs. 9,500.00" },
  { id: "50ml", label: "50ml", price: "Rs. 6,000.00" },
];

/**
 * Price, size and add to cart. This is a static build with no shop behind it,
 * so the button and the size selector are UI state only - selecting a size
 * changes the price shown and nothing is sent anywhere. Both prices stay in
 * the document, one per size, so the choice is readable before it is made.
 */
export function BuyBlock() {
  const [variantId, setVariantId] = useState(VARIANTS[0].id);
  const [added, setAdded] = useState(false);

  const variant = VARIANTS.find((item) => item.id === variantId) ?? VARIANTS[0];

  const select = (id: string) => {
    setVariantId(id);
    setAdded(false);
  };

  return (
    <section className="buy" aria-labelledby="product-title">
      <h1 className="buy__title" id="product-title">
        {TITLE}
      </h1>

      <p className="buy__price">
        <span className="buy__price-label">{variant.label}</span>
        <span className="buy__price-amount">{variant.price}</span>
      </p>

      <fieldset className="buy__variants">
        <legend>Size</legend>
        {VARIANTS.map((item) => (
          <label className="buy__variant" key={item.id}>
            <input
              type="radio"
              name="size"
              value={item.id}
              checked={item.id === variantId}
              onChange={() => select(item.id)}
            />
            <span className="buy__variant-size">{item.label}</span>
            <span className="buy__variant-price">{item.price}</span>
          </label>
        ))}
      </fieldset>

      <p className="buy__status">
        Selling out quick
        <span aria-hidden="true"> 🔥</span>
      </p>

      <ul className="buy__points">
        <li>Swift Nationwide Shipping</li>
        <li>In stock, ready to ship</li>
      </ul>

      <button type="button" className="buy__add" onClick={() => setAdded(true)}>
        Add to cart
      </button>

      <p className="buy__confirm" role="status">
        {added ? `Added ${variant.label} to your cart` : ""}
      </p>
    </section>
  );
}
