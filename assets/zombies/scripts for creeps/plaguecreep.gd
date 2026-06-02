# ============================================================
# PlagueCreep.gd — extends BaseZombie
# Spreads a contagion DoT that jumps between nearby enemies.
# ============================================================
extends BaseZombie
class_name PlagueCreep

@export_group("Plague")
@export var plague_range    : float = 3.0   # melee application range
@export var plague_cooldown : float = 4.0
@export var plague_dps      : float = 12.0
@export var plague_duration : float = 6.0
@export var spread_radius   : float = 4.0   # how far plague jumps
@export var max_spread_hops : int   = 3
@export var cloud_radius    : float = 3.5
@export var cloud_dps       : float = 8.0
@export var cloud_cooldown  : float = 8.0

var _plague_timer : float = 0.0
var _cloud_timer  : float = 0.0

func _ready() -> void:
	max_health      = 380.0
	move_speed      = 2.6
	damage          = 14.0
	attack_range    = 2.2
	attack_cooldown = 1.3
	gold_reward     = 65
	armor_physical  = 3.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_plague_timer = randf_range(1.0, plague_cooldown)
	_cloud_timer  = randf_range(3.0, cloud_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_plague_timer -= delta
	_cloud_timer  -= delta
	if _plague_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= plague_range + 0.5:
			_plague_timer = plague_cooldown
			_infect(target, max_spread_hops)
	if _cloud_timer <= 0.0:
		_cloud_timer = cloud_cooldown
		_release_cloud()

func _infect(u: Node, hops_left: int) -> void:
	if not is_instance_valid(u) or hops_left <= 0: return
	_apply_dot(u)
	# Spread to nearby enemies
	get_tree().create_timer(1.5).timeout.connect(func():
		for nearby in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(nearby) or nearby == u: continue
			if not ("team_id" in nearby) or int(nearby.get("team_id")) == team_id: continue
			if (nearby as Node3D).global_position.distance_to((u as Node3D).global_position) > spread_radius: continue
			_infect(nearby, hops_left - 1), CONNECT_ONE_SHOT)

func _apply_dot(u: Node) -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for i in int(plague_duration):
		get_tree().create_timer(float(i + 1)).timeout.connect(func():
			if not is_instance_valid(u): return
			if u.has_method("take_damage"):
				u.take_damage(plague_dps, self)
				if is_instance_valid(dn) and dn.has_method("spawn_number"):
					dn.spawn_number(plague_dps, (u as Node3D).global_position + Vector3(0,1.2,0), 3, false),
			CONNECT_ONE_SHOT)

func _release_cloud() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > cloud_radius: continue
		if u.has_method("take_damage"):
			u.take_damage(cloud_dps, self)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(cloud_dps, (u as Node3D).global_position + Vector3(0,1.2,0), 3, false)
