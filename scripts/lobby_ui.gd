# ============================================================
# lobby_ui.gd — pre-match Host/Join screen for the networked
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
var _info_label  : Label
var _back_button : Button


func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	join_button.pressed.connect(_on_join_pressed)
	start_button.pressed.connect(_on_start_pressed)

	NetworkManager.peer_joined.connect(_on_peer_joined)
	NetworkManager.peer_left.connect(_on_peer_left)
	NetworkManager.client_connected.connect(_on_client_connected)
	NetworkManager.client_connection_failed.connect(_on_client_connection_failed)

	# Extra UI built in code so the .tscn stays minimal.
	_info_label = Label.new()
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.add_theme_font_size_override("font_size", 12)
	_info_label.add_theme_color_override("font_color", Color(0.55, 0.78, 1.0))
	_info_label.text = "Host, then give players one of your IPs + port %d.\nSame Wi‑Fi / LAN: use your local address below. Over the internet: forward UDP %d on the host's router, then use the host's public IP." % [NetworkManager.PORT, NetworkManager.PORT]
	$Panel/VBox.add_child(_info_label)
	$Panel/VBox.move_child(_info_label, 1)   # right under the title

	_back_button = Button.new()
	_back_button.text = "◀  Back to Menu"
	_back_button.pressed.connect(_on_back_pressed)
	$Panel/VBox.add_child(_back_button)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		_on_back_pressed()


func _on_back_pressed() -> void:
	NetworkManager.disconnect_network()
	get_tree().change_scene_to_file("res://MainMenu.tscn")


func _local_ipv4s() -> Array:
	var out : Array = []
	for a in IP.get_local_addresses():
		if a is String and (a as String).get_slice_count(".") == 4 \
				and not (a as String).begins_with("127.") \
				and not (a as String).begins_with("169.254."):
			out.append(a)
	return out


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
	var ips := _local_ipv4s()
	_info_label.text = "HOSTING on port %d.\nOn your network, players connect to:  %s\nInternet: forward UDP %d on your router, then share your public IP." % [
		NetworkManager.PORT,
		("   |   ".join(ips) if not ips.is_empty() else "(no LAN address found)"),
		NetworkManager.PORT]
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
	status_label.text = "Connecting to %s:%d..." % [ip, NetworkManager.PORT]


func _on_client_connected() -> void:
	status_label.text = "Connected. Waiting for the host to start the match."


func _on_client_connection_failed() -> void:
	status_label.text = "Could not connect. Check the IP/port and that the host is running."
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
