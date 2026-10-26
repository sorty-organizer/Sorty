---
name: ponytail
description: Review or implement the simplest complete solution when the user explicitly invokes Ponytail. Does not activate for ordinary coding tasks or persist into later requests.
license: MIT
---

# Ponytail

Apply only to the request that invoked it.

Understand the requested behavior and existing callers before changing code. Reuse an existing implementation, standard library, or native control when it meets the requirement. Prefer the smallest complete change; avoid speculative abstractions, dependencies, and scaffolding.

Preserve requested features, visual behavior, error handling, data safety, and accessibility. A short diff that patches the wrong cause is unfinished. Use checks appropriate to the change and repository instructions; this skill does not impose a separate test framework, artifact, comment convention, or output limit.

For an explicit simplicity review, report concrete unnecessary complexity and the effect of removing it. Implement only within the user's authorized scope. Finish the requested work and report the outcome plainly.
