## Summary

Replace type-punning via `*reinterpret_cast<std::uint32_t const *>(&float)` in
`ankerl::unordered_dense::hash<Vector3f>::operator()` with `std::bit_cast`. The
existing code is undefined behaviour under the strict-aliasing rules and breaks
the build under `-Wall -Wextra -Werror` on GCC 13.

## Why

The hash implementation in `library/include/Vector.h` (around line 553) reads
each `float` component of a `Vector3f` by reinterpreting its address as a
`std::uint32_t const *` and dereferencing it:

```cpp
std::uint64_t x = *reinterpret_cast<std::uint32_t const *>(&value.x);
```

This is a strict-aliasing violation: a `std::uint32_t` lvalue is being formed
from storage whose dynamic type is `float`. Any compiler that takes
`-fstrict-aliasing` seriously is allowed to reorder the load against
neighbouring float accesses or to assume the values do not alias.

Concretely, on Ubuntu 24.04 with GCC 13.3.0 and the project's existing
`-Wall -Wextra -Werror`, building `library/include/Vector.h` fails with
`-Werror=strict-aliasing` (`dereferencing type-punned pointer will break
strict-aliasing rules`) once `-O2`/`-O3` is in effect, which is the default
`Release` configuration.

`std::bit_cast` (C++20, `<bit>`) is the standard, portable replacement for
exactly this pattern: it copies the bit representation of the source object
into the destination type without forming an aliasing pointer, the compiler
emits the same single-load instruction, and it is `constexpr`-friendly.

## Fix

- Add `#include <bit>` to `library/include/Vector.h`.
- Replace the three `*reinterpret_cast<std::uint32_t const *>(&value.<x|y|z>)`
  loads with `std::bit_cast<std::uint32_t>(value.<x|y|z>)`.

The hash result is bit-identical for all inputs — `bit_cast` and the previous
type-punning produce the same `uint32_t` representation of the float — so this
is a behaviour-preserving change, not just a warning silencer.

## Testing

- `cmake --build build` on Ubuntu 24.04 / GCC 13.3.0 with the project's
  default flags (`-Wall -Wextra -Werror`, Release): builds without
  `strict-aliasing` warnings.
- The same build on Clang 18 (which does not flag the original code under
  `-Werror`) is unaffected.
- Hashes computed for a representative set of `Vector3f` values match between
  before/after the patch (verified via a one-off harness; can be inlined as a
  test if you want).

## Notes / open questions

- `std::bit_cast` requires C++20. The project already uses C++20 features
  elsewhere (concepts, `<ranges>`, `<format>`-style usage), so this should be
  a no-op for the language standard. If the project ever needs to compile
  under C++17, a `std::memcpy`-based fallback is the standard alternative.
- `std::has_unique_object_representations_v<Vector3f>` is asserted (commented
  out) immediately above the hash. `bit_cast` requires
  `is_trivially_copyable_v<float>`, which holds; the commented assertion is
  unaffected by this patch.
