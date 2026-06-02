# ============================================================
# ThornsCreep.gd — extends BaseZombie
# Reflects a portion of all damage taken back at the attacker.
# Periodically erupts thorns in a burst AoE.
# ============================================================
extends BaseZombie
class_name ThornsCreep

@export_group("Thorns")
@export var reflect_pct    : float = 0.40
@export var burst_radius   : float = 3.0
@export var burst_damage   : float = 45.0
@export var burst_cooldown : float = 7.0
@export var regen_per_sec  : float = 8.0    # passive health regen

var _burst_timer : float = 0.0

func _ready() -> void:
	max_health      = 750.0
	move_speed      = 1.7
	damage          = 18.0
	attack_range    = 2.2
	attack_cooldown = 1.5
	gold_reward     = 65
	armor_physical  = 20.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_burst_timer = randf_range(3.0, burst_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	health = minf(health + regen_per_sec * delta, max_health)
	_burst_timer -= delta
	if _burst_timer <= 0.0:
		_burst_timer = burst_cooldown
		_do_burst()

# Override take_damage to add reflect
func take_damage(amount: float, source) -> void:
	super.take_damage(amount, source)
	if not is_instance_valid(source): return
	var reflected := amount * reflect_pct
	if source.has_method("take_damage"):
		source.take_damage(reflected, self)
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	if is_instance_valid(dn) and dn.has_method("spawn_number"):
		dn.spawn_number(reflected, (source as Node3D).global_position + Vector3(0,1.5,0), 0, false)

func _do_burst() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > burst_radius: continue
		if u.has_method("take_damage"):
			u.take_damage(burst_damage, self)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(burst_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)
