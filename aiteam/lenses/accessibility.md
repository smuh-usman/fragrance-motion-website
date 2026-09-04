# Lens: Accessibility

Layered onto your role for this task.

- Is the correct semantic element used? A `div` with a click handler is not a
  button and cannot be reached, focused or activated by a keyboard.
- Can everything be done with the keyboard alone, in a sensible order, with focus
  always visible and never trapped?
- Does every input have a programmatically associated label, and every image
  meaningful alternative text — or an empty one when decorative?
- When content changes without a page load — validation errors, loading finishing,
  a countdown reaching a threshold — is that announced, or only shown?
- Is colour ever the only signal? Pair it with text or shape. Check contrast.
- Are motion and timing avoidable for those who need more time or less movement?

Test with the keyboard before declaring this done. It takes a minute and catches
most of what automated checks miss.
