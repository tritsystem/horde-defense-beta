# ============================================================
# VampireCreep.gd — extends BaseZombie
# Life-steal on every hit. Transforms into bat swarm at low HP.
# ============================================================
extends BaseZombie
class_name VampireCreep

@export_group("Vampire")
@export var lifesteal_pct     : float = 0.45
@export var transform_threshold: float = 0.25
@export var bat_damage        : float = 12.0
@export var bat_radius        : float = 5.0
@export var bat_cooldown      : float = 3.0
@export var charm_range       : float = 7.0
@export var charm_cooldown    : float = 12.0
@export var charm_duration    : float = 3.0

var _bat_timer    : float = 0.0
var _charm_timer  : float = 0.0
var _transformed  : bool  = false

func _ready() -> void:
	max_health      = 450.0
	move_speed      = 3.2
	damage          = 24.0
	attack_range    = 2.0
	attack_cooldown = 1.1
	gold_reward     = 70
	armor_physical  = 5.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_bat_timer   = randf_range(2.0, bat_cooldown)
	_charm_timer = randf_range(4.0, charm_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_bat_timer   -= delta
	_charm_timer -= delta
	if not _transformed and health / max_health <= transform_threshold:
		_transform()
	if _bat_timer <= 0.0 and _transformed:
		_bat_timer = bat_cooldown * 0.5
		_bat_swarm()
	elif _bat_timer <= 0.0:
		_bat_timer = bat_cooldown
	if _charm_timer <= 0.0:
		_charm_timer = charm_cooldown
		_do_charm()

# Override attack to apply lifesteal
func _do_attack() -> void:
	if not is_instance_valid(target): return
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	if target.has_method("take_damage"):
		target.take_damage(damage, self)
		var stolen := damage * lifesteal_pct
		health = minf(health + stolen, max_health)
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(damage, target.global_position + Vector3(0,1.5,0), 0, false)

func _transform() -> void:
	_transformed = true
	move_speed   *= 1.6
	damage       *= 0.7   # bats do less per-hit but AoE

func _bat_swarm() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > bat_radius: continue
		if u.has_method("take_damage"):
			u.take_damage(bat_damage, self)
			health = minf(health + bat_damage * lifesteal_pct, max_health)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(bat_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)

func _do_charm() -> void:
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > charm_range: continue
		# Make enemy attack their own allies
		if u.has_method("set_forced_target"):
			var allies := get_tree().get_nodes_in_group("units")
			for ally in allies:
				if is_instance_valid(ally) and "team_id" in ally and int(ally.get("team_id")) == int(u.get("team_id")) and ally != u:
					u.set_forced_target(ally, charm_duration)
					break
		break   # only charm one target per cast
