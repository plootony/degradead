extends Node
## Autoload (see [application]/autoload in project.godot).
## Shared network-test constants + one-time Fusion bootstrap.
##
## Physics layers (see [layer_names] in project.godot). Movement colliders live on
## "player_body" and mask environment + other players; shot raycasts mask
## environment + hitbox so walls block shots and a miss still lands on geometry.
const ENVIRONMENT_LAYER_BIT: int = 1
const PLAYER_BODY_LAYER_BIT: int = 2
const HITBOX_LAYER_BIT: int = 3

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
	"legs": 25,
}
const DEFAULT_DAMAGE: int = 25

## Fixed room code used by net/lobby.tscn by default (ТЗ Шаг 4a: "по фиксированному
## имени комнаты"). The lobby UI still lets you override it per ТЗ's "или простому коду".
const DEFAULT_ROOM_CODE: String = "TESTROOM"

## How long (seconds) the server keeps hitbox position history for lag-compensated
## rewind (Шаг 4b). The rewind window itself comes from Fusion.get_rtt() at shot
## time, clamped to this.
const HITBOX_HISTORY_SEC: float = 1.0

## Hit-resolution strategy used by net/match_server.gd:
##  "single"  -> Шаг 4a: one live raycast against the single capsule Hitbox.
##  "modular" -> Шаг 4b: rewind per-bone history and test against each hitbox.
## Ship with "single" first per the ТЗ's own validation order ("после того как 4a
## подтверждённо работает") -- flip to "modular" once 4a is confirmed on two clients.
const HITBOX_MODE: String = "single"

const MAX_SHOT_RANGE: float = 100.0

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


## Godot layer bits ready to drop into collision_layer / collision_mask.
static func hitbox_mask() -> int:
	return 1 << (HITBOX_LAYER_BIT - 1)


static func environment_mask() -> int:
	return 1 << (ENVIRONMENT_LAYER_BIT - 1)


static func player_body_mask() -> int:
	return 1 << (PLAYER_BODY_LAYER_BIT - 1)


static func damage_for(hitbox_key: String) -> int:
	return DAMAGE_BY_HITBOX.get(hitbox_key, DEFAULT_DAMAGE)


func _ready() -> void:
	# fusion/connection/app_id in project.godot should already configure the native
	# singleton on load, but we set it defensively here too in case that project
	# setting isn't auto-consumed by this preview build — cheap and harmless either way.
	var app_id: String = ProjectSettings.get_setting("fusion/connection/app_id", "")
	if app_id != "" and Engine.has_singleton("Fusion"):
		Fusion.set_app_id(app_id)
