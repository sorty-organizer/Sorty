# AI session lifetime

The supplied crash report, incident `DFE6E9DC-D2E1-4E21-8661-6A1CF17D63C8`,
records Sorty 1.3.0 build 2749 aborting on macOS 27.0.1 on 25 October 2026.
The exception stack ends in CFNetwork task creation through
`URLSession.data(for:)`, called by `AISessionManager.runPrewarm`.
The report does not include the Objective-C exception reason.

Source review found that pool replacement, explicit invalidation, and idle
cleanup could call `finishTasksAndInvalidate()` while a caller still held the
returned session. Prewarming also reused that session for fallback requests.
The detached `Task.yield()` before invalidation provided no ordering guarantee.
This is a concrete task-creation race consistent with the supplied stack.
The crash itself has not been reproduced.

`AISessionManager` now returns an `AISession` owner shared by the pool and its
callers. Removing a session from the pool only releases the pool's ownership.
Data and streaming request creation retain that owner through the asynchronous
call. After the last owner releases it, detached cleanup calls
`finishTasksAndInvalidate()`, allowing already-created streaming tasks to finish.
The shared request helper uses the same ownership for AI clients and retries.
Privacy checks and redirect blocking remain in `NetworkPrivacyPolicy`.

```text
Pool removal -> callers retain session -> last caller releases owner
             -> finish active tasks and invalidate
```

Do not restore delayed invalidation as a substitute for ownership. Neither a
scheduler yield nor a fixed grace period bounds when a caller creates its next
request. Any future raw URLSession escape must preserve this lifetime contract.
