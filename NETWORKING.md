# Network foundation

The simulation uses Godot 4.7.2 and the repository's native Photon Fusion SDK.
The wire version is `dgd-net-4`; peers with the old schema join a different
Photon application-version namespace and cannot accidentally mix packets.

## State and input

- `net/player_input.gd` is the pure 12-byte input codec. Each tick includes
  movement, view angles, flags, requested stance/equipment and life id.
- `player/player.tscn` declares persistent replicated properties **before spawn**:
  HP, life id, respawn deadline, stance, weapon, aim, pitch and shot sequencing /
  cooldown, plus the injury bit mask. Fusion's `REPLICATION_AUTO` supplies transform and velocity.
- The input owner predicts locally. The master executes the same decoded input.
  Queued input from a previous life is rejected after a respawn teleport.
- Local mouse intent is independent of simulated angles: replay never overwrites
  a newly sampled mouse event. Camera rotation updates immediately; camera
  translation extrapolates at most one physics tick, with an obstruction check.
  Small reconciliation displacements decay on the camera over 50 ms; normal
  movement and rotation are not delayed. Physics and respawn teleports snap immediately.
- Stance and equipment are tick input plus snapshot state, rather than standalone
  broadcasts. This makes both rollback and late join coherent.
- HP has one source: the replicated player property written by the master.
  Hit RPCs only produce transient effects. A new master continues the replicated
  respawn deadline in Fusion's shared network clock.

## Shots and hit history

A click immediately plays its firing animation and sends a reliable request.
The predicted tracer is clipped against visible hitboxes and geometry during the
next physics tick (at most one tick later), without waiting for the server. The host
validates the native sender against the receiving avatar, life id, increasing
sequence, cooldown, finite unit ray and bounded camera origin. Unknown senders
are rejected. Physics queries run after movement/history in the physics tick.
Both the camera ray and the path from the player's eye to the result are checked
against cover. This is bounded server validation, not a complete anti-cheat.

The ring buffer keeps 0.5 s of history and interpolates shapes between ticks.
It does not interpolate across death, incompatible stance shapes, or respawn.
Rewind is capped at 0.35 s. Remote smoothing retains the 50 ms exponential decay
constant; this is **not** an exact fixed-time snapshot buffer. RTT plus the decay
constant is an approximation of visual age, so heavily jittered / asymmetric
links still need dedicated latency and loss testing before competitive use.

## SDK behavior verified in this build

Live tests show that `get_rpc_sender()` supplies the real peer id. The earlier
unknown-sender workaround is therefore removed. Host `queue_input()` invokes its
own callback synchronously; an ordinary client must drain its prediction queue.
Pure observers do not execute input and must register independently of input
callbacks. Custom property configuration is stored in the scene for late joins.

The native SDK currently emits `Capture not registered: 'fusion'` on headless
shutdown without a debugger session. The test runner excludes this exact teardown
message only; script errors and all other engine errors fail the run.

## Repeatable checks

After importing the project, run:

```sh
godot --headless --path . --script res://tests/network_unit.gd
python3 tests/run_network.py /absolute/path/to/godot
```

The live runner needs access to Photon and starts three isolated peers in a
unique room. It checks local movement before a server round trip, movement
speed, a jump through prediction replay, preservation of mouse intent, late
join HP/injuries/stance/equipment, master migration during death, respawn, damage after
migration, and rejection of previous-life input. Logs are in `tests/results/`.

Two-peer combat can also be exercised with the existing
`--autojoin --room=UNIQUE --autofire --autoaim --posdump` flags.

## Extending the game

Add durable gameplay values to the scene's replication config. Add player
intent to the versioned input codec if it affects simulation or replay.
Keep transient sound/particles out of replay, and use RPCs for transient events.
New server-owned cooldowns and timers must use shared network time and be
replicated when they need to survive master migration. Keep local camera and
UI smoothing out of authoritative physics.

References: [Fusion input/prediction](https://doc.photonengine.com/fusion-godot/v3-client-server/manual/replication/prediction-and-input),
[property replication](https://doc.photonengine.com/fusion-godot/v3-client-server/manual/replication/syncing-properties),
[Godot CharacterBody3D](https://docs.godotengine.org/en/stable/classes/class_characterbody3d.html).

## Hit visuals

`net/shot_visuals.gd` encodes 48 bytes of cosmetic context: shot sequence, both
life ids, the muzzle position at firing time, and contact/normal in the target's
historical body or bone frame. On receipt the contact is mapped onto the
currently displayed target. Blood is emitted there in world coordinates, so
already-emitted particles do not follow later target motion. World impacts keep
world coordinates and use the surface normal. Old-life and duplicate reports
cannot spawn another blood burst.

The muzzle marker is placed on the imported compensator's end face. Tracer
prediction uses the same read-only collision query as server hit resolution;
only the server wrapper changes HP. An acknowledgement may correct a visible
predicted tracer in place, but never redraws an expired line or edits a pool
slot reused by another shot. Tracer fade uses a separate material per pool slot
and works in Forward+, Mobile and Compatibility rendering modes.

Offline regression and rendered verification:

```sh
godot --headless --path . --script res://tests/impact_visuals.gd
godot --path . --rendering-method gl_compatibility --script res://tests/impact_visuals.gd -- --visual
```

The rendered test saves `/tmp/dgd-impact-visual.png`: the blue box represents
the historical target location and the green box the current displayed one.
The blood burst and tracer end must appear at the green box.


## Modular injuries and headshots

The default is now `HITBOX_MODE = "modular"`. Existing bone-based hit detection
uses 11 shapes: head/pelvis spheres and capsules along the torso, upper/lower
arms and upper/lower legs. Every segment has its own stable hit key and bone
frame for rewind and blood reprojection. The capsules approximate the model;
they follow the current animated skeleton without changing its animations.

`NetConfig.HITBOX_REGIONS` maps segments onto six HUD regions. `_injured_parts`
is a replicated integer bit mask (head=1, torso=2, left arm=4, right arm=8,
left leg=16, right leg=32). Only `server_apply_damage(damage, hitbox_key)` writes
injuries and health; any positive-damage head hit sets HP to zero immediately.
Respawn resets the mask. Snapshots preserve injuries through late joining,
prediction rollback and master migration; hit-effect RPCs never modify the mask.

The compact 100×100 HUD silhouette (`ui/injury_panel.gd`) sits at the top left,
without text or a background. It listens for state changes and does not intercept
mouse input. Healthy regions are white; injured regions are red;
there is no separate limb HP or movement penalty yet. The provided
`icons8-hitbox.svg` is preserved in `ui/injuries/`; its original closed subpaths
are split into six white SVG layers for independent tinting. Left/right regions
refer to the character's anatomy (front view).

```sh
godot --headless --path . --script res://tests/injury_hud.gd
godot --path . --rendering-method gl_compatibility --resolution 1100x700 --script res://tests/injury_hud.gd -- --visual
```

The rendered check saves `/tmp/dgd-injury-hud.png`. The live three-peer runner
also checks limb injuries, a lethal head hit with damage=1, late-join injury
state, master migration, and clearing injuries on respawn. To test the full
shot RPC / rewind / hit-report path, start two instances with:

```sh
godot --headless --path . --script res://tests/headshot_peer.gd -- --autojoin --room=UNIQUE_HEADSHOT_ROOM
```


## Remote locomotion animation

Locomotion direction, walk/run/sprint selection and jump tuck use the
CharacterBody3D `velocity` supplied by simulation or Fusion's root replication.
They do not differentiate the rendered position: packet batching and prediction
corrections produce artificial zero/high speeds that used to restart forward
clips. An explicit zero velocity selects idle immediately; missing position
updates do not temporarily downgrade a running player to walking.

To check both directions (host observing client, client observing host), start
two instances in the same unique room:

```sh
godot --headless --path . --script res://tests/animation_peer.gd -- --autojoin --room=UNIQUE_ANIMATION_ROOM
godot --headless --path . --script res://tests/animation_motion.gd
```

The live test requires uninterrupted run clips while moving and idle after
stopping. The offline test exercises batched position updates, corrections,
teleports, sprint, strafe, stance and jump-pose stability.

## Camera profiles

The enabled `addons/dgd_camera` editor plugin edits four independent camera
profiles in `camera_settings.tres`. The player and editor preview use the same
rig and motion components. Profile transitions blend distance, anchor height,
FOV and tilt; current mouse look still applies immediately. The first-person
anchor follows stance height rather than animated head motion, so a zero step
amplitude disables locomotion bob. A SpringArm retains obstruction handling.

Own fire input starts a camera impulse after capturing and sending the ray.
Only a local player's confirmed HP decrease triggers hit shake; replay of input
and remote shot animations do not. Impulses reset on a new life. No new network
messages or replicated properties are introduced. See the plugin README for
parameters, editor workflow and its runtime/editor/network tests.
