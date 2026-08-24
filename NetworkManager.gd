# ============================================================
# NetworkManager.gd — AUTOLOAD
# Phase 1 of the 4-player native multiplayer plan
# (see C:\Users\gbran\.claude\plans\reactive-sparking-finch.md).
# LAN direct-IP only — no matchmaking/relay/NAT traversal.
# ============================================================
extends Node

const PORT := 7777
const MAX_PLAYERS := 4  # includes the host

signal server_started
signal client_connected
signal client_connection_failed
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)

var is_networked : bool = false  # false = untouched legacy local/splitscreen path


func host_game() -> int:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS - 1)  # -1: server's own slot isn't a "peer"
	if err != OK:
		push_error("[NetworkManager] host_game failed: %s" % error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	is_networked = true
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[NetworkManager] Hosting on port %d (max %d players)" % [PORT, MAX_PLAYERS])
	server_started.emit()
	return OK


func join_game(ip: String) -> int:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, PORT)
	if err != OK:
		push_error("[NetworkManager] join_game failed: %s" % error_string(err))
		return err
	multiplayer.multiplayer_peer = peer
	is_networked = true
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
		multiplayer.connection_failed.connect(_on_connection_failed)
	print("[NetworkManager] Connecting to %s:%d..." % [ip, PORT])
	return OK


func disconnect_network() -> void:
	if is_instance_valid(multiplayer.multiplayer_peer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_networked = false


func is_server() -> bool:
	return is_networked and multiplayer.is_server()


func local_peer_id() -> int:
	return multiplayer.get_unique_id() if is_networked else 1


func _on_peer_connected(id: int) -> void:
	print("[NetworkManager] Peer connected: %d" % id)
	peer_joined.emit(id)


func _on_peer_disconnected(id: int) -> void:
	print("[NetworkManager] Peer disconnected: %d" % id)
	peer_left.emit(id)


func _on_connected_to_server() -> void:
	print("[NetworkManager] Connected to server.")
	client_connected.emit()


func _on_connection_failed() -> void:
	push_error("[NetworkManager] Failed to connect to server.")
	multiplayer.multiplayer_peer = null
	is_networked = false
	client_connection_failed.emit()


@rpc("authority", "call_local", "reliable")
func rpc_load_match() -> void:
	get_tree().change_scene_to_file("res://main.tscn")


# ============================================================
# CREEP DECK VOTE RELAY — Phase 3 of the multiplayer plan.
# CreepDeckUI.gd's vote state (_all_votes etc.) is a static var, shared
# across instances only WITHIN one process -- over the network each peer
# is a separate process, so a non-host client's vote never reached anyone
# else. This accumulates votes server-side and broadcasts the final deck,
# reusing CreepDeckUI's own sort/slice/pad tally algorithm unchanged
# (see CreepDeckUI.gd's tally_networked_votes).
# ============================================================
var _deck_votes : Dictionary = {}   # player_id -> Array of creep ids, server-only


@rpc("any_peer", "call_remote", "reliable")
func rpc_cast_vote(player_id: int, voted_ids: Array) -> void:
	if not multiplayer.is_server(): return
	_deck_votes[player_id] = voted_ids
	var total : int = multiplayer.get_peers().size() + 1
	print("[NetworkManager] vote received from player %d (%d/%d)" % [player_id, _deck_votes.size(), total])
	if _deck_votes.size() < total: return

	# Whichever CreepDeckUI instance exists on the server (the host's own
	# local player, since only the server ever reaches this point) supplies
	# the tally algorithm and the unvoted-creep padding pool -- mirrors the
	# existing local-multiplayer behavior of using the last-confirming
	# instance's unlock catalogue for padding.
	var ui := get_tree().get_first_node_in_group("creep_deck_ui")
	var final_deck : Array = []
	if is_instance_valid(ui) and ui.has_method("tally_networked_votes"):
		final_deck = ui.tally_networked_votes(_deck_votes)
	_deck_votes.clear()
	rpc_apply_final_deck.rpc(final_deck)


@rpc("authority", "call_remote", "reliable")
func rpc_apply_final_deck(deck: Array) -> void:
	for ui in get_tree().get_nodes_in_group("creep_deck_ui"):
		if is_instance_valid(ui) and ui.has_method("_finish"):
			ui._finish(deck.duplicate())
