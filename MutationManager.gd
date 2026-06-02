# ============================================================
# MutationManager.gd — AUTOLOAD
# ============================================================
# Selects one weekly global modifier based on ISO week number.
# Modifier is applied at game start and shown in HUD/main menu.
#
# Register as Autoload: MutationManager
# ============================================================
extends Node

signal mutation_applied(mutation: Dictionary)

const MUTATIONS : Array = [
	{
		"id": "fast_eggs",
		"name": "Fast Hatchers",
		"desc": "Eggs hatch 50% faster this week.",
		"color": Color(1.0, 0.55, 0.1),
		"icon": "🥚",
	},
	{
		"id": "double_spawns",
		"name": "Double Spawn",
		"desc": "Wave spawn size is doubled.",
		"color": Color(0.9, 0.2, 0.2),
		"icon": "👥",
	},
	{
		"id": "friendly_fire",
		"name": "Friendly Fire",
		"desc": "Player bullets deal 30% damage to teammates.",
		"color": Color(0.9, 0.4, 0.1),
		"icon": "🔥",
	},
	{
		"id": "titan_week",
		"name": "Titan Week",
		"desc": "All zombies have 50% more health.",
		"color": Color(0.7, 0.1, 0.9),
		"icon": "💪",
	},
	{
		"id": "fog_war",
		"name": "Fog of War",
		"desc": "Minimap disabled. Fog shrinks 30% faster.",
		"color": Color(0.4, 0.4, 0.8),
		"icon": "🌫",
	},
	{
		"id": "gold_rush",
		"name": "Gold Rush",
		"desc": "Enemies drop 2× gold. Eggs drop bonus crystals.",
		"color": Color(0.95, 0.85, 0.1),
		"icon": "💰",
	},
	{
		"id": "regen_horde",
		"name": "Regen Horde",
		"desc": "Zombies slowly regenerate health.",
		"color": Color(0.2, 0.9, 0.4),
		"icon": "❤",
	},
]

var active_mutation : Dictionary = {}


func _ready() -> void:
	add_to_group("mutation_manager")
	_pick_weekly_mutation()


func _pick_weekly_mutation() -> void:
	# Use ISO week number for deterministic weekly rotation
	var date   := Time.get_date_dict_from_system()
	var week_n := _iso_week(date["year"], date["month"], date["day"])
	var idx    := week_n % MUTATIONS.size()
	active_mutation = MUTATIONS[idx]
	print("[MutationManager] Week %d — Mutation: %s" % [week_n, active_mutation["name"]])


func apply_to_game() -> void:
	if active_mutation.is_empty(): return
	mutation_applied.emit(active_mutation)
	_apply_mutation(active_mutation["id"])
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.has_method("show_message"):
			hud.show_message(
				"%s Weekly Mutation: %s" % [active_mutation["icon"], active_mutation["name"]],
				active_mutation["color"])


func _apply_mutation(id: String) -> void:
	match id:
		"fast_eggs":
			for egg in get_tree().get_nodes_in_group("eggs"):
				if egg.has_method("get") and "hatch_time" in egg:
					egg.set("hatch_time", float(egg.get("hatch_time")) * 0.5)
		"double_spawns":
			var ls := get_tree().get_first_node_in_group("lane_spawner")
			if is_instance_valid(ls) and "wave_size" in ls:
				ls.set("wave_size", int(ls.get("wave_size")) * 2)
		"titan_week":
			for z in get_tree().get_nodes_in_group("zombies"):
				if "max_health" in z and "health" in z:
					z.set("max_health", float(z.get("max_health")) * 1.5)
					z.set("health",     float(z.get("health"))     * 1.5)
		"fog_war":
			for hud in get_tree().get_nodes_in_group("hud"):
				if hud.has_method("hide_minimap"): hud.hide_minimap()
		_:
			pass   # gold_rush, friendly_fire, regen_horde handled in their respective systems


func get_mutation_flag(flag: String) -> bool:
	return active_mutation.get("id", "") == flag


# Simple ISO week calculation
func _iso_week(year: int, month: int, day: int) -> int:
	var a := int((14 - month) / 12)
	var y := year + 4800 - a
	var m := month + 12 * a - 3
	var jdn := day + int((153 * m + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045
	var d4  := (jdn + 31741 - (jdn % 7)) % 146097 % 36524 % 1461
	var l   := int(d4 / 1460)
	var d1  := ((d4 - l) % 365) + l
	return int(d1 / 7) + 1
