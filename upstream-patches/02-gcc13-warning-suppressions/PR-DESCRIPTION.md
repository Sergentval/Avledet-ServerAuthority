## Summary

Add four `-Wno-*` flags to the existing GCC warning-suppression block in
`library/CMakeLists.txt` so that the project builds under
`-Wall -Wextra -Werror` on GCC 13. Each suppressed warning is a known
GCC 13 false-positive class with an upstream Bugzilla entry; the project's
own code is unaffected.

## Why

On Ubuntu 24.04 (GCC 13.3.0), a clean `cmake --build build` with the existing
`-Werror` block fails with the following diagnostics, none of which point at
buggy code in this repository:

1. `-Wstringop-overflow=` triggered through `bits/stl_algobase.h:437` while
   compiling code that calls `std::copy` / `std::move` chains with
   `-O2`/`-O3`. In this codebase the canonical reproduction is in
   `library/src/Reader.cpp` (the deserialisation paths). GCC reports a
   `writing N bytes into a region of size 0` error inside libstdc++ headers.
   This is GCC bug
   [PR110501](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=110501) and
   related: stringop-overflow has long been known to misbehave on STL
   algorithm chains under inlining; the GCC team has been disabling it by
   default for `std::vector` since GCC 12.

2. `-Warray-bounds` paired with the same call sites — same root cause as
   above, GCC's value-range propagation incorrectly concludes the destination
   range is empty after inlining. Tracked in GCC PRs
   [99578](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=99578) and
   [109570](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=109570).

3. `-Wrestrict` — false positives on heavily-templated code (sol2 binding
   helpers, range-v3 view pipelines) where GCC believes a `__restrict__`
   pointer is being self-copied through a wrapper object. Tracked in GCC PR
   [105651](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=105651).

4. `-Wdangling-reference` (new in GCC 13) — fires on perfectly-valid
   range-v3 / sol2 idioms that return `const&` to a temporary that the
   caller does not actually keep beyond the full expression. Tracked in GCC
   PR [107532](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=107532); it is
   widely regarded as overly aggressive and is suppressed in many large
   C++20+ codebases (e.g. LLVM, Folly, abseil) for the same reason.

Without these suppressions the project does not build at all on GCC 13 with
its stated warning posture, even on a pristine `0.221.12` checkout. Clang 18
on the same machine builds clean — the issue is GCC-13-specific.

## Fix

Append the following to the existing `target_compile_options(avledet_library
PRIVATE ...)` block (the one already containing `-Wno-unknown-pragmas` etc.):

```cmake
-Wno-stringop-overflow
-Wno-array-bounds
-Wno-restrict
-Wno-dangling-reference
```

Each line carries an inline comment naming the GCC-13-specific class of
false-positive it addresses, so a future maintainer can audit whether the
suppression is still needed once GCC 14 / 15 land.

## Testing

- Build with GCC 13.3.0 on Ubuntu 24.04, `cmake -DCMAKE_BUILD_TYPE=Release`:
  succeeds; previously failed in `Reader.cpp` (and a handful of other
  translation units) on `-Werror=stringop-overflow`.
- Build with Clang 18.1.3 on the same machine: unchanged. Clang does not
  recognise `-Wstringop-overflow` / `-Wdangling-reference`, but `-Wno-*` for
  unknown warnings is silently ignored, so this is portable.
- Build with GCC 12 (Ubuntu 22.04): unchanged — the same `-Wno-*` flags are
  recognised on GCC 12.

## Notes / open questions

- These are all GCC-specific quirks. They do not silence any real warning in
  this project's own code; I confirmed by re-running with each flag removed
  individually and inspecting every diagnostic's source location — all live
  inside libstdc++ headers, range-v3, or sol2.
- If you would prefer to gate them behind a `CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL 13`
  guard rather than apply unconditionally, I am happy to rework the patch
  that way. The current shape matches the style of the existing `-Wno-*`
  block, which is also unconditional.
- A more durable long-term fix would be to bump the project's required GCC
  to 14+ once it is mainstream, since most of these false-positives are
  improved (though not all eliminated) in GCC 14. That is out of scope for
  this PR.
