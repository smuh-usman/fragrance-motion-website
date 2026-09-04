# Lens: Security

Layered onto your role for this task. It changes what you pay attention to, not
what you are building.

While working, keep asking: if the caller were hostile, what would they send?

- Does every identifier in a request get checked against *this caller's* right to
  it, rather than merely against the caller being authenticated?
- Is anything that determines permission, eligibility, identity or elapsed time
  taken from client input? It must come from server state.
- Could sending this request twice at the same instant produce a result that
  sending it twice in sequence would not?
- Does the response include any field the caller is not entitled to see, because
  the serializer is broader than the authorization check?
- Do errors or logs reveal credentials, tokens, personal data, or the existence of
  resources the caller should not know about?
- Is anything guessable or expensive here reachable without a rate limit?

Write a test for the hostile case, not only the permitted one. An authorization
check with no test proving the wrong actor is refused is an untested check.
