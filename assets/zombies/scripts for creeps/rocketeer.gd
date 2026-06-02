# ============================================================
# RocketeerCreep.gd — extends BaseZombie
# Ranged. Fires slow homing rockets with large splash radius.
# ============================================================
extends BaseZombie
class_name RocketeerCreep

@export_group("Rocketeer")
@export var rocket_range    : float = 16.0
@export var rocket_damage   : float = 70.0
@export var rocket_splash   : float = 5.0
@export var rocket_cooldown : float = 6.0
@export var volley_count    : int   = 3       # fires 3 rockets in rapid burst
@export var volley_interval : float = 0.4

var _rocket_timer : float = 0.0

func _ready() -> void:
	max_health      = 280.0
	move_speed      = 2.0
	damage          = 10.0
	attack_range    = rocket_range
	attack_cooldown = rocket_cooldown
	gold_reward     = 75
	armor_physical  = 2.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_rocket_timer = randf_range(2.0, rocket_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_rocket_timer -= delta
	if _rocket_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= rocket_range:
			_rocket_timer = rocket_cooldown
			_fire_volley()

func _fire_volley() -> void:
	for i in volley_count:
		get_tree().create_timer(volley_interval * i).timeout.connect(func():
			if not is_dead and is_instance_valid(target):
				_launch_rocket(target.global_position), CONNECT_ONE_SHOT)

func _launch_rocket(dest: Vector3) -> void:
	# 0.8s travel time, then explode at destination
	get_tree().create_timer(0.8).timeout.connect(func():
		_explode(dest), CONNECT_ONE_SHOT)

func _explode(pos: Vector3) -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(pos) > rocket_splash: continue
		if u.has_method("take_damage"):
			u.take_damage(rocket_damage, self)
			if u is CharacterBody3D:
				var kb := ((u as Node3D).global_position - pos).normalized()
				(u as CharacterBody3D).velocity += (kb + Vector3(0,0.5,0)) * 9.0
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(rocket_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)
