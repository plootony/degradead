extends Node
## Autoload (see [application]/autoload in project.godot).
## Shared network-test constants + one-time Fusion bootstrap.
##
## Physics layers (see [layer_names] in project.godot). Movement colliders live on
## "player_body" and mask environment + other players. Shots never use the physics
## server against players at all -- see MatchServer.resolve_shot(): only the
## environment is raycast (walls block shots, misses land on geometry), players are
## tested analytically against their rewound HitboxHistory shapes.
const ENVIRONMENT_LAYER_BIT: int = 1
const PLAYER_BODY_LAYER_BIT: int = 2

## Health / respawn. Damage is keyed by hitbox key ("body" in single mode, the
## per-bone keys from Player.HITBOX_BONES in modular mode).
const MAX_HP: int = 100
const RESPAWN_DELAY_SEC: float = 4.0
const DAMAGE_BY_HITBOX: Dictionary = {
	"body": 34,
	"torso": 34,
	"head": 100,
	"left_arm": 20,
	"right_arm": 20,
	"left_leg": 25,
	"right_leg": 25,
	"legs": 25,  # Legacy fallback.
}
const DEFAULT_DAMAGE: int = 25
## Stable bit positions are part of the replicated injury schema.
const INJURY_BITS: Dictionary = {
	"head": 1, "torso": 2, "left_arm": 4, "right_arm": 8,
	"left_leg": 16, "right_leg": 32,
}
const HITBOX_REGIONS: Dictionary = {
	"body": "torso", "pelvis": "torso",
	"left_forearm": "left_arm", "right_forearm": "right_arm",
	"left_shin": "left_leg", "right_shin": "right_leg",
}

func injury_bit(hitbox_key: String) -> int:
	if hitbox_key == "legs":
		return INJURY_BITS["left_leg"] | INJURY_BITS["right_leg"]
	return INJURY_BITS.get(HITBOX_REGIONS.get(hitbox_key, hitbox_key), 0)


## Fixed room code used by net/lobby.tscn by default (ТЗ Шаг 4a: "по фиксированному
## имени комнаты"). The lobby UI still lets you override it per ТЗ's "или простому коду".
const DEFAULT_ROOM_CODE: String = "TESTROOM"

## Hitbox shape set recorded into HitboxHistory and tested by MatchServer:
##  "single"  -> Шаг 4a: one capsule per player (follows the stance collider).
##  "modular" -> Шаг 4b: bone-attached capsules/spheres from Player.HITBOX_BONES.
## Both are lag-compensated the same way; only the shapes differ.
const HITBOX_MODE: String = "modular"
const MAX_SHOT_RANGE: float = 100.0

## Lag compensation. The master rewinds each target's HitboxHistory to the
## moment the shooter actually saw them, then tests the ray against those
## shapes. How long history is kept, and the rewind window's hard cap:
const HITBOX_HISTORY_SEC: float = 0.5
const MAX_REWIND_SEC: float = 0.35
const FIRE_INTERVAL_SEC: float = 0.1
const OWNER_CORRECTION_DECAY_SEC: float = 0.05
const MAX_CAMERA_ORIGIN_DISTANCE: float = 4.0
# Bump when the input layout / replicated property schema changes.
const NETWORK_VERSION: String = "dgd-net-7"
## Set false to resolve against current positions (rewind = 0) -- the old 4a
## behaviour, useful to A/B how much the rewind changes hit feel.
const LAG_COMPENSATION: bool = true

## Replication tuning applied to every Player's FusionServerReplicator from
## Player._build_replicator() (the .tscn can't reference these constants).
## Exponential decay constant for remote transforms, not a fixed snapshot
## buffer. 50 ms smooths stepped delivery; lag compensation uses this only as
## an estimate of visual age. Local mouse look does not use this smoothing.
const PROXY_INTERPOLATION_SEC: float = 0.05
## Ticks between state sends; 1 = every simulation tick (lowest latency).
const REPLICATION_UPDATE_INTERVAL_TICKS: int = 1

## Raw FusionClient::RpcTarget values (addons/fusion/cs/Core/FusionEnums.cs) --
## not re-exposed as a GDScript-visible enum by the native singleton, so we mirror
## the ints here instead of guessing at a Fusion.RpcTarget path that may not exist.
const RPC_TARGET_ALL: int = 0
const RPC_TARGET_MASTER: int = -1
const RPC_TARGET_PLUGIN: int = -2
const RPC_TARGET_OWNER: int = -3

## Raw FusionReplicator::OwnerMode value for PlayerPredicted (same file as above).
const OWNER_MODE_PLAYER_PREDICTED: int = 5

## Raw FusionClient::ConnectionStatus values (same source file).
const CONNECTION_STATUS_DISCONNECTED: int = 0
const CONNECTION_STATUS_CONNECTING: int = 1
const CONNECTION_STATUS_CONNECTED: int = 2
const CONNECTION_STATUS_JOINING_ROOM: int = 3
const CONNECTION_STATUS_IN_ROOM: int = 4
const CONNECTION_STATUS_ERROR: int = 5
const CONNECTION_STATUS_NAMES: Dictionary = {
	CONNECTION_STATUS_DISCONNECTED: "disconnected",
	CONNECTION_STATUS_CONNECTING: "connecting",
	CONNECTION_STATUS_CONNECTED: "connected",
	CONNECTION_STATUS_JOINING_ROOM: "joining room",
	CONNECTION_STATUS_IN_ROOM: "in room",
	CONNECTION_STATUS_ERROR: "error",
}


## Godot collision bit for a 1-based layer number, ready for collision_layer / mask.
## (Instance methods, not static: callers go through the autoload instance.)
func layer_mask(layer_bit: int) -> int:
	return 1 << (layer_bit - 1)


func damage_for(hitbox_key: String) -> int:
	return DAMAGE_BY_HITBOX.get(HITBOX_REGIONS.get(hitbox_key, hitbox_key), DEFAULT_DAMAGE)


func _ready() -> void:
	Input.use_accumulated_input = false
	# fusion/connection/app_id in project.godot should already configure the native
	# singleton on load, but we set it defensively here too in case that project
	# setting isn't auto-consumed by this preview build — cheap and harmless either way.
	var app_id: String = ProjectSettings.get_setting("fusion/connection/app_id", "")
	if app_id != "" and Engine.has_singleton("Fusion"):
		Fusion.set_app_id(app_id)
