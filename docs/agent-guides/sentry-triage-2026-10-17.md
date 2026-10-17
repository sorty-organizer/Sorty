# Sentry triage, 17 October 2026

[SORTY-MACOS-3D, event 6eb2f75342644710bb83c0aa93d73ce9](https://sorty-z1.sentry.io/issues/7797322010/events/6eb2f75342644710bb83c0aa93d73ce9/)
is a handled `organize.generate_plan` failure in production Sorty 1.3.0,
build 20261004162224. At triage, the issue contained one event affecting one
user. No thread was marked crashed. The recorded status was 413, but the event
does not identify the provider, model, batch size, or exact limit.

Sorty uses 413 for provider request-size failures and for locally detected
context/output limits. The adaptive retry policy previously stopped at eight
files and capped splitting at five levels. Limit failures now permit splitting
down to one file, with nine levels available for a 350-file batch. Malformed
responses retain their eight-file cutoff. Cancellation and single-file failures
still propagate; the change does not guarantee recovery when one file or fixed
instructions exceed the model's limits.

Sentry diagnostics now include an allowlisted `limit_hint` derived locally from
the error message: `output`, `context`, `request_size`, or `unknown`. These are
hints, not proof of the provider's cause. No raw provider message is collected.

The existing organization regression now requires recovery through single-file
requests and checks that every file survives the merge exactly once. A diagnostic
test covers fixed hints and private-message exclusion. No local verification was
run, per the repository's instructions for minor changes. The exact production
failure has not been reproduced, and recurrence prevention remains unverified.
