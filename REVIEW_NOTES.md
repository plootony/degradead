# Review notes — test-fusion prototype

## What this is
Throwaway prototype validating one hypothesis: **Godot 4.7.2 + Photon Fusion (Godot SDK 3.0.0 *preview*, build 555) + Client-Server topology with prediction + Mixamo model + hitscan with server-side validation** holds together under real network latency. Not a game. Polish, IK, custom rigs, UI are explicitly out of scope per the original spec.

## Status
- Steps 1–3 (import, controller, animations) and Step 4a (networking + single-collider hitscan): **implemented and verified** by automated two-instance tests against live Photon Cloud.
- Step 4b (per-bone hitboxes + lag-compensated rewind): **implemented but switched off** — `NetConfig.HITBOX_MODE = "single"`. Flip to `"modular"` to exercise it. It has *not* been verified end to end.

## File map
| File | Role |
|---|---|
| `net/lobby.gd` / `.tscn` | Main scene: arena geometry, join UI, `FusionSpawner`, player spawning |
| `player/player.gd` / `.tscn` | Avatar: movement, camera, animation, hitboxes, shot RPC endpoints |
| `net/match_server.gd` | Autoload: player registry + shot resolution (4a raycast, 4b rewind) |
| `net/hitbox_history.gd` | Per-player position history buffer for lag compensation |
| `autoload/net_config.gd` | Shared constants: artificial delay, layer masks, raw Fusion enum ints |

## Fusion preview-SDK gotchas — these look like bugs but are deliberate
Every one of these was found empirically (the official docs are behind a bot-wall; the C# wrappers in `addons/fusion/cs/**` are the de-facto API reference). **Do not "simplify" these away.**

1. `input_authority` is **method-only** (`set_input_authority`/`get_input_authority`), not a registered property — `replicator.set("input_authority", …)` silently no-ops. `root_path`/`owner_mode`/`root_replication_mode` *are* real properties.
2. `FusionSpawner.spawn()`'s **pre-spawn Callable never fires**; the returned node is configured synchronously instead.
3. RPC targets must be **networked nodes** (carrying a replicator). Addressing the `MatchServer` autoload failed with `No FusionReplicator found for object 'Node'` even after `register_broadcast_receiver()`. Hence RPC endpoints live on `Player` and delegate to `MatchServer`.
4. RPC receivers still need Godot's standard **`@rpc` annotation**, despite Fusion using its own dispatch.
5. `root_replication_mode` must be `1` (Auto) or **nothing replicates** — remote peers see objects frozen at spawn.
6. `fusion/connection/mode` is **Cloud vs self-hosted Local**, *not* topology (setting it to 1 makes the client dial `127.0.0.1:5055`). Topology is `fusion/simulation/mode` (int; `1` = ClientServer, confirmed via `Fusion.get_simulation_mode()`).
7. `FusionServerReplicator` **must exist in the .tscn**, not be created in `_ready()` — the spawner scans the instantiated scene before `_ready()` runs and hard-crashes otherwise.
8. `on_process_input` **does not fire on non-master clients**; on the master it fires *synchronously inside* `queue_input()`. This drives the split in `_physics_process`: owner queues (and, if not master, drains for prediction); master drains for objects it doesn't own.
9. `Fusion.get_rpc_sender()` returned 0 in testing, so the shooter id is also passed explicitly and the server prefers its own value when available.
10. The Photon **App ID must be created with dashboard SDK "Version 3"** (Unreal/Godot). A Fusion-2 App ID fails room creation with `Unsupported Plugin` (32752) regardless of topology or region.

## Asset gotchas
- Godot's importer rewrites `mixamorig:Head` → `mixamorig_Head` (colon is illegal in node names).
- `Tony.fbx`'s own clip imports as `mixamo_com` and **is the T-pose** — must not be used as idle.
- `aks-74.fbx` is ~10× oversized (9.2 m); `_normalize_weapon_scale()` measures its AABB and rescales to 0.9 m.
- Mixamo models face **+Z**; the visual container is rotated 180° so the character doesn't run backwards.

## Where to focus review
- **Deviation from spec:** the artificial 100–150 ms delay is applied only in `MatchServer.resolve_shot()`, *not* to input processing — the SDK owns the input queue. This weakens the "test under real latency" claim for movement.
- **Lag compensation (4b)** uses sphere-vs-ray against a fixed rewind window equal to the artificial delay, not per-player RTT, and approximates every bone as a sphere. Unverified.
- **Idle animation** is `run_forward` frozen at frame 0 — no idle clip exists in the asset set. Looks like a mid-stride freeze.
- `MatchServer.register_player()` is retried from `_on_process_input` because `input_authority` may not be set at `_ready()` time. Slightly hacky; worth confirming ordering guarantees.
- Test hooks `--automove`, `--autofire`, `--posdump`, `--room=` live in production code (opt-in via CLI args only).
- `Player._local_aabb()` composes local transforms manually — check the maths if the weapon scale ever looks off.
- `player.tscn` is intentionally a bare shell; almost the whole node tree is built at runtime in `_ready()` because the FBX import layout could not be inspected when it was written. Reasonable to revisit now that the editor is available.

## How to verify
The project is driven headlessly with a portable Godot build (no editor needed):

    godot --path . -- --autojoin --room=SOMECODE [--automove] [--autofire] [--posdump]

Run two instances with the same `--room` and diff their logs: `[POS ...]` lines should show both peers tracking both players, and `[shot]` lines should be identical on both sides. Use a fresh room code each run — Photon rooms outlive the process (`EmptyRoomTtlMs`) and a stale room makes the next run join as a non-master.

After deleting `.godot/`, regenerate it with `godot --headless --path . --import` — a plain run does **not** rebuild the import cache or register the GDExtension.
