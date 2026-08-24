# ============================================================
# PurchaseRelay.gd — AUTOLOAD
# Phase 3 of the multiplayer plan (see
# C:\Users\gbran\.claude\plans\reactive-sparking-finch.md).
#
# Server-authoritative spawning for player-purchased creeps and
# turrets, replicated via MultiplayerSpawner -- the spawn-side
# counterpart to CombatRelay.gd's damage relay: the client reports
# intent, the server validates+spends gold and performs the real
# spawn under this autoload's own spawn_path, and the spawner
# replicates the resulting node to every peer. Purchased creeps and
# turrets are added under a dedicated root this autoload owns,
# separate from hive/zombie autonomous spawning -- that's Phase 4's
# server-only simulation (not started), deliberately untouched here.
#
# Trust level matches gold: the client-reported cost is trusted and
# validated only by spend_gold's/spend_crystals's own funds check --
# this is PvE co-op (see plan's stated threat model), not anti-cheat
# hardening.
# ============================================================
extends Node

var _spawn_root : Node3D
var _spawner    : MultiplayerSpawner
var _registered_paths : Dictionary = {}   # resource_path -> true


func _ready() -> void:
	_spawn_root = Node3D.new()
	_spawn_root.name = "PurchasedRoot"
	add_child(_spawn_root)
	_spawn_root.add_to_group("purchased_root")

	_spawner = MultiplayerSpawner.new()
	_spawner.name = "PurchaseSpawner"
	add_child(_spawner)
	_spawner.spawn_path = _spawn_root.get_path()


func spawn_root() -> Node3D:
	return _spawn_root


## Called by shopui.gd on every peer at boot (turret_scenes/creep scenes are
## editor-assigned consts, identical across peers) so every client already
## knows the scene before the server ever spawns one -- MultiplayerSpawner
## requires the receiving end to have the scene registered to instantiate
## the replicated node at all.
func register_scene(scene: PackedScene) -> void:
	if not is_instance_valid(scene): return
	var path := scene.resource_path
	if path.is_empty() or _registered_paths.has(path): return
	_spawner.add_spawnable_scene(path)
	_registered_paths[path] = true


@rpc("any_peer", "call_remote", "reliable")
func rpc_request_buy_creep(team: int, scene_path: String, kind: String, owner_path: NodePath,
							cost: int, count: int) -> void:
	if not multiplayer.is_server(): return
	# "economy_controller" (not the shared "game_manager" group) --
	# main.tscn has a second, unrelated node also in "game_manager" that
	# doesn't implement spend_gold/get_gold. See game_phase_script.gd's
	# _ready() for the full explanation.
	var gm := get_tree().get_first_node_in_group("economy_controller")
	if not is_instance_valid(gm) or not gm.spend_gold(team, cost): return
	gm.rpc_sync_gold.rpc(team, gm.get_gold(team))

	var scene : PackedScene = load(scene_path)
	if not is_instance_valid(scene): return
	register_scene(scene)  # server registers too, harmless if already done

	var owner_player : Node = get_node_or_null(owner_path)
	var spawned := false
	for s in get_tree().get_nodes_in_group("creep_spawner"):
		if not ("team_id" in s) or s.team_id != team: continue
		if not s.has_method("spawn_purchased_creep"): continue
		for _i in range(count):
			var creep : Node = s.spawn_purchased_creep(scene, owner_player)
			if not is_instance_valid(creep): continue
			if "owner_id" in creep and is_instance_valid(owner_player):
				creep.owner_id = owner_player.get_instance_id()
			if "team_id" in creep: creep.team_id = team
			if kind == "attack":
				if creep.has_method("set_ai_mode"): creep.set_ai_mode(1)
				if "owner_player" in creep: creep.owner_player = null
			else:
				if creep.has_method("set_ai_mode"): creep.set_ai_mode(2)
				if "owner_player" in creep: creep.owner_player = owner_player
		spawned = true
		break
	if not spawned and is_instance_valid(owner_player) and owner_player.has_method("spawn_creep_at_base"):
		for _i in range(count):
			owner_player.spawn_creep_at_base(scene, kind)


@rpc("any_peer", "call_remote", "reliable")
func rpc_request_buy_turret(team: int, scene_path: String, position: Vector3, rotation_y: float,
							 owner_path: NodePath, cost: int) -> void:
	if not multiplayer.is_server(): return
	# "economy_controller" (not the shared "game_manager" group) --
	# main.tscn has a second, unrelated node also in "game_manager" that
	# doesn't implement spend_gold/get_gold. See game_phase_script.gd's
	# _ready() for the full explanation.
	var gm := get_tree().get_first_node_in_group("economy_controller")
	if not is_instance_valid(gm) or not gm.spend_gold(team, cost): return
	gm.rpc_sync_gold.rpc(team, gm.get_gold(team))

	var scene : PackedScene = load(scene_path)
	if not is_instance_valid(scene): return
	register_scene(scene)

	var inst := scene.instantiate() as Node3D
	if not is_instance_valid(inst): return
	_spawn_root.add_child(inst, true)
	inst.global_position = position
	inst.rotation.y      = rotation_y
	if "team_id" in inst: inst.team_id = team
	var owner_player : Node = get_node_or_null(owner_path)
	if "owner_id" in inst and is_instance_valid(owner_player): inst.owner_id = owner_player.get_instance_id()
	if not inst.is_in_group("towers"): inst.add_to_group("towers")
