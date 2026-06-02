# ============================================================
# SpitterCreep.gd — extends BaseZombie
# Ranged acid spit. Leaves a damaging acid pool on ground.
# ============================================================
extends BaseZombie
class_name SpitterCreep

@export_group("Spitter")
@export var spit_range      : float = 11.0
@export var spit_damage     : float = 20.0
@export var spit_cooldown   : float = 3.0
@export var pool_radius     : float = 2.5
@export var pool_dps        : float = 12.0
@export var pool_duration   : float = 5.0

var _spit_timer : float = 0.0

func _ready() -> void:
	max_health      = 260.0
	move_speed      = 2.3
	damage          = 10.0
	attack_range    = spit_range
	attack_cooldown = spit_cooldown
	gold_reward     = 50
	armor_physical  = 2.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_spit_timer = randf_range(1.0, spit_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_spit_timer -= delta
	if _spit_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= spit_range:
			_spit_timer = spit_cooldown
			_do_spit()

func _do_spit() -> void:
	var hit_pos := target.global_position if is_instance_valid(target) else global_position
	get_tree().create_timer(0.4).timeout.connect(func():
		_hit_immediate(hit_pos)
		_spawn_pool(hit_pos), CONNECT_ONE_SHOT)

func _hit_immediate(pos: Vector3) -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(pos) > pool_radius * 0.5: continue
		if u.has_method("take_damage"):
			u.take_damage(spit_damage, self)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(spit_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)

func _spawn_pool(pos: Vector3) -> void:
	# Tick damage every 1s for pool_duration seconds
	var dn    := get_tree().get_first_node_in_group("damage_numbers")
	var ticks := int(pool_duration)
	for i in ticks:
		get_tree().create_timer(float(i + 1)).timeout.connect(func():
			for u in get_tree().get_nodes_in_group("units"):
				if not is_instance_valid(u) or not ("team_id" in u): continue
				if int(u.get("team_id")) == team_id: continue
				if (u as Node3D).global_position.distance_to(pos) > pool_radius: continue
				if u.has_method("take_damage"):
					u.take_damage(pool_dps, self)
					if is_instance_valid(dn) and dn.has_method("spawn_number"):
						dn.spawn_number(pool_dps, (u as Node3D).global_position + Vector3(0,1.2,0), 3, false),
			CONNECT_ONE_SHOT)
