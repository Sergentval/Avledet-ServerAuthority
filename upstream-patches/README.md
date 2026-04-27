# Avledet upstream-contribution patches

Three independent patches against `crazicrafter1/Avledet@0.221.12`, prepared
during a build/spike of Avledet on Ubuntu 24.04 / GCC 13.3.0. Each patch
solves a distinct issue and can be submitted as its own PR.

| # | Directory                          | Files touched               | Lines | Risk    |
|---|------------------------------------|-----------------------------|-------|---------|
| 1 | `01-bit-cast-vector-h/`            | `library/include/Vector.h`  | +4 / -3 | low (UB fix, behaviour-preserving) |
| 2 | `02-gcc13-warning-suppressions/`   | `library/CMakeLists.txt`    | +4 / -0 | low (build-only, no runtime impact) |
| 3 | `03-tracy-on-demand-default/`      | `library/CMakeLists.txt`    | +5 / -0 | medium (changes profiling default; documented memory-leak fix) |

The three patches are independent and can be applied in any order or
individually. Patches 2 and 3 both touch `library/CMakeLists.txt` but at
non-overlapping hunks.

## Layout

```
upstream-patches/
├── README.md                          # this file
├── 01-bit-cast-vector-h/
│   ├── patch.diff                     # `git apply`-ready unified diff
│   └── PR-DESCRIPTION.md              # ready-to-paste PR body
├── 02-gcc13-warning-suppressions/
│   ├── patch.diff
│   └── PR-DESCRIPTION.md
└── 03-tracy-on-demand-default/
    ├── patch.diff
    └── PR-DESCRIPTION.md
```

## How to apply

From a fresh clone of upstream at the `0.221.12` tag:

```bash
git clone https://github.com/crazicrafter1/Avledet.git
cd Avledet
git checkout 0.221.12

# Apply individually, in any order:
git apply /path/to/upstream-patches/01-bit-cast-vector-h/patch.diff
git apply /path/to/upstream-patches/02-gcc13-warning-suppressions/patch.diff
git apply /path/to/upstream-patches/03-tracy-on-demand-default/patch.diff

# Or all at once:
git apply /path/to/upstream-patches/*/patch.diff
```

To verify cleanly without modifying the working tree:

```bash
git apply --check /path/to/upstream-patches/01-bit-cast-vector-h/patch.diff
```

All three patches have been verified to apply cleanly against a pristine
`0.221.12` checkout via `git apply --check`.

## How to submit

1. For each patch, create a branch from `0.221.12` (or whatever the current
   tip is — re-run `git apply --check` first; rebase the hunk locations if
   the file has drifted).
2. Apply the patch, commit with a message derived from the
   `PR-DESCRIPTION.md` summary line (e.g. `Vector.h: replace
   reinterpret_cast type-pun with std::bit_cast`).
3. Push and open a PR using the corresponding `PR-DESCRIPTION.md` as the PR
   body, verbatim.

## Toolchain context

All patches were prepared and validated under:

- Ubuntu 24.04 LTS
- GCC 13.3.0 (also tested with Clang 18.1.3)
- CMake 3.28.3, Ninja
- vcpkg 2026-04-08 (manifest mode)
- Steamworks SDK 1.62 via `julianxhokaxhiu/SteamworksSDKCI`
