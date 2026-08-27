# ============================================================
# CreepDeckManager.gd — Autoload
# Manages creep deck selection and creep definitions
# ============================================================
extends Node

signal deck_chosen(player_id: int, deck: Array)
signal card_acquired(player_id: int, creep_id: String)

# ── Creep definitions ─────────────────────────────────────────
# REAL BUG FIX (2026-08-24): this used to list 20 "creep" entries whose
# `script` fields pointed at res://scripts/*Creep.gd -- NONE of those 20
# files exist on disk (confirmed: not even the .gd, let alone a matching
# .tscn), so this whole catalogue was pure aspirational scaffolding that
# was never actually connected to anything spawnable. The player's real,
# working purchasable creep roster is exactly the 5 non-boss entries in
# scenes/ui.tscn's defend_creep_scenes/labels/costs export (Zombie, Tank,
# Shaman, Berserker, Leaper -- BOSSMAN is a 6th, boss-only unit,
# deliberately excluded from normal deck unlocking). Trimmed to match
# what's actually real, "cost" now means "per-unit purchase price during
# a match" (matches defend_creep_costs exactly) -- progressive UNLOCK
# pricing (getting a new type into your deck in the first place) is
# handled separately below via get_unlock_cost()/get_next_unlockable().
const ALL_CREEPS : Array = [
	{"id":"zombie",    "name":"Zombie",    "cost":100, "icon":"🧟",
	 "desc":"Basic melee zombie. No frills.",
	 "ability":"None"},
	{"id":"tank",      "name":"Tank",      "cost":300, "icon":"🛡",
	 "desc":"High HP frontline. Absorbs damage for nearby allies.",
	 "ability":"Taunt"},
	{"id":"shaman",    "name":"Shaman",    "cost":200, "icon":"💚",
	 "desc":"Heals nearby allies over time.",
	 "ability":"Heal Aura"},
	{"id":"berserker", "name":"Berserker", "cost":250, "icon":"⚡",
	 "desc":"Enrages below 40% HP — speed and damage spike.",
	 "ability":"Enrage"},
	{"id":"leaper",    "name":"Leaper",    "cost":300, "icon":"🦘",
	 "desc":"Leaps at enemies from range. Slows on land.",
	 "ability":"Leap + Slow"},
]

const DECK_SIZE      : int = 5   # cards in active deck (== all real types, for now)
# Only the zombie starts unlocked -- everything else is earned by spending
# gold to unlock it (see get_unlock_cost/get_next_unlockable/unlock_next),
# one at a time, each successive unlock costing more than the last.
const BASE_CREEP_IDS : Array = ["zombie"]
# Fixed unlock order for the 4 non-starter real creeps.
const UNLOCK_ORDER   : Array = ["tank", "shaman", "berserker", "leaper"]
const UNLOCK_BASE_COST  : int = 200   # cost of the 1st unlock beyond the starter
const UNLOCK_COST_MULT  : float = 2.0 # each successive unlock costs this much more

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


func get_unlocked_creeps(player_id: int) -> Array:
	var deck : Array = get_player_deck(player_id)
	return ALL_CREEPS.filter(func(c): return c["id"] in deck)


## Next creep the player hasn't unlocked yet, in fixed UNLOCK_ORDER, or ""
## if every real creep type is already in their deck.
func get_next_unlockable(player_id: int) -> String:
	var deck : Array = get_player_deck(player_id)
	for id in UNLOCK_ORDER:
		if not (id in deck): return id
	return ""


## Progressive pricing: the Nth unlock beyond the free starter costs
## UNLOCK_BASE_COST * UNLOCK_COST_MULT^(N-1) -- 200, 400, 800, 1600 for the
## 4 real non-starter creeps, so building out a full personal roster is a
## real, escalating gold sink across a run rather than a one-time cost.
func get_unlock_cost(player_id: int) -> int:
	var already_unlocked : int = get_player_deck(player_id).size() - 1   # minus the free starter
	already_unlocked = maxi(already_unlocked, 0)
	return int(round(UNLOCK_BASE_COST * pow(UNLOCK_COST_MULT, already_unlocked)))


## Actually unlocks the next creep in line for this player, permanently
## adding it to their deck (persists the same way add_card_to_deck always
## has -- GameSettings for this session, RunSaveManager across sessions).
## Caller is responsible for actually spending the gold first.
func unlock_next(player_id: int) -> String:
	var next_id : String = get_next_unlockable(player_id)
	if next_id == "": return ""
	add_card_to_deck(player_id, next_id)
	return next_id


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
