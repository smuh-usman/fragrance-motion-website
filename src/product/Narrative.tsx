/**
 * The story, as the shop tells it. Each paragraph is a single string so the
 * copy stays verbatim and greppable; the prose is rendered as real paragraphs
 * so it stays selectable and readable to a screen reader, and the closing note
 * is a real `em` rather than styled type on a div.
 */
const PARAGRAPHS = [
  "What could be more beautiful than losing yourself in a place of pure serenity, where you explore the unknown without any fears?",
  "\"Lost in Kashmir\" embodies the freeing and unencumbered beauty of Kashmir's sun-kissed meadows, plains, and forests. An exuberant top, featuring French Lavender and Gin, coupled with delightful Orange Blossom, radiates the unique energy found only in Kashmir.",
  "As the evening sun sets, flowers bloom, unveiling the elegance of Iris and Jasmine, the noblest of flowers. Citruses maintain the composition's exuberance, creating a sophisticated, satisfying, and irresistibly appealing phase.",
  "When night falls, bonfires light up, and tales unfold. Kashmir warmly embraces, liberating from civility's shackles. The aromatic base, with Cinnamon, Tonka Beans, Rosewood, and Amber, signifies the comforting and inviting essence of Exuberant Kashmir.",
  "Experience the enchantment of \"Lost in Kashmir\" – a fragrance that takes you on a captivating journey through the beauty and exuberance of Kashmir's day and night.",
];

const CLOSING =
  "Imaginary Fragrances captures the soul-stirring exuberance and freedom that Kashmir brings with every single visit. Enjoy the Extrait De Parfum which is as charming and as magical as Kashmir itself.";

export function Narrative() {
  return (
    <section
      className="narrative"
      id="description"
      aria-labelledby="description-title"
    >
      <h2 className="narrative__heading" id="description-title">
        Description
      </h2>
      <div className="narrative__body">
        {PARAGRAPHS.map((paragraph, index) => (
          <p key={index}>{paragraph}</p>
        ))}
        <p>
          <em>{CLOSING}</em>
        </p>
      </div>
    </section>
  );
}
