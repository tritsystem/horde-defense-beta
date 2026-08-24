# ============================================================
# lobby_ui.gd — pre-match Host/Join screen for the new networked
# multiplayer path. Phase 1 of the multiplayer plan (see
# C:\Users\gbran\.claude\plans\reactive-sparking-finch.md).
# Local split-screen play never touches this scene at all.
# ============================================================
extends Control

@onready var host_button   : Button   = $Panel/VBox/HostButton
@onready var ip_field      : LineEdit = $Panel/VBox/IPField
@onready var join_button   : Button   = $Panel/VBox/JoinButton
@onready var player_list   : Label    = $Panel/VBox/PlayerListLabel
@onready var status_label  : Label    = $Panel/VBox/StatusLabel
@onready var start_button  : Button   = $Panel/VBox/StartButton

var _connected_peers : Array[int] = []


func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	start_button.pressed.connect(_on_start_pressed)

	NetworkManager.peer_joined.connect(_on_peer_joined)
	NetworkManager.peer_left.connect(_on_peer_left)
	NetworkManager.client_connected.connect(_on_client_connected)
	NetworkManager.client_connection_failed.connect(_on_client_connection_failed)


func _on_host_pressed() -> void:
	var err := NetworkManager.host_game()
	if err != OK:
		status_label.text = "Failed to host: %s" % error_string(err)
		return
	_connected_peers = [1]  # host is always peer id 1
	host_button.disabled = true
	join_button.disabled = true
	ip_field.editable = false
	start_button.disabled = false
	status_label.text = "Hosting. Waiting for players..."
	_refresh_player_list()


func _on_join_pressed() -> void:
	var ip := ip_field.text.strip_edges()
	if ip.is_empty():
		status_label.text = "Enter a host IP address."
		return
	var err := NetworkManager.join_game(ip)
	if err != OK:
		status_label.text = "Failed to connect: %s" % error_string(err)
		return
	host_button.disabled = true
	join_button.disabled = true
	ip_field.editable = false
	status_label.text = "Connecting to %s..." % ip


func _on_client_connected() -> void:
	status_label.text = "Connected. Waiting for host to start the match."


func _on_client_connection_failed() -> void:
	status_label.text = "Could not connect. Check the IP and try again."
	host_button.disabled = false
	join_button.disabled = false
	ip_field.editable = true


func _on_peer_joined(id: int) -> void:
	if not NetworkManager.is_server(): return
	if id in _connected_peers: return
	if _connected_peers.size() >= NetworkManager.MAX_PLAYERS:
		push_warning("[Lobby] Peer %d connected but lobby is full — should have been rejected earlier" % id)
	_connected_peers.append(id)
	_refresh_player_list()


func _on_peer_left(id: int) -> void:
	_connected_peers.erase(id)
	_refresh_player_list()


func _refresh_player_list() -> void:
	player_list.text = "Players (%d/%d): %s" % [
		_connected_peers.size(), NetworkManager.MAX_PLAYERS,
		", ".join(_connected_peers.map(func(p): return str(p)))
	]


func _on_start_pressed() -> void:
	if not NetworkManager.is_server(): return
	if _connected_peers.size() < 1:
		status_label.text = "Need at least 1 player to start."
		return
	NetworkManager.rpc_load_match.rpc()
