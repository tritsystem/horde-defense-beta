# ============================================================
# NetPlayerSpawner.gd
# Phase 1 of the multiplayer plan (see
# C:\Users\gbran\.claude\plans\reactive-sparking-finch.md).
# Networked equivalent of SplitScreenManager.gd's local player
# spawning -- one Player.tscn instance per connected peer,
# owned (multiplayer authority) by that peer, replicated to
# everyone via MultiplayerSpawner. Self-contained: creates its
# own MultiplayerSpawner + players_root children, so it can be
# instantiated dynamically by Scenesetup.gd the same way it
# already dynamically creates SplitScreenManager.
# Only ever created when NetworkManager.is_networked is true --
# the legacy local split-screen path never touches this.
# ============================================================
extends Node

const PLAYER_SCENE_PATH := "res://scenes/Player.tscn"

var players_root : Node3D
var _spawner : MultiplayerSpawner
var _next_slot : int = 1
var _peer_to_player_id : Dictionary = {}  # peer_id -> assigned player_id (1-4)


func _ready() -> void:
	if not NetworkManager.is_networked:
		queue_free()
		return

	players_root = Node3D.new()
	players_root.name = "NetPlayers"
	add_child(players_root)

	_spawner = MultiplayerSpawner.new()
	_spawner.name = "PlayerSpawner"
	_spawner.spawn_path = players_root.get_path()
	_spawner.add_spawnable_scene(PLAYER_SCENE_PATH)
	add_child(_spawner)

	if multiplayer.is_server():
		# host plays too -- spawn its own player first
		_spawn_for(multiplayer.get_unique_id())
		multiplayer.peer_connected.connect(_spawn_for)
		multiplayer.peer_disconnected.connect(_despawn_for)


func _spawn_for(peer_id: int) -> void:
	if not multiplayer.is_server(): return
	if peer_id in _peer_to_player_id:
		push_warning("[NetPlayerSpawner] peer %d already has a player, ignoring" % peer_id)
		return
	if _next_slot > 4:
		push_warning("[NetPlayerSpawner] lobby full (4/4) but peer %d connected -- should have been rejected in the lobby" % peer_id)
		return

	var scene : PackedScene = load(PLAYER_SCENE_PATH)
	var p : Node = scene.instantiate()
	p.name = "Player_%d" % peer_id
	p.player_id = _next_slot
	p.team_id = 1  # co-op: every human player defends the one shared team-1 base
	p.local_input_slot = 1  # each client has exactly one local human at slot 1
	p.device_id = -1

	_peer_to_player_id[peer_id] = _next_slot
	_next_slot += 1

	players_root.add_child(p, true)
	p.set_multiplayer_authority(peer_id)
	print("[NetPlayerSpawner] Spawned player_id=%d for peer %d" % [p.player_id, peer_id])


func _despawn_for(peer_id: int) -> void:
	if not multiplayer.is_server(): return
	if not (peer_id in _peer_to_player_id): return
	var pid : int = _peer_to_player_id[peer_id]
	for child in players_root.get_children():
		if "player_id" in child and int(child.player_id) == pid:
			child.queue_free()
			break
	_peer_to_player_id.erase(peer_id)
	print("[NetPlayerSpawner] Despawned player_id=%d for disconnected peer %d" % [pid, peer_id])
