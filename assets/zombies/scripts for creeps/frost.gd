# ============================================================
# FrostCreep.gd — extends BaseZombie
# Ranged ice bolts. Applies slow stacks. Full stacks = freeze.
# ============================================================
extends BaseZombie
class_name FrostCreep

@export_group("Frost")
@export var bolt_range      : float = 12.0
@export var bolt_damage     : float = 16.0
@export var bolt_cooldown   : float = 1.8
@export var slow_per_stack  : float = 0.15    # speed reduction per stack
@export var max_stacks      : int   = 4
@export var freeze_duration : float = 2.0
@export var stack_duration  : float = 4.0

var _bolt_timer : float = 0.0
# target → [stack_count, timer]
var _frost_stacks : Dictionary = {}

func _ready() -> void:
	max_health      = 290.0
	move_speed      = 2.1
	damage          = 10.0
	attack_range    = bolt_range
	attack_cooldown = bolt_cooldown
	gold_reward     = 55
	armor_physical  = 2.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_bolt_timer = randf_range(0.5, bolt_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_bolt_timer -= delta
	_tick_stacks(delta)
	if _bolt_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= bolt_range:
			_bolt_timer = bolt_cooldown
			_fire_bolt()

func _fire_bolt() -> void:
	if not is_instance_valid(target): return
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	if target.has_method("take_damage"):
		target.take_damage(bolt_damage, self)
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(bolt_damage, target.global_position + Vector3(0,1.5,0), 0, false)
	_add_frost_stack(target)

func _add_frost_stack(u: Node) -> void:
	var id := u.get_instance_id()
	if not _frost_stacks.has(id):
		_frost_stacks[id] = { "node": u, "stacks": 0, "timer": 0.0, "base_speed": u.get("move_speed") if "move_speed" in u else 3.0 }
	var entry = _frost_stacks[id]
	entry["stacks"] = mini(entry["stacks"] + 1, max_stacks)
	entry["timer"]  = stack_duration
	var new_speed := entry["base_speed"] * (1.0 - slow_per_stack * entry["stacks"])
	if "move_speed" in u: u.set("move_speed", maxf(0.2, new_speed))
	if entry["stacks"] >= max_stacks:
		if u.has_method("apply_stun"): u.apply_stun(freeze_duration)
		entry["stacks"] = 0
		entry["timer"]  = 0.0
		if "move_speed" in u: u.set("move_speed", entry["base_speed"])
		_frost_stacks.erase(id)

func _tick_stacks(delta: float) -> void:
	var expired := []
	for id in _frost_stacks:
		var entry = _frost_stacks[id]
		entry["timer"] -= delta
		if entry["timer"] <= 0.0:
			if is_instance_valid(entry["node"]) and "move_speed" in entry["node"]:
				entry["node"].set("move_speed", entry["base_speed"])
			expired.append(id)
	for id in expired: _frost_stacks.erase(id)
