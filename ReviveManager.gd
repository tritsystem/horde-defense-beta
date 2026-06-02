# ============================================================
# ReviveManager.gd — AUTOLOAD
# ============================================================
# Manages a shared teamwide revive pool. On player death,
# consumes one revive and respawns the player. If the pool
# is empty, triggers game over.
#
# Register as Autoload: ReviveManager
# ============================================================
extends Node

signal revive_used(player_id: int, revives_left: int)
signal revive_pool_empty()

const DEFAULT_POOL : int = 5

var _pool     : int  = DEFAULT_POOL
var _enabled  : bool = true


func _ready() -> void:
	add_to_group("revive_manager")


func reset(pool: int = DEFAULT_POOL) -> void:
	_pool    = pool
	_enabled = true
	_update_hud()


func disable() -> void:
	_enabled = false


func get_revives_left() -> int:
	return _pool


func on_player_died(player: Node) -> void:
	if not _enabled: return
	if _pool > 0:
		_pool -= 1
		revive_used.emit(player.get("player_id") if "player_id" in player else 0, _pool)
		_update_hud()
		_announce_revive(player)
		# Trigger respawn after brief delay
		get_tree().create_timer(2.5).timeout.connect(func():
			if is_instance_valid(player) and player.has_method("_respawn"):
				player._respawn())
	else:
		revive_pool_empty.emit()
		for hud in get_tree().get_nodes_in_group("hud"):
			if hud.has_method("show_message"):
				hud.show_message("💀 No revives left — GAME OVER!", Color(0.9, 0.1, 0.1))


func _announce_revive(player: Node) -> void:
	var pid := int(player.get("player_id")) if "player_id" in player else 0
	var msg := "💀 Player %d down! Revives left: %d" % [pid, _pool]
	var col := Color(0.9, 0.5, 0.5) if _pool > 2 else Color(1.0, 0.2, 0.2)
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"): hud.show_message(msg, col)


func _update_hud() -> void:
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("update_revive_count"): hud.update_revive_count(_pool)
