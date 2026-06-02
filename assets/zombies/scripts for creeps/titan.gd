# ============================================================
# TitanCreep.gd — extends BaseZombie
# Boss-tier. Immune to CC. Periodic shockwave. Gets stronger
# each time it kills a unit.
# ============================================================
extends BaseZombie
class_name TitanCreep

@export_group("Titan")
@export var shockwave_radius  : float = 7.0
@export var shockwave_damage  : float = 55.0
@export var shockwave_cooldown: float = 6.0
@export var power_per_kill    : float = 0.05   # +5% damage per kill, stacks
@export var max_power_stacks  : int   = 20
@export var tremor_range      : float = 12.0   # passive tremor slows nearby

var _shockwave_timer : float = 0.0
var _power_stacks    : int   = 0

func _ready() -> void:
	max_health      = 4000.0
	move_speed      = 1.5
	damage          = 50.0
	attack_range    = 3.0
	attack_cooldown = 2.0
	gold_reward     = 300
	armor_physical  = 30.0
	armor_slash     = 25.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_shockwave_timer = randf_range(2.0, shockwave_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_shockwave_timer -= delta
	if _shockwave_timer <= 0.0:
		_shockwave_timer = shockwave_cooldown
		_do_shockwave()
	_passive_tremor()

# CC immunity
func apply_stun(_duration: float) -> void: pass
func apply_slow(_mult: float, _duration: float) -> void: pass

func _do_shockwave() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		var d := (u as Node3D).global_position.distance_to(global_position)
		if d > shockwave_radius: continue
		var dmg := shockwave_damage * (1.0 + power_per_kill * _power_stacks)
		if u.has_method("take_damage"):
			u.take_damage(dmg, self)
		if u is CharacterBody3D:
			var kb := ((u as Node3D).global_position - global_position).normalized()
			(u as CharacterBody3D).velocity += (kb + Vector3(0,0.4,0)) * (12.0 - d)
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(dmg, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)

func _passive_tremor() -> void:
	# Slow enemies just by proximity
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		var d := (u as Node3D).global_position.distance_to(global_position)
		if d > tremor_range: continue
		# Progressive slow based on proximity
		var slow_mult := lerpf(0.3, 0.9, d / tremor_range)
		if "move_speed" in u:
			var base := u.get("move_speed") if u.get("move_speed") > 0.5 else 3.0
			u.set("move_speed", maxf(0.3, base * slow_mult))

# Called externally when titan kills something
func on_kill() -> void:
	_power_stacks = mini(_power_stacks + 1, max_power_stacks)
