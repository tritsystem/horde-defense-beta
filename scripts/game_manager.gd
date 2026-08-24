# ============================================================
# game_manager.gd
# ============================================================
# Place as a direct child of your Game scene root.
# Does NOT spawn players — that is SSM's job.
# ============================================================
extends Node

# ============================================================
# CONFIG
# ============================================================
@export var starting_money  : int   = 1000
@export var prep_time       : float = 180.0
@export var income_amount   : int   = 10
@export var income_interval : float = 5.0

# ============================================================
# STATE
# ============================================================
var team_money    := { 1: 0, 2: 0 }
var team_ready    := { 1: false, 2: false }
var prep_timer    : float = 0.0
var match_started : bool  = false
var _income_timer : float = 0.0

# player_id (1-based) → { team_id, node }
var players : Dictionary = {}

# ============================================================
# SIGNALS
# ============================================================
signal money_changed(team: int, amount: int)
signal gold_awarded(team: int, amount: int)
signal ready_updated(team: int, ready: bool)
signal prep_time_updated(time_left: float)
signal match_started_signal()
signal player_registered(player_id: int, team_id: int)

# ============================================================
# READY
# ============================================================
func _ready() -> void:
	add_to_group("game_manager")
	_load_team_assignments()
	_init_money()
	print("🟢 PREP PHASE STARTED")


# ============================================================
# TEAM ASSIGNMENTS
# ============================================================
func _load_team_assignments() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if not is_instance_valid(gs):
		_register_player(1, 1)
		return

	var count : int = max(1, int(gs.get("player_count")))
	var assignments : Dictionary = gs.get("team_assignments")

	for i in range(count):
		var team_id : int = assignments.get(i, (i % 2) + 1)
		_register_player(i + 1, team_id)

	print("✅ Loaded %d players from GameSettings" % count)


func _register_player(player_id: int, team_id: int) -> void:
	players[player_id] = { "team_id": team_id, "node": null }
	# Ensure team has a money entry
	if not team_money.has(team_id):
		team_money[team_id] = starting_money
	player_registered.emit(player_id, team_id)
	print("👤 Player %d → Team %d" % [player_id, team_id])


# Called by SSM after spawning each player node
func bind_player_node(player_id: int, node: Node) -> void:
	if players.has(player_id):
		players[player_id]["node"] = node
	else:
		push_warning("[GM] bind_player_node: unknown player_id=%d" % player_id)


func get_player_team(player_id: int) -> int:
	return players.get(player_id, {}).get("team_id", -1)

func get_player_count() -> int:
	return players.size()

func get_players_on_team(team_id: int) -> Array:
	var result := []
	for pid in players:
		if players[pid]["team_id"] == team_id:
			result.append(pid)
	return result


# ============================================================
# PROCESS
# ============================================================
func _process(delta: float) -> void:
	if not match_started:
		_update_prep(delta)
	else:
		_update_income(delta)


# ============================================================
# PREP PHASE
# ============================================================
func _update_prep(delta: float) -> void:
	prep_timer += delta
	var time_left : float = maxf(prep_time - prep_timer, 0.0)
	prep_time_updated.emit(time_left)
	if time_left <= 0.0:
		_start_match()


func set_team_ready(team_id: int, ready: bool = true) -> void:
	if match_started or not team_ready.has(team_id): return
	team_ready[team_id] = ready
	ready_updated.emit(team_id, ready)
	var all_ready : bool = true
	for k in team_ready:
		if not team_ready[k]: all_ready = false; break
	if all_ready: _start_match()


# ============================================================
# MATCH START
# ============================================================
func _start_match() -> void:
	if match_started: return
	match_started  = true
	_income_timer  = 0.0
	print("🔥 MATCH STARTED")
	prep_time_updated.emit(-1.0)
	match_started_signal.emit()
	_enable_spawners()


func _enable_spawners() -> void:
	for s in get_tree().get_nodes_in_group("creep_spawner"):
		if not is_instance_valid(s): continue
		if "active" in s: s.active = true
		if s.has_method("start_spawning"): s.start_spawning()


# ============================================================
# INCOME
# ============================================================
func _update_income(delta: float) -> void:
	_income_timer += delta
	if _income_timer >= income_interval:
		_income_timer -= income_interval
		for team_id in team_money.keys():
			award_gold(team_id, income_amount)


# ============================================================
# MONEY
# ============================================================
func _init_money() -> void:
	var rsm := get_node_or_null("/root/RunSaveManager")
	for team_id in team_money.keys():
		var saved : int = rsm.get_team_gold(team_id) if is_instance_valid(rsm) else -1
		team_money[team_id] = saved if saved >= 0 else starting_money
		money_changed.emit(team_id, team_money[team_id])


func get_gold(team_id: int) -> int:
	return team_money.get(team_id, 0)


func spend_gold(team_id: int, amount: int) -> bool:
	if team_money.get(team_id, 0) < amount: return false
	team_money[team_id] -= amount
	money_changed.emit(team_id, team_money[team_id])
	var rsm := get_node_or_null("/root/RunSaveManager")
	if is_instance_valid(rsm): rsm.set_team_gold(team_id, team_money[team_id])
	return true


func award_gold(team_id: int, amount: int) -> void:
	team_money[team_id] = team_money.get(team_id, 0) + amount
	money_changed.emit(team_id, team_money[team_id])
	gold_awarded.emit(team_id, amount)
	var rsm := get_node_or_null("/root/RunSaveManager")
	if is_instance_valid(rsm): rsm.set_team_gold(team_id, team_money[team_id])


func add_gold(team_id: int, amount: int) -> void:
	award_gold(team_id, amount)
