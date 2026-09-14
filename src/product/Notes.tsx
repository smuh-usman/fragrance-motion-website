type Note = {
  id: string;
  heading: string;
  value: string;
  description: string;
};

const NOTES: Note[] = [
  {
    id: "top",
    heading: "Top note",
    value: "GIN, LAVENDER, ORANGE BLOSSOM",
    description:
      "A thirst quenching Gin Accord made with Juniper Berries and accentuated by French Lavender and a beautiful juicy citrus Orange Blossom",
  },
  {
    id: "heart",
    heading: "Heart note",
    value: "ORRIS ROOT, JASMINE, CITRUSES AND IRIS FLOWER",
    description:
      "A noble and glorious heart maintains the citrus exuberance from the top notes.",
  },
  {
    id: "base",
    heading: "Base note",
    value: "CINNAMON, TONKA BEANS, MUSK, AMBER",
    description:
      "An aromatic base with oriental facets, both comforting and exciting. Cinnamon and Tonka add a familiar yet profound sweet, spicy magic to an already memorable composition.",
  },
];

const INGREDIENTS =
  "Alcohol, Parfum (Fragrance), Water (Aqua), Farnesol, Benzyl Benzoate, Anisyl Alcohol, Geraniol, Cinnamyl, Eugenol, Essential Oils, Iso-E Super, Linalool, Citronellol, Ethylhexyl Salicylate, BHT.";

/**
 * What is in the bottle and what it smells of. The ingredient declaration is
 * prose and the notes are titled lists, so the note headings are real headings
 * and the note names are read in order rather than being a picture of type.
 */
export function Notes() {
  return (
    <section className="notes" id="notes" aria-labelledby="notes-title">
      <div className="notes__ingredients">
        <h2 className="notes__heading" id="notes-title">
          Ingredients
        </h2>
        <p>{INGREDIENTS}</p>
        <p>
          Concentration: 32%
          <br />
          Intensity: ••••
          <br />
          Extrait De Parfum
        </p>
      </div>

      <h2 className="notes__heading">Olfactive notes</h2>
      <div className="notes__grid">
        {NOTES.map((note) => (
          <article className="notes__item" key={note.id}>
            <h3>{note.heading}</h3>
            <p className="notes__value">{note.value}</p>
            <p className="notes__description">{note.description}</p>
          </article>
        ))}
      </div>
    </section>
  );
}
