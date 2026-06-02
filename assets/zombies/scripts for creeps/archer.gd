# ============================================================
# ArcherCreep.gd — extends BaseZombie
# Ranged. Fires rapid arrows. Occasional piercing shot.
# ============================================================
extends BaseZombie
class_name ArcherCreep

@export_group("Archer")
@export var shoot_range      : float = 14.0
@export var arrow_damage     : float = 22.0
@export var arrow_cooldown   : float = 1.4
@export var pierce_chance    : float = 0.25   # 0-1
@export var pierce_radius    : float = 1.0    # width of pierce sweep
@export var preferred_dist   : float = 9.0    # tries to stay at this range

var _arrow_timer : float = 0.0

func _ready() -> void:
	max_health      = 240.0
	move_speed      = 2.4
	damage          = 12.0
	attack_range    = shoot_range
	attack_cooldown = arrow_cooldown
	gold_reward     = 45
	armor_physical  = 1.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_arrow_timer = randf_range(0.5, arrow_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	# Kite: back away if target too close
	if is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d < preferred_dist - 1.5:
			var flee := (global_position - target.global_position).normalized()
			velocity += flee * move_speed * delta * 60.0
	_arrow_timer -= delta
	if _arrow_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= shoot_range:
			_arrow_timer = arrow_cooldown
			_fire_arrow()

func _fire_arrow() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	var pierce := randf() < pierce_chance
	if pierce:
		# Hit every enemy along the line to target
		var dir := (target.global_position - global_position).normalized()
		for u in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(u) or not ("team_id" in u): continue
			if int(u.get("team_id")) == team_id: continue
			var to_u := (u as Node3D).global_position - global_position
			if to_u.length() > shoot_range: continue
			if to_u.normalized().dot(dir) < 0.85: continue   # ~32 deg cone
			if u.has_method("take_damage"):
				u.take_damage(arrow_damage * 1.5, self)
				if is_instance_valid(dn) and dn.has_method("spawn_number"):
					dn.spawn_number(arrow_damage * 1.5, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)
	else:
		if target.has_method("take_damage"):
			target.take_damage(arrow_damage, self)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(arrow_damage, target.global_position + Vector3(0,1.5,0), 0, false)
