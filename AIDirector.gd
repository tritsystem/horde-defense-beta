# ============================================================
# AIDirector.gd — AUTOLOAD
# ============================================================
# "Introduce logic to control ALL AI" -- via a Spiking Neural Network, not
# an LLM (per redirect: an LLM call per-frame for hundreds of units is
# computationally infeasible; spikeling.gd's own header literally
# describes this exact use case -- "a spiking neural network as a live
# mind, e.g. a horde hive-mind").
#
# This is a STRATEGIC layer, not a replacement for the TACTICAL layer
# each zombie/ally already has (their own individual Aggro/Caution/Alert
# brain, added earlier this session -- see zombie.gd's _brain_tick() and
# team_ally.gd's). A real squad commander doesn't aim every soldier's
# rifle; this doesn't either. It reads AGGREGATE battlefield state (how
# close the player is to active hives, how many zombies the horde has
# recently lost, how low the player's base is) and periodically
# broadcasts a fleet-wide strategic push -- push harder, pull back, or go
# for the kill -- while every individual unit keeps making its own
# real-time tactical decisions underneath that.
#
# Ticks on a SLOW cadence (every few seconds), not every physics frame --
# strategic decisions don't need to be instantaneous, and reading/writing
# every active zombie every single frame would be real, unnecessary cost
# for zero behavioral benefit.
# ============================================================
extends Node

const SpikelingScript = preload("res://spikeling.gd")

const TICK_INTERVAL    : float = 3.0
const EFFECT_DURATION  : float = 8.0

# ── Trigger tuning ──────────────────────────────────────────────
const ASSAULT_TRIGGER_RADIUS : float = 60.0   # player within this of an active hive
const REGROUP_LOSS_THRESHOLD : int   = 6      # zombies lost since last tick to trigger Regroup
const OVERWHELM_HEALTH_PCT   : float = 0.35   # player base below this fraction of its first-seen health

# ── Broadcast strength ──────────────────────────────────────────
const ASSAULT_SPEED_MULT    : float = 1.15
const ASSAULT_DAMAGE_MULT   : float = 1.10
const REGROUP_SPEED_MULT    : float = 0.85
const OVERWHELM_SPEED_MULT  : float = 1.30
const OVERWHELM_DAMAGE_MULT : float = 1.25

var brain : Spikeling
var _tick_timer      : float = TICK_INTERVAL
var _assault_timer   : float = 0.0
var _regroup_timer   : float = 0.0
var _overwhelm_timer : float = 0.0
var _prev_z1_count   : int   = -1
var _base_health_baseline : Dictionary = {}   # base node -> first-seen health

signal directive_fired(name: String)


func _ready() -> void:
	add_to_group("ai_director")
	brain = SpikelingScript.new()
	# Overwhelm primes Assault -- a horde already going for the kill also
	# pushes harder overall, not just "extra damage in isolation".
	brain.load_from_text(
		"neuron Assault threshold=100 leak=10\n" +
		"neuron Regroup threshold=100 leak=10\n" +
		"neuron Overwhelm threshold=90 leak=8\n" +
		"synapse Overwhelm -> Assault weight=30\n" +
		"refractory=2\n")
	set_process(true)


func _process(delta: float) -> void:
	_assault_timer   = maxf(0.0, _assault_timer   - delta)
	_regroup_timer   = maxf(0.0, _regroup_timer   - delta)
	_overwhelm_timer = maxf(0.0, _overwhelm_timer - delta)
	_broadcast_to_horde()   # keep multipliers current even between ticks (timers decay every frame)

	_tick_timer -= delta
	if _tick_timer > 0.0: return
	_tick_timer = TICK_INTERVAL
	_director_tick()


func _director_tick() -> void:
	var zhm := get_node_or_null("/root/ZombieHordeManager")
	if not is_instance_valid(zhm): return

	# ── Assault: player deep in horde territory ──────────────────
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if is_instance_valid(player):
		var nearest_hive_dist : float = INF
		for h in get_tree().get_nodes_in_group("hive_clusters"):
			if not is_instance_valid(h) or not (h is Node3D): continue
			if "is_dead" in h and h.get("is_dead"): continue
			var d : float = player.global_position.distance_to((h as Node3D).global_position)
			if d < nearest_hive_dist: nearest_hive_dist = d
		if nearest_hive_dist < ASSAULT_TRIGGER_RADIUS:
			var proximity_signal : float = (ASSAULT_TRIGGER_RADIUS - nearest_hive_dist) / ASSAULT_TRIGGER_RADIUS
			brain.stimulate("Assault", proximity_signal * 60.0)

	# ── Regroup: heavy recent losses ─────────────────────────────
	if zhm.has_method("z1_count"):
		var z1_now : int = zhm.z1_count()
		if _prev_z1_count >= 0:
			var lost : int = _prev_z1_count - z1_now
			if lost >= REGROUP_LOSS_THRESHOLD:
				brain.stimulate("Regroup", float(lost) * 8.0)
		_prev_z1_count = z1_now

	# ── Overwhelm: player base critically low ────────────────────
	# basenode.gd has no separate max_health field (health doubles as its
	# own de-facto ceiling, confirmed earlier this session) -- track each
	# base's first-seen health as an implicit baseline instead of a real max.
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or not ("team_id" in b) or int(b.get("team_id")) != 1: continue
		if not ("health" in b): continue
		var hp : float = float(b.get("health"))
		if not _base_health_baseline.has(b):
			_base_health_baseline[b] = hp
		var baseline : float = float(_base_health_baseline[b])
		if baseline > 0.0:
			var pct : float = hp / baseline
			if pct < OVERWHELM_HEALTH_PCT:
				brain.stimulate("Overwhelm", (OVERWHELM_HEALTH_PCT - pct) * 150.0)

	var fired : Array = brain.step()
	if "Assault" in fired:
		_assault_timer = EFFECT_DURATION
		print("[AIDirector] ASSAULT — horde pushes harder")
		directive_fired.emit("Assault")
	if "Regroup" in fired:
		_regroup_timer = EFFECT_DURATION
		print("[AIDirector] REGROUP — horde pulls back")
		directive_fired.emit("Regroup")
	if "Overwhelm" in fired:
		_overwhelm_timer = EFFECT_DURATION
		print("[AIDirector] OVERWHELM — going for the kill")
		directive_fired.emit("Overwhelm")


## Current strategic multipliers, exposed so allies (team_ally.gd) can
## also react to the same broadcast -- "control ALL AI", not just zombies.
func get_speed_mult() -> float:
	if _overwhelm_timer > 0.0: return OVERWHELM_SPEED_MULT
	if _assault_timer   > 0.0: return ASSAULT_SPEED_MULT
	if _regroup_timer   > 0.0: return REGROUP_SPEED_MULT
	return 1.0

func get_damage_mult() -> float:
	if _overwhelm_timer > 0.0: return OVERWHELM_DAMAGE_MULT
	if _assault_timer   > 0.0: return ASSAULT_DAMAGE_MULT
	return 1.0


func _broadcast_to_horde() -> void:
	var zhm := get_node_or_null("/root/ZombieHordeManager")
	if not is_instance_valid(zhm) or not zhm.has_method("get_z1_active_by_team"): return
	var speed_mult  : float = get_speed_mult()
	var damage_mult : float = get_damage_mult()
	for z in zhm.get_z1_active_by_team(2):
		if is_instance_valid(z) and "director_speed_mult" in z and "director_damage_mult" in z:
			z.set("director_speed_mult", speed_mult)
			z.set("director_damage_mult", damage_mult)
