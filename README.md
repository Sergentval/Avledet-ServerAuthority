# Avledet-ServerAuthority

**Goal:** make Valheim multiplayer feel like a real MMO — true server-authoritative simulation, hundreds of concurrent players, thousands of structures, mobs that don't freeze when their owner disconnects.

This is a Lua module suite for [Avledet](https://github.com/crazicrafter1/Avledet), the C++ Valheim dedicated server reimplementation. Where vanilla Valheim's server is mostly a P2P relay (mob AI / combat / physics run on whichever client is closest), this project moves the simulation onto the server.

## Status

Phase 0 — Foundation. Not yet usable. See [ROADMAP.md](docs/ROADMAP.md).

## Why not just use BepInEx mods?

We also maintain [Sergentval/Valheim-serverside](https://github.com/Sergentval/Valheim-serverside) — a C# BepInEx mod that does ZDO ownership transfer in vanilla Valheim's headless server. That works, ships via Thunderstore, and is the right answer for most server admins.

It hits a wall at ~50 concurrent players and ~5–10k structures because Unity's main-thread tick doesn't scale further. This project is the answer to "what if you wanted 200 players and 50k structures."

## Architecture in one paragraph

[Avledet](https://github.com/crazicrafter1/Avledet) replaces Valheim's `valheim_server.x86_64` (Unity-based, ~3 GB RAM at idle) with a pure-C++ binary (~90 MB RAM at idle). Avledet handles networking, ZDO replication, world generation, and persistence. It exposes a [sol2](https://github.com/ThePhD/sol2) Lua API that lets us add behaviours on top — including the AI / combat / pathfinding that Avledet doesn't natively provide. This repo is the suite of Lua modules that, together, make Avledet behave as a server-authoritative MMO instead of a smart relay.

## Repo layout

```
lua/scripts/ServerAuthority/   Lua modules drop-in for Avledet's data/lua/scripts/
docs/                           Design docs, research, decisions
tests/                          Lua test harness
upstream-patches/               Patches we contribute back to Avledet
```

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 0 | Foundation: repo, ServerAuthority Phase 1 ported, Avledet upstream PRs, sustained-run validation | in progress |
| 1 | Stub AI: server-claimed mobs idle-walk instead of freezing | pending |
| 2 | Aggro + chase: mobs detect players, walk toward them. No damage. | pending |
| 3 | Custom pathfinder: A* on Avledet's heightmap | pending |
| 4 | Combat resolution: server-side hit detection + damage | pending |
| 5 | Status effects, stagger, knockback, ragdoll | pending |
| 6 | Per-mob configs: every creature behaves like itself | pending (parallel) |

Each phase produces something independently usable. Phase 0+1 alone delivers "structures don't lag at scale, mobs don't freeze on disconnect" — covering most of the felt MMO experience.

See [docs/ROADMAP.md](docs/ROADMAP.md) for detail.

## Install (when usable)

This will be drop-in Lua scripts into Avledet's `data/lua/scripts/ServerAuthority/`. Avledet auto-loads them.

You will need:
- A built Avledet binary (see [docs/build-avledet.md](docs/build-avledet.md))
- Steam SDK + steamclient.so set up per Avledet's instructions

## Acknowledgements

- [Avledet](https://github.com/crazicrafter1/Avledet) by `rj` / `crazicrafter1` — the platform this work is built on
- [`ddormer/valheim-serverside`](https://github.com/ddormer/valheim-serverside) — original BepInEx prior art for the server-authority concept
- The [Valheim](https://www.valheimgame.com/) team at [Iron Gate](https://irongatestudio.se/) — the game we are extending

## License

MIT. See [LICENSE](LICENSE).
