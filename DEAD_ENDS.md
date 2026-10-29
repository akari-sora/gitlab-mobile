# Dead Ends Log

| Iteration | Approach Tried | Why It Failed | Files Touched |
|-----------|---------------|---------------|---------------|
| 2026-10-29 CI flakes | Reproduce the `pumpUntil` / settle flakes with local load: two looping heavy test files and six CPU burners, with coverage (8 unmodified runs of `read_cache_settings_test.dart`, all passed; 4 more at `taskpolicy -c background` also passed) | A 10-core Mac under that load still finishes native I/O inside the ~1.5 s real budget of 100 `pumpUntil` cycles. Injecting real-time latency (`Isolate.run(() => sleep(...))`) into the harness or fixture reproduces the exact CI messages; use that instead | none committed |
| 2026-10-29 CI flakes | Wait for D4/D6b to settle on "stale line shown and refresh enabled" | With a slow mutation those hold while the Dates save is still in flight (save button shown, disabled); the condition also needs the mutation counted and the editor closed | `test/work_item_dates_parent_integration_test.dart` |
| 2026-10-29 CI flakes | Reproduce the V9 `prepare` 20 s `TimeoutException` (job 17565572197) under load, alone (12 runs) and in file order (6 runs) | Never reproduced; passing CI runs take 0.3-2.3 s, so the failure is a hang, not slowness. Root cause not found; nothing changed for it | none |
