# test-fusion

Prototype validating **Godot 4.7.2 + Photon Fusion (Godot SDK 3.0.0-preview-555), Client-Server topology with prediction**, a Mixamo character, and hitscan shooting with server-side validation.

Networked shooter prototype. See [NETWORKING.md](NETWORKING.md) for the current network architecture and regression tests. [REVIEW_NOTES.md](REVIEW_NOTES.md) records earlier experiments; its network notes are historical.

## Running it on a fresh machine

Everything needed is in this repo — the Photon SDK and the Photon App ID are committed, so there is nothing to download or configure by hand.

1. **Install Godot 4.7.2 (stable)**. No .NET/Mono build required — the project is pure GDScript.
2. **Clone the repo.**
3. **Build the import cache.** A clone has no `.godot/` (it is generated, not committed). Either open the project once in the Godot editor and let it import, or do it headlessly:

       godot --headless --path . --import

   Skipping this step fails with `Identifier "Fusion" not declared` and `Cannot open file res://.godot/imported/...` — the GDExtension registry and imported assets both live in that cache.
4. **Run** — `F5` in the editor, or:

       godot --path .

The Fusion addon is a plain GDExtension: it loads automatically from `addons/fusion/`, and there is **nothing to enable** under Project → Plugins.

## Testing multiplayer

In the editor: **Debug → Run Multiple Instances → 2 Instances**, then `F5`. Press **Join** in both windows with the same room code.

Controls: `WASD` move, mouse look, **click** to capture the mouse, **Esc** to release it (needed to click into the other window), **LMB** to fire (only while the mouse is captured and the rifle is in hand), **R** reload, **RMB (hold)** aim, **Shift (hold)** sprint, **Space** jump, **C** toggle crouch, **Z** toggle prone (from either stand or crouch; pressing it again while prone stands back up), **F** melee (rifle butt, visual only -- no damage), **V** toggle first / third person, **Q** switch weapon (rifle ⇄ hands, the rifle goes on the back), **1** / **2** pick the slot directly.

Camera is DayZ-like: third person sits behind and over the right shoulder with the character low-centre; aiming pulls in tight over the shoulder and narrows the FOV; first person is at the eyes with the body and rifle rendered. The torso bends with the vertical look angle (a `SkeletonModifier3D` on top of the animation), so the rifle follows your aim in every view.

Gameplay loop: 100 HP, body shot = 34 (head = 100 in modular mode), death plays the Mixamo "Dying" clip, respawn after 4 s at the next spawn point. Hits show a red burst on the target and a tracer from the muzzle (the shooter's own tracer is drawn immediately, before the master confirms the hit); misses that reach level geometry show a dust burst there. Walls block shots. The join panel hides once you are in a room; HP is shown top-left. A stats block top-right shows FPS / frame time, physics rate, connection state, region, ping (`Fusion.get_rtt()`), room name and player count, local player id and master/client role, network time and spawned avatar count.

Headless test harness (no editor, no keyboard needed):

    godot --path . -- --autojoin --room=SOMECODE [--automove] [--autofire] [--autoaim] [--posdump]

Run two instances with the same `--room` and compare their logs: `[POS ...]` lines should show both peers tracking both players (with hp), and `[shot]` lines should be identical on both sides. With `--autofire --autoaim` on both, expect three body hits → `hp 0`, an `rpc_respawn` a few seconds later, and the respawned player back at 100. **Use a fresh room code per run** — Photon rooms outlive the process, and rejoining a stale one makes the new instance a non-master.

## Notes

- The Photon **App ID must be created with dashboard SDK "Version 3"** (Unreal/Godot). A Fusion-2 App ID fails room creation with `Unsupported Plugin` (32752). The committed App ID is already correct.
- **Region**: `fusion/connection/default_region` is set to `eu`. This Fusion 3 preview App ID only exposes five Photon regions — `us`, `eu`, `asia`, `jp`, `sa`; `ru`/`rue`/`tr` and the rest return `Region X is not available (32756)`. Measured from Russia on 2026-09-07: eu ≈149 ms, us ≈209 ms, asia ≈289 ms, sa ≈354 ms, jp ≈379 ms. A per-run override is `Fusion.connect_to_photon(user_id, region, app_version)`.
- `project.godot` pins the Windows rendering driver to **D3D12**. On a machine without D3D12 support, change `rendering/rendering_device/driver.windows` to `vulkan`.
- Hit detection is **lag-compensated in both hitbox modes** (the master rewinds each target to what the shooter was looking at, using the shooter's own RTT). `NetConfig.HITBOX_MODE` only picks the shapes: `"single"` (default, one capsule per player) or `"modular"` (one sphere per bone, head = 100 damage). `NetConfig.LAG_COMPENSATION = false` resolves against current positions instead, to A/B the difference.


Ammo capacity, starting reserve, caliber, reload duration and single/automatic
fire are configured in **Стрельба → Патроны** for each weapon. Bottom-right HUD
shows numeric HP and magazine / reserve. See `addons/dgd_firearm/README.md`.
