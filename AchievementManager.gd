# ============================================================
# AchievementManager.gd — AUTOLOAD
# ============================================================
# Tracks per-match stats and awards achievement badges.
# Saves earned achievements to user://achievements.json.
#
# Register as Autoload: AchievementManager
# ============================================================
extends Node

signal achievement_earned(player_id: int, achievement: Dictionary)

const SAVE_PATH : String = "user://achievements.json"

const ACHIEVEMENTS : Array = [
	{
		"id":    "egg_blitz",
		"name":  "Egg Blitz",
		"desc":  "Destroy 3 eggs within 5 seconds.",
		"icon":  "🥚",
		"color": Color(1.0, 0.75, 0.2),
	},
	{
		"id":    "teammate_save",
		"name":  "Guardian Angel",
		"desc":  "Kill an enemy attacking a near-dead teammate.",
		"icon":  "🛡",
		"color": Color(0.4, 0.8, 1.0),
	},
	{
		"id":    "rampage",
		"name":  "Rampage",
		"desc":  "Get 5 kills in under 4 seconds.",
		"icon":  "🔥",
		"color": Color(1.0, 0.3, 0.1),
	},
	{
		"id":    "pacifist_wave",
		"name":  "Untouchable",
		"desc":  "Survive a full wave without taking damage.",
		"icon":  "✨",
		"color": Color(0.9, 0.9, 1.0),
	},
	{
		"id":    "hive_clearer",
		"name":  "Hive Clearer",
		"desc":  "Destroy all eggs in a hive cluster.",
		"icon":  "🏆",
		"color": Color(0.95, 0.8, 0.1),
	},
	{
		"id":    "sword_master",
		"name":  "Sword Master",
		"desc":  "Land 50 sword kills in one match.",
		"icon":  "⚔",
		"color": Color(0.7, 0.7, 1.0),
	},
	{
		"id":    "corruption_cleanser",
		"name":  "Corruption Cleanser",
		"desc":  "Capture 3 purifier beacons in one match.",
		"icon":  "💜",
		"color": Color(0.7, 0.3, 1.0),
	},
]

# Per-match stats: pid → stats dict
var _stats    : Dictionary = {}
var _earned   : Dictionary = {}   # pid → Array[String] (achievement ids)
var _saved    : Dictionary = {}   # persistent earned (loaded from file)

# Egg kill window tracking
var _egg_kill_times : Dictionary = {}  # pid → Array[float]


func _ready() -> void:
	add_to_group("achievement_manager")
	_load_saved()


func reset() -> void:
	_stats.clear()
	_egg_kill_times.clear()
	for pid in _earned:
		_earned[pid].clear()


func _ensure_player(pid: int) -> void:
	if not _stats.has(pid):
		_stats[pid] = {
			"kills": 0, "sword_kills": 0, "eggs_destroyed": 0,
			"beacons_captured": 0, "damage_taken_this_wave": 0.0
		}
	if not _earned.has(pid):
		_earned[pid] = []
	if not _egg_kill_times.has(pid):
		_egg_kill_times[pid] = []


func on_kill(pid: int, killed: Node) -> void:
	_ensure_player(pid)
	_stats[pid]["kills"] += 1
	if is_instance_valid(killed) and killed.has_method("swing"):
		_stats[pid]["sword_kills"] += 1
	_check_rampage(pid)
	_try_unlock(pid, "sword_master", _stats[pid]["sword_kills"] >= 50)


func on_egg_destroyed(pid: int) -> void:
	_ensure_player(pid)
	_stats[pid]["eggs_destroyed"] += 1
	# Track timestamps for Egg Blitz
	var now : float = Time.get_ticks_msec() / 1000.0
	_egg_kill_times[pid].append(now)
	_egg_kill_times[pid] = _egg_kill_times[pid].filter(func(t): return now - t < 5.0)
	_try_unlock(pid, "egg_blitz", _egg_kill_times[pid].size() >= 3)
	_try_unlock(pid, "hive_clearer", false)  # evaluated by HiveCluster


func on_beacon_captured(pid: int) -> void:
	_ensure_player(pid)
	_stats[pid]["beacons_captured"] += 1
	_try_unlock(pid, "corruption_cleanser", _stats[pid]["beacons_captured"] >= 3)


func on_wave_survived_clean(pid: int) -> void:
	_ensure_player(pid)
	_try_unlock(pid, "pacifist_wave", _stats[pid]["damage_taken_this_wave"] == 0.0)
	_stats[pid]["damage_taken_this_wave"] = 0.0


func on_player_took_damage(pid: int, amount: float) -> void:
	_ensure_player(pid)
	_stats[pid]["damage_taken_this_wave"] += amount


func on_hive_cleared(pid: int) -> void:
	_ensure_player(pid)
	_try_unlock(pid, "hive_clearer", true)


func _check_rampage(pid: int) -> void:
	# Rampage check is handled via kill streak in player.gd (5 kills in 4s window)
	pass


func _try_unlock(pid: int, achievement_id: String, condition: bool) -> void:
	if not condition: return
	if _earned[pid].has(achievement_id): return
	_earned[pid].append(achievement_id)
	for a in ACHIEVEMENTS:
		if a["id"] == achievement_id:
			achievement_earned.emit(pid, a)
			_show_badge(a)
			_save_earned(pid, achievement_id)
			return


func _show_badge(a: Dictionary) -> void:
	var msg := "%s Achievement: %s — %s" % [a["icon"], a["name"], a["desc"]]
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"): hud.show_message(msg, a["color"])


func _save_earned(pid: int, achievement_id: String) -> void:
	var key := str(pid)
	if not _saved.has(key): _saved[key] = []
	if not (achievement_id in _saved[key]):
		_saved[key].append(achievement_id)
	_persist()


func _persist() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_saved))
		f.close()


func _load_saved() -> void:
	if not FileAccess.file_exists(SAVE_PATH): return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f:
		var result := JSON.parse_string(f.get_as_text())
		f.close()
		if result is Dictionary: _saved = result
