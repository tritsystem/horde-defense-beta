# ============================================================
# RunSaveManager.gd — Autoload
# Persists mid-run state (class, gold, deck, crystals) to disk.
# Loads automatically at startup; clear_save() ends the run.
# ============================================================
extends Node

const SAVE_PATH := "user://run_save.json"

# In-memory cache of saved run data (int keys per player/team)
var _classes   : Dictionary = {}  # pid → int(PlayerClass)
var _gold      : Dictionary = {}  # team_id → int
var _decks     : Dictionary = {}  # pid → Array[String]
var _crystals  : Dictionary = {}  # pid → int


func _ready() -> void:
	load_run()


# ── Public query ───────────────────────────────────────────────

func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


# ── Load from disk ─────────────────────────────────────────────

func load_run() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return false
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	if not data is Dictionary:
		return false
	if data.has("classes"):
		for k in (data["classes"] as Dictionary):
			_classes[int(k)] = int(data["classes"][k])
	if data.has("gold"):
		for k in (data["gold"] as Dictionary):
			_gold[int(k)] = int(data["gold"][k])
	if data.has("decks"):
		for k in (data["decks"] as Dictionary):
			_decks[int(k)] = data["decks"][k]
	if data.has("crystals"):
		for k in (data["crystals"] as Dictionary):
			_crystals[int(k)] = int(data["crystals"][k])
	return true


# ── Save to disk ───────────────────────────────────────────────

func save_run() -> void:
	var data := {
		"classes":  {},
		"gold":     {},
		"decks":    {},
		"crystals": {},
	}
	for pid in _classes:
		data["classes"][str(pid)] = _classes[pid]
	for tid in _gold:
		data["gold"][str(tid)] = _gold[tid]
	for pid in _decks:
		data["decks"][str(pid)] = _decks[pid]
	for pid in _crystals:
		data["crystals"][str(pid)] = _crystals[pid]
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data))
	file.close()


# ── Clear run (call on retry / return to menu) ─────────────────

func clear_save() -> void:
	_classes  = {}
	_gold     = {}
	_decks    = {}
	_crystals = {}
	var dir := DirAccess.open("user://")
	if is_instance_valid(dir):
		dir.remove("run_save.json")


# ── Setters (update cache then flush to disk) ──────────────────

func set_player_class(pid: int, class_id: int) -> void:
	_classes[pid] = class_id
	save_run()

func set_team_gold(team_id: int, amount: int) -> void:
	_gold[team_id] = amount
	save_run()

func set_player_deck(pid: int, deck: Array) -> void:
	_decks[pid] = deck.duplicate()
	save_run()

func set_player_crystals(pid: int, amount: int) -> void:
	_crystals[pid] = amount
	save_run()


# ── Getters ────────────────────────────────────────────────────

func get_player_class(pid: int) -> int:
	return int(_classes.get(pid, 0))

# Returns -1 when no saved value (so callers can distinguish 0 gold from no save)
func get_team_gold(team_id: int) -> int:
	return int(_gold.get(team_id, -1))

func get_player_deck(pid: int) -> Array:
	return (_decks as Dictionary).get(pid, [])

func get_player_crystals(pid: int) -> int:
	return int(_crystals.get(pid, 0))
