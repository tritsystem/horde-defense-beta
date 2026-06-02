# ============================================================
# MirrorCreep.gd — extends BaseZombie
# Scans enemies on spawn and copies the strongest one's stats.
# Reflects a debuff back on whoever debuffs it.
# ============================================================
extends BaseZombie
class_name MirrorCreep

@export_group("Mirror")
@export var copy_radius     : float = 20.0
@export var copy_stat_mult  : float = 0.75   # copies at 75% of target stats
@export var reflect_cooldown: float = 8.0
@export var reflect_radius  : float = 5.0
@export var reflect_damage  : float = 40.0
@export var mimic_cooldown  : float = 12.0   # re-scan and re-copy

var _reflect_timer : float = 0.0
var _mimic_timer   : float = 0.0

func _ready() -> void:
	max_health      = 400.0
	move_speed      = 2.8
	damage          = 20.0
	attack_range    = 2.2
	attack_cooldown = 1.3
	gold_reward     = 70
	armor_physical  = 5.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_reflect_timer = randf_range(2.0, reflect_cooldown)
	_mimic_timer   = mimic_cooldown
	# Copy on spawn
	call_deferred("_copy_strongest")

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_reflect_timer -= delta
	_mimic_timer   -= delta
	if _reflect_timer <= 0.0:
		_reflect_timer = reflect_cooldown
		_do_reflect()
	if _mimic_timer <= 0.0:
		_mimic_timer = mimic_cooldown
		_copy_strongest()

func _copy_strongest() -> void:
	var best     : Node  = null
	var best_hp  : float = 0.0
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > copy_radius: continue
		if "max_health" in u and u.get("max_health") > best_hp:
			best_hp = u.get("max_health"); best = u
	if not is_instance_valid(best): return
	# Copy key stats at reduced fraction
	var stats := ["max_health","move_speed","damage","attack_range","attack_cooldown","armor_physical"]
	for stat in stats:
		if stat in best and stat in self:
			set(stat, best.get(stat) * copy_stat_mult)
	# Re-sync health to new max
	health = max_health

func _do_reflect() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > reflect_radius: continue
		if u.has_method("take_damage"):
			u.take_damage(reflect_damage, self)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(reflect_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)
