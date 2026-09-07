# test-fusion

Prototype validating **Godot 4.7.2 + Photon Fusion (Godot SDK 3.0.0-preview-555), Client-Server topology with prediction**, a Mixamo character, and hitscan shooting with server-side validation.

Not a game — a viability test. See [REVIEW_NOTES.md](REVIEW_NOTES.md) for architecture, SDK gotchas and known gaps.

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

Controls: `WASD` move, mouse look, **click** to capture the mouse, **Esc** to release it (needed to click into the other window), **LMB** to fire.

Headless test harness (no editor, no keyboard needed):

    godot --path . -- --autojoin --room=SOMECODE [--automove] [--autofire] [--posdump]

Run two instances with the same `--room` and compare their logs: `[POS ...]` lines should show both peers tracking both players, and `[shot]` lines should be identical on both sides. **Use a fresh room code per run** — Photon rooms outlive the process, and rejoining a stale one makes the new instance a non-master.

## Notes

- The Photon **App ID must be created with dashboard SDK "Version 3"** (Unreal/Godot). A Fusion-2 App ID fails room creation with `Unsupported Plugin` (32752). The committed App ID is already correct.
- `project.godot` pins the Windows rendering driver to **D3D12**. On a machine without D3D12 support, change `rendering/rendering_device/driver.windows` to `vulkan`.
- Step 4b (per-bone hitboxes + lag compensation) is implemented but **off**: flip `HITBOX_MODE` to `"modular"` in `autoload/net_config.gd`.
