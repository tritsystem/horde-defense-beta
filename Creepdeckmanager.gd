# ============================================================
# CreepDeckManager.gd — Autoload
# Manages creep deck selection and creep definitions
# ============================================================
extends Node

signal deck_chosen(player_id: int, deck: Array)
signal card_acquired(player_id: int, creep_id: String)

# ── Creep definitions ─────────────────────────────────────────
# Each entry: id, name, desc, icon, cost, stats, ability_desc, script_path
const ALL_CREEPS : Array = [
	# ── BASE CREEPS (always unlocked) ────────────────────────
	{"id":"zombie",     "name":"Zombie",      "tier":"base", "cost":50,  "icon":"🧟",
	 "desc":"Basic melee zombie. No frills.",
	 "stats":{"hp":80,"dmg":10,"spd":3.2}, "ability":"None",
	 "tags":["swarm", "lane"],
	 "script":"res://scripts/Zombie.gd"},
	{"id":"tank",       "name":"Tank",        "tier":"base", "cost":150, "icon":"🛡",
	 "desc":"High HP. Taunts enemies. Absorbs damage for nearby allies.",
	 "stats":{"hp":350,"dmg":18,"spd":1.4}, "ability":"Taunt + Slam",
	 "tags":["frontline", "taunt"],
	 "script":"res://scripts/TankCreep.gd"},
	{"id":"berserker",  "name":"Berserker",   "tier":"base", "cost":120, "icon":"⚡",
	 "desc":"Enrages below 40% HP — speed and damage spike.",
	 "stats":{"hp":180,"dmg":18,"spd":2.8}, "ability":"Enrage",
	 "tags":["dps", "berserk"],
	 "script":"res://scripts/BerserkerCreep.gd"},
	{"id":"shaman",     "name":"Shaman",      "tier":"base", "cost":130, "icon":"💚",
	 "desc":"Heals nearby allies. Aura regenerates HP over time.",
	 "stats":{"hp":120,"dmg":8,"spd":2.2},  "ability":"Heal Pulse + Aura",
	 "tags":["support", "heal"],
	 "script":"res://scripts/ShamanCreep.gd"},
	{"id":"leaper",     "name":"Leaper",      "tier":"base", "cost":100, "icon":"🦘",
	 "desc":"Leaps at enemies from range. Slows on land.",
	 "stats":{"hp":100,"dmg":16,"spd":3.5}, "ability":"Leap + Slow",
	 "tags":["flanker", "mobility"],
	 "script":"res://scripts/LeaperCreep.gd"},
	# ── ADVANCED CREEPS (unlocked — all available for now) ───
	{"id":"bomber",     "name":"Bomber",      "tier":"advanced", "cost":200, "icon":"💣",
	 "desc":"Runs into enemies and explodes dealing AoE damage.",
	 "stats":{"hp":90,"dmg":80,"spd":4.0},  "ability":"Suicide Bomb",
	 "tags":["aoe", "death"],
	 "script":"res://scripts/BomberCreep.gd"},
	{"id":"ghost",      "name":"Ghost",       "tier":"advanced", "cost":180, "icon":"👻",
	 "desc":"Phases through walls. Invisible until attacking.",
	 "stats":{"hp":70,"dmg":22,"spd":5.0},  "ability":"Phase + Stealth",
	 "tags":["stealth", "bypass"],
	 "script":"res://scripts/GhostCreep.gd"},
	{"id":"goliath",    "name":"Goliath",     "tier":"advanced", "cost":350, "icon":"🗿",
	 "desc":"Massive HP. Stomps ground stunning nearby enemies.",
	 "stats":{"hp":600,"dmg":30,"spd":1.0}, "ability":"Stomp Stun",
	 "tags":["frontline", "tank"],
	 "script":"res://scripts/GoliathCreep.gd"},
	{"id":"assassin",   "name":"Assassin",    "tier":"advanced", "cost":220, "icon":"🗡",
	 "desc":"Targets lowest HP enemy. Crits from stealth.",
	 "stats":{"hp":90,"dmg":45,"spd":4.5},  "ability":"Mark + Backstab",
	 "tags":["flanker", "dps"],
	 "script":"res://scripts/AssassinCreep.gd"},
	{"id":"hunter",     "name":"Hunter",      "tier":"advanced", "cost":160, "icon":"🏹",
	 "desc":"Ranged attacker. Fires projectiles from distance.",
	 "stats":{"hp":100,"dmg":20,"spd":2.8}, "ability":"Ranged Shot",
	 "tags":["ranged", "kite"],
	 "script":"res://scripts/HunterCreep.gd"},
	{"id":"viper",      "name":"Viper",       "tier":"advanced", "cost":175, "icon":"🐍",
	 "desc":"Poisons on bite. Stacks up to 3 times.",
	 "stats":{"hp":110,"dmg":12,"spd":3.8}, "ability":"Poison Stack",
	 "tags":["poison", "debuff"],
	 "script":"res://scripts/ViperCreep.gd"},
	{"id":"colossus",   "name":"Colossus",    "tier":"advanced", "cost":400, "icon":"⚙",
	 "desc":"Mechanical creep. Immune to slow/poison. Fires rockets.",
	 "stats":{"hp":400,"dmg":40,"spd":1.8}, "ability":"Rocket Barrage",
	 "tags":["frontline", "ranged"],
	 "script":"res://scripts/ColossusCreep.gd"},
	{"id":"wraith",     "name":"Wraith",      "tier":"advanced", "cost":240, "icon":"🌑",
	 "desc":"Shadow damage. Drains HP on hit. Teleports when low.",
	 "stats":{"hp":130,"dmg":28,"spd":4.2}, "ability":"Drain + Blink",
	 "tags":["stealth", "drain"],
	 "script":"res://scripts/WraithCreep.gd"},
	{"id":"necromancer","name":"Necromancer", "tier":"advanced", "cost":300, "icon":"💀",
	 "desc":"Resurrects fallen zombies as weakened copies.",
	 "stats":{"hp":150,"dmg":15,"spd":2.5}, "ability":"Resurrect",
	 "tags":["support", "swarm"],
	 "script":"res://scripts/NecromancerCreep.gd"},
	{"id":"elemental",  "name":"Elemental",   "tier":"advanced", "cost":280, "icon":"🌊",
	 "desc":"Cycles fire/ice/lightning attacks. Each deals bonus damage.",
	 "stats":{"hp":160,"dmg":25,"spd":3.0}, "ability":"Element Cycle",
	 "tags":["dps", "aoe"],
	 "script":"res://scripts/ElementalCreep.gd"},
	{"id":"broodmother","name":"Broodmother", "tier":"advanced", "cost":320, "icon":"🕷",
	 "desc":"Spawns 3 spiderlings on death.",
	 "stats":{"hp":200,"dmg":20,"spd":2.6}, "ability":"Spawn Brood",
	 "tags":["swarm", "death"],
	 "script":"res://scripts/BroodmotherCreep.gd"},
	{"id":"titan",      "name":"Titan",       "tier":"advanced", "cost":500, "icon":"🔥",
	 "desc":"Legendary. Deals fire AoE. Immune to first death.",
	 "stats":{"hp":800,"dmg":55,"spd":1.2}, "ability":"Phoenix + Fire Aura",
	 "tags":["frontline", "juggernaut"],
	 "script":"res://scripts/TitanCreep.gd"},
	{"id":"specter",    "name":"Specter",     "tier":"advanced", "cost":260, "icon":"✨",
	 "desc":"Boosts nearby allied zombie damage by 20%.",
	 "stats":{"hp":120,"dmg":18,"spd":3.3}, "ability":"Aura Boost",
	 "tags":["support", "aura"],
	 "script":"res://scripts/SpecterCreep.gd"},
	{"id":"juggernaut", "name":"Juggernaut",  "tier":"advanced", "cost":380, "icon":"💥",
	 "desc":"Charges in a line knocking back all in path.",
	 "stats":{"hp":500,"dmg":35,"spd":2.0}, "ability":"Charge",
	 "tags":["frontline", "mobility"],
	 "script":"res://scripts/JuggernautCreep.gd"},
	{"id":"plague",     "name":"Plague Doctor","tier":"advanced","cost":290, "icon":"🧪",
	 "desc":"Spreads disease AoE that weakens enemy turrets.",
	 "stats":{"hp":140,"dmg":14,"spd":2.7}, "ability":"Disease Cloud",
	 "tags":["debuff", "aoe"],
	 "script":"res://scripts/PlagueCreep.gd"},
]

const DECK_SIZE      : int = 5   # cards in active deck
const BASE_CREEP_IDS : Array = ["zombie","tank","berserker","shaman","leaper"]

# Player decks: pid → Array of creep ids
var _decks : Dictionary = {}

# Set to true the first time CreepDeckUI shows the how-to tooltip.
# Persisted to disk so it only appears once across sessions.
const _PREFS_PATH : String = "user://creep_deck_prefs.cfg"
var deck_ui_tutorial_seen: bool = false


func _ready() -> void:
	add_to_group("creep_deck_manager")
	_load_prefs()


func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_PREFS_PATH) == OK:
		deck_ui_tutorial_seen = cfg.get_value("prefs", "tutorial_seen", false)


func save_tutorial_seen() -> void:
	deck_ui_tutorial_seen = true
	var cfg := ConfigFile.new()
	cfg.load(_PREFS_PATH)  # preserve any other keys
	cfg.set_value("prefs", "tutorial_seen", true)
	cfg.save(_PREFS_PATH)


func get_all_creeps() -> Array:
	return ALL_CREEPS


func get_base_creeps() -> Array:
	return ALL_CREEPS.filter(func(c): return c["tier"] == "base")


func get_unlocked_creeps(_player_id: int) -> Array:
	# For now all creeps unlocked — lock/unlock system added later
	return ALL_CREEPS


func get_player_deck(pid: int) -> Array:
	# Check GameSettings first — survives scene reload within a session
	var gs := _get_game_settings()
	if is_instance_valid(gs) and "player_decks" in gs:
		if pid in gs.player_decks:
			_decks[pid] = (gs.player_decks as Dictionary)[pid].duplicate()
			return _decks[pid]
	# Fall back to RunSaveManager for cross-session persistence
	var rsm := get_node_or_null("/root/RunSaveManager")
	if is_instance_valid(rsm) and rsm.has_save():
		var saved_deck : Array = rsm.get_player_deck(pid)
		if not saved_deck.is_empty():
			_decks[pid] = saved_deck.duplicate()
			return _decks[pid]
	if pid in _decks: return _decks[pid]
	# Default deck = base creeps
	_decks[pid] = BASE_CREEP_IDS.duplicate()
	return _decks[pid]

func _get_game_settings() -> Node:
	var gs := get_tree().root.get_node_or_null("GameSettings")
	if is_instance_valid(gs): return gs
	return get_tree().get_first_node_in_group("game_settings")


func set_player_deck(pid: int, creep_ids: Array) -> void:
	_decks[pid] = creep_ids.slice(0, DECK_SIZE)
	# Persist to GameSettings so deck survives scene reload within a session
	var gs := _get_game_settings()
	if is_instance_valid(gs) and "player_decks" in gs:
		gs.player_decks[pid] = _decks[pid].duplicate()
	# Persist to RunSaveManager for cross-session save
	var rsm := get_node_or_null("/root/RunSaveManager")
	if is_instance_valid(rsm): rsm.set_player_deck(pid, _decks[pid])
	deck_chosen.emit(pid, _decks[pid])


func get_creep_def(creep_id: String) -> Dictionary:
	for c in ALL_CREEPS:
		if c["id"] == creep_id: return c
	return {}


func add_card_to_deck(pid: int, creep_id: String) -> bool:
	if get_creep_def(creep_id).is_empty(): return false
	var deck := get_player_deck(pid)
	if creep_id in deck: return false
	deck.append(creep_id)
	_decks[pid] = deck
	var gs := _get_game_settings()
	if is_instance_valid(gs) and "player_decks" in gs:
		gs.player_decks[pid] = deck.duplicate()
	var rsm := get_node_or_null("/root/RunSaveManager")
	if is_instance_valid(rsm): rsm.set_player_deck(pid, deck)
	card_acquired.emit(pid, creep_id)
	return true


func get_scene_for_creep(creep_id: String) -> PackedScene:
	var def := get_creep_def(creep_id)
	if def.is_empty(): return null
	var path : String = def.get("script", "")
	if path.is_empty(): return null
	# Try loading as PackedScene (.tscn) first, fall back to script
	var tscn_path := path.replace(".gd", ".tscn")
	if ResourceLoader.exists(tscn_path): return load(tscn_path)
	return null
