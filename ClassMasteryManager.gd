# ============================================================
# ClassMasteryManager.gd — AUTOLOAD
# ============================================================
# Tracks kills per class per match, awards mastery levels 1-5.
# Resets each match. Passive perks applied via get_perk_bonus().
#
# Register as Autoload: ClassMasteryManager
# ============================================================
extends Node

signal mastery_level_up(player_id: int, class_id: int, new_level: int)

# XP thresholds for each mastery level (kills needed)
const LEVEL_THRESHOLDS : Array[int] = [0, 5, 15, 30, 55, 90]

# Passive perk bonuses per mastery level [level_1 ... level_5]
# Each class has the same progression structure; values scale per level
const PERK_MOVE_SPEED  : Array[float] = [0.0, 0.02, 0.04, 0.06, 0.08, 0.10]
const PERK_DAMAGE      : Array[float] = [0.0, 0.03, 0.06, 0.09, 0.12, 0.15]
const PERK_CD_REDUCE   : Array[float] = [0.0, 0.03, 0.06, 0.10, 0.13, 0.16]
const PERK_AMMO_BONUS  : Array[int]   = [0,   0,    1,    1,    2,    2   ]

# State: pid → { class_id: kills }
var _kills   : Dictionary = {}   # pid → { class_id: int }
var _levels  : Dictionary = {}   # pid → { class_id: int }


func _ready() -> void:
	add_to_group("class_mastery_manager")


func reset() -> void:
	_kills.clear()
	_levels.clear()


func register_kill(player_id: int, class_id: int) -> void:
	if not _kills.has(player_id):
		_kills[player_id]  = {}
		_levels[player_id] = {}
	if not _kills[player_id].has(class_id):
		_kills[player_id][class_id]  = 0
		_levels[player_id][class_id] = 0

	_kills[player_id][class_id]  += 1
	var kills  : int = _kills[player_id][class_id]
	var old_lv : int = _levels[player_id][class_id]
	var new_lv : int = _compute_level(kills)

	if new_lv > old_lv:
		_levels[player_id][class_id] = new_lv
		mastery_level_up.emit(player_id, class_id, new_lv)
		_announce(player_id, class_id, new_lv)


func get_level(player_id: int, class_id: int) -> int:
	return int(_levels.get(player_id, {}).get(class_id, 0))


func get_kills(player_id: int, class_id: int) -> int:
	return int(_kills.get(player_id, {}).get(class_id, 0))


func get_perk_bonus(player_id: int, class_id: int, stat: String) -> float:
	var lv : int = get_level(player_id, class_id)
	match stat:
		"move_speed": return PERK_MOVE_SPEED[lv]
		"damage":     return PERK_DAMAGE[lv]
		"cd_reduce":  return PERK_CD_REDUCE[lv]
	return 0.0


func get_ammo_bonus(player_id: int, class_id: int) -> int:
	return PERK_AMMO_BONUS[get_level(player_id, class_id)]


func _compute_level(kills: int) -> int:
	var lv := 0
	for i in range(1, LEVEL_THRESHOLDS.size()):
		if kills >= LEVEL_THRESHOLDS[i]: lv = i
		else: break
	return lv


func _announce(player_id: int, class_id: int, level: int) -> void:
	var msg := "⭐ Class Mastery Lv.%d! (+move speed, +damage)" % level
	var col := Color(1.0, 0.85, 0.1)
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"): hud.show_message(msg, col)
	print("[ClassMastery] P%d class %d → Level %d" % [player_id, class_id, level])
