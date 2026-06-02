# ============================================================
# LeaderboardManager.gd — AUTOLOAD
# ============================================================
# Saves highest wave / time per class for Endless mode.
# Data stored in user://leaderboard.json
#
# Register as Autoload: LeaderboardManager
# ============================================================
extends Node

const SAVE_PATH : String = "user://leaderboard.json"

# { "class_name": { "best_wave": int, "best_time": float, "date": String } }
var _records : Dictionary = {}


func _ready() -> void:
	add_to_group("leaderboard_manager")
	_load()


func submit(class_name: String, wave: int, time_secs: float) -> void:
	if not _records.has(class_name):
		_records[class_name] = {"best_wave": 0, "best_time": 0.0, "date": ""}
	var rec   : Dictionary = _records[class_name]
	var better : bool = wave > rec["best_wave"] or (wave == rec["best_wave"] and time_secs > rec["best_time"])
	if better:
		rec["best_wave"] = wave
		rec["best_time"] = time_secs
		rec["date"]      = Time.get_date_string_from_system()
		_records[class_name] = rec
		_save()
		for hud in get_tree().get_nodes_in_group("hud"):
			if hud.has_method("show_message"):
				hud.show_message("🏆 New record! Wave %d as %s!" % [wave, class_name], Color(0.95, 0.85, 0.1))


func get_record(class_name: String) -> Dictionary:
	return _records.get(class_name, {"best_wave": 0, "best_time": 0.0, "date": ""})


func get_all_records() -> Dictionary:
	return _records.duplicate()


func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_records))
		f.close()


func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH): return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f:
		var result := JSON.parse_string(f.get_as_text())
		f.close()
		if result is Dictionary: _records = result
