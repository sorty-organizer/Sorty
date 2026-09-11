# Sorty's InjectionLite copy

Source: https://github.com/johnno1962/InjectionLite

Revision: `20dd8459d058a6012ea156eecdeef586260ad90d`, the InjectionNext 2.0.1
submodule revision previously pinned in Sorty's package manifest. The upstream
license and source headers are retained.

Sorty changes the file-watcher callback to drain saved paths through
`PendingInjections`. Waiting for the linker can pump the watcher's run loop and
deliver another save while `InjectionLite.inject` holds its `os_unfair_lock`.
The pending list prevents recursive injection and keeps one pending entry per
file. A file saved again during its own injection gets another pass after the
current injection finishes. Processing stays on the original watcher run loop.

`PendingInjectionsTests` covers nested run-loop saves, coalescing, save order,
and later batches. Keep this patch when updating the vendored revision until
upstream provides equivalent protection.

The runtime remains linked only when `SORTY_HOT_RELOAD=true`.
