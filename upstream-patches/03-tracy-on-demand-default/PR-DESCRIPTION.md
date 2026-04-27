## Summary

Make `TRACY_ON_DEMAND` the default for the Avledet library by adding
`target_compile_definitions(avledet_library PUBLIC TRACY_ON_DEMAND)` to
`library/CMakeLists.txt`. Without this, every Avledet build shipped to a
production server with no Tracy GUI ever attached has an unbounded
in-memory event buffer that grows ~28 MB/min during play and OOM-kills the
process within hours. Tracy still works on demand — connecting a Tracy GUI
client to a running server begins recording from that moment, exactly as
before, but no events are buffered when nobody is watching.

## Why

`vcpkg.json` lists `tracy[crash-handler]` as a hard dependency, and
`library/CMakeLists.txt` calls `find_package(Tracy CONFIG REQUIRED)`
unconditionally. vcpkg's `TracyConfig.cmake` propagates `-DTRACY_ENABLE`
through `INTERFACE_COMPILE_DEFINITIONS`, so every `Tracy::TracyClient`-linked
target is built with profiling instrumentation active.

By default (without `TRACY_ON_DEMAND`), Tracy's client begins recording
zone/event/sample data the moment its constructor runs, into an in-memory
ring that only drains when a Tracy GUI tool connects to download it. On a
headless production server this is unbounded.

I confirmed the leak on a clean `0.221.12` build, GCC 13.3.0, Ubuntu 24.04,
single Windows client connecting via direct IP. RSS at 30 s resolution:

| Phase                       | Duration | RSS growth     | Rate          |
|-----------------------------|---------:|---------------:|--------------:|
| Idle, no peer (Tracy ON)    |     90 s |  95 → 117 MB   | **14 MB/min** |
| Player connected, exploring |   10 min | 117 → 401 MB   | **28 MB/min** |
| 90 s after disconnect       |     90 s | 401 → 445 MB   | **22 MB/min** (still growing with zero peers) |

Independent confirmation via `gdb` on the silent process showed Tracy's four
worker threads (`Tracy Sampling`, `Tracy Profiler`, `Tracy DXT1`,
`Tracy Symbol Worker`) alive and the main thread idle in `IAvledet::update()`.
A separate 11-hour run reached **14.6 GB RSS** before I stopped it.

After enabling `TRACY_ON_DEMAND` (and changing nothing else), the same client
walkthrough on the same VPS:

| Phase                       | Duration | RSS growth     | Rate                |
|-----------------------------|---------:|---------------:|--------------------:|
| Idle, no peer               |     90 s |   86 → 86 MB   | **0 MB/min — flat** |
| Player connected, exploring |   8.8 min | 86 → 112 MB    | **0.5 MB/min**      |
| Post-disconnect             |        — |       112 MB   | flat                |

The remaining 0.5 MB/min during play is legitimate ZDO heap growth
(0 → ~20 000 ZDOs over the run; ~250 B per ZDO including unordered-map
bucket overhead = ~5 MB observed delta, which matches the arithmetic).
**Memory growth rate is ~70× lower with this one-line change.**

This is documented behaviour. From the [Tracy
manual](https://github.com/wolfpld/tracy/blob/master/manual/tracy.tex)
(§3.5 *On-demand profiling*):

> By default, the profiled program will start profiling immediately, even
> before the connection from the client is made. […] With on-demand mode
> enabled, the profiled application will wait for a connection from the
> client to be made before it starts profiling.

For a headless game server that may run for days between profiling sessions,
`TRACY_ON_DEMAND` is the correct production default.

## Fix

Append to `library/CMakeLists.txt`, immediately after the existing
`target_link_libraries(avledet_library PUBLIC ... isptr::isptr)` block:

```cmake
# Tracy on-demand: only record profiling events when a Tracy GUI client is
# connected. Without this, Tracy's in-memory event buffer grows unbounded
# (~25 MB/min while a peer is connected, ~15 MB/min idle), which OOM-kills
# a long-running server.
target_compile_definitions(avledet_library PUBLIC TRACY_ON_DEMAND)
```

`PUBLIC` so that downstream targets (the executable and any consumers of
`avledet_library`) inherit the same on-demand behaviour and there is no
Tracy ABI mismatch between TUs.

## Testing

- Long-running soak: run the server idle for 30 min, then connect a client
  for 10 min, then disconnect. RSS should plateau within a few hundred KB.
  Without this patch, RSS climbs continuously.
- Profiling on demand: start the server with this build, then run
  `tracy-profiler` (or `capture`) and connect to the server's Tracy port.
  Events should begin flowing from the moment of connection. Disconnect,
  and recording stops; reconnect, and recording resumes. This matches the
  documented `TRACY_ON_DEMAND` semantics and is what we want for a
  headless server.

## Notes / open questions

- This **changes the default behaviour** of profiling-enabled builds. Anyone
  relying on the current "record everything from process start, even with
  no GUI attached" behaviour — for example, capturing the very first ticks
  of startup before they could realistically attach a GUI — would lose
  that. If you would like to preserve a way to opt back into the old
  behaviour, we could gate the new line on a CMake option, e.g.:

  ```cmake
  option(AVL_TRACY_ON_DEMAND "Defer Tracy recording until a GUI connects" ON)
  if (AVL_TRACY_ON_DEMAND)
      target_compile_definitions(avledet_library PUBLIC TRACY_ON_DEMAND)
  endif()
  ```

  I went with the unconditional form on the assumption that the production
  server use-case dominates and that one-shot profiling-from-startup is
  better served by `TRACY_NO_FRAME_IMAGE` + a manual `TracyMessage(...)`
  marker than by leaving recording on permanently. Happy to switch to the
  guarded form if you prefer.
- `TRACY_ON_DEMAND` is fully compatible with `TRACY_NO_BROADCAST` /
  `TRACY_DELAYED_INIT` and other tuning macros documented in the Tracy
  manual; this PR does not preclude any of them.
- This patch only affects builds where Tracy is enabled. If a future PR
  introduces `AVL_DISABLE_TRACY` or similar, the macro definition becomes
  a no-op and there is nothing to undo.
