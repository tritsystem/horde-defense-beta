# ============================================================
# QuestManager.gd — Autoload
# In-game competitions / quests with rewards
# ============================================================
extends Node

signal quest_completed(quest: Dictionary, player_id: int)
signal quest_progress(quest: Dictionary, player_id: int, current: int)
signal new_quest_available(quest: Dictionary)
signal ally_choice_available(player_id: int)

const QUEST_POOL : Array = [
	# Zombie kills
	{"id":"z_kills_10",  "label":"Zombie Slayer I",    "type":"zombie_kills",   "target":10,  "reward_gold":80,  "reward_crystals":3,  "icon":"🧟"},
	{"id":"z_kills_25",  "label":"Zombie Slayer II",   "type":"zombie_kills",   "target":25,  "reward_gold":150, "reward_crystals":6,  "icon":"🧟"},
	{"id":"z_kills_50",  "label":"Zombie Slayer III",  "type":"zombie_kills",   "target":50,  "reward_gold":300, "reward_crystals":12, "icon":"🧟"},
	# Headshots
	{"id":"hs_5",        "label":"Sharpshooter I",     "type":"headshots",      "target":5,   "reward_gold":100, "reward_crystals":4,  "icon":"🎯"},
	{"id":"hs_15",       "label":"Sharpshooter II",    "type":"headshots",      "target":15,  "reward_gold":200, "reward_crystals":8,  "icon":"🎯"},
	{"id":"hs_30",       "label":"Headhunter",         "type":"headshots",      "target":30,  "reward_gold":400, "reward_crystals":15, "icon":"🎯"},
	# Take little damage
	{"id":"nodmg_wave",  "label":"Untouchable",        "type":"survive_nodmg",  "target":1,   "reward_gold":200, "reward_crystals":8,  "icon":"🛡"},
	{"id":"low_hp_kill", "label":"Last Stand",         "type":"kill_at_low_hp", "target":5,   "reward_gold":150, "reward_crystals":6,  "icon":"💀"},
	# Turret kills
	{"id":"turret_k_1",  "label":"Demolisher",         "type":"turret_kills",   "target":1,   "reward_gold":250, "reward_crystals":10, "icon":"💥"},
	{"id":"turret_k_3",  "label":"Base Breaker",       "type":"turret_kills",   "target":3,   "reward_gold":500, "reward_crystals":20, "icon":"💥"},
	# Sword enchant kills
	{"id":"enchant_k_5", "label":"Elemental Master",   "type":"enchant_kills",  "target":5,   "reward_gold":120, "reward_crystals":5,  "icon":"✦"},
	{"id":"enchant_k_15","label":"Spellblade",         "type":"enchant_kills",  "target":15,  "reward_gold":250, "reward_crystals":10, "icon":"✦"},
	# Speed run
	{"id":"kill_30s",    "label":"Blitz",              "type":"kills_in_time",  "target":3,   "reward_gold":180, "reward_crystals":7,  "icon":"⚡", "window":30.0},
	# Squad
	{"id":"squad_10",    "label":"Commander",          "type":"squad_kills",    "target":10,  "reward_gold":200, "reward_crystals":8,  "icon":"🧠"},
	# Ally choice ("Call of the Wild") REMOVED from the quest pool -- the
	# rat/bat pack choice (AllyChoiceUI.gd) is no longer quest-gated at
	# all, per "should be an option given right off the start, no quest
	# requirement". It now fires directly at round 1 start instead (see
	# game_phase_script.gd's StateCombat.enter()). reward_type
	# "ally_choice" handling stays in _complete_quest() below in case this
	# is ever re-added as an actual quest later, it's just unreferenced
	# by the pool for now.
]

# Active quests per player_id
var _active   : Dictionary = {}   # pid → [quest_dict]
var _progress : Dictionary = {}   # pid → {quest_id → int}
var _completed: Dictionary = {}   # pid → [quest_id]

const MAX_ACTIVE := 3

func _ready() -> void:
	add_to_group("quest_manager")

func register_player(pid: int) -> void:
	if pid in _active: return
	_active[pid]    = []
	_progress[pid]  = {}
	_completed[pid] = []
	_assign_quests(pid)

func _assign_quests(pid: int) -> void:
	var pool : Array = QUEST_POOL.filter(func(q): return not (q["id"] in _completed.get(pid, [])))
	pool.shuffle()
	var count := 0
	for q in pool:
		if count >= MAX_ACTIVE: break
		var already : bool = false
		for aq in _active.get(pid, []):
			if aq["id"] == q["id"]: already = true; break
		if already: continue
		_active[pid].append(q.duplicate())
		_progress[pid][q["id"]] = 0
		count += 1
	new_quest_available.emit(_active.get(pid, []))

func record_event(pid: int, event_type: String, amount: int = 1, context: Dictionary = {}) -> void:
	if pid not in _active: register_player(pid)
	var to_complete : Array = []
	for q in _active.get(pid, []):
		if q["type"] != event_type: continue
		var qid : String = q["id"]
		_progress[pid][qid] = _progress[pid].get(qid, 0) + amount
		quest_progress.emit(q, pid, _progress[pid][qid])
		if _progress[pid][qid] >= q["target"]:
			to_complete.append(q)
	for q in to_complete:
		_complete_quest(pid, q)

func _complete_quest(pid: int, q: Dictionary) -> void:
	_active[pid].erase(q)
	_completed[pid].append(q["id"])
	quest_completed.emit(q, pid)

	if q.get("reward_type", "") == "ally_choice":
		# Special reward -- no flat gold/crystals, let a UI (AllyChoiceUI)
		# handle the actual choice + spawn.
		ally_choice_available.emit(pid)
	else:
		# Give rewards
		var gm := get_tree().get_first_node_in_group("game_manager")
		if is_instance_valid(gm) and gm.has_method("add_gold"):
			gm.add_gold(pid, q.get("reward_gold", 0))  # pid used as team_id approximation
		# Give crystals to player
		for p in get_tree().get_nodes_in_group("player"):
			if "player_id" in p and int(p.get("player_id")) == pid:
				if p.has_method("add_crystal"):
					p.add_crystal(q.get("reward_crystals", 0))
				break
	# Assign new quest to replace
	get_tree().create_timer(2.0).timeout.connect(func(): _assign_quests(pid))

func get_active_quests(pid: int) -> Array:
	return _active.get(pid, [])

func get_progress(pid: int, quest_id: String) -> int:
	return _progress.get(pid, {}).get(quest_id, 0)
