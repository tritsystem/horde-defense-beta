# ============================================================
# GhostCreep.gd — extends BaseZombie
# Phases in and out. Becomes untargetable while phased.
# ============================================================
extends BaseZombie
class_name GhostCreep

@export_group("Ghost")
@export var phase_cooldown : float = 6.0
@export var phase_duration : float = 2.0
@export var phase_speed_mult: float = 2.5
@export var drain_range    : float = 4.0
@export var drain_damage   : float = 15.0
@export var drain_cooldown : float = 3.5

var _phase_timer  : float = 0.0
var _drain_timer  : float = 0.0
var _is_phased    : bool  = false
var _base_speed   : float = 0.0

func _ready() -> void:
	max_health      = 280.0
	move_speed      = 3.0
	damage          = 14.0
	attack_range    = 2.0
	attack_cooldown = 1.4
	gold_reward     = 65
	armor_physical  = 0.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_base_speed  = move_speed
	_phase_timer = randf_range(2.0, phase_cooldown)
	_drain_timer = randf_range(1.0, drain_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_phase_timer -= delta
	_drain_timer -= delta
	if _phase_timer <= 0.0 and not _is_phased:
		_phase_timer = phase_cooldown
		_do_phase()
	if _drain_timer <= 0.0:
		_drain_timer = drain_cooldown
		_do_drain()

func _do_phase() -> void:
	_is_phased  = true
	move_speed  = _base_speed * phase_speed_mult
	# Signal BaseZombie to become untargetable if supported
	if has_method("set_invulnerable"): set_invulnerable(true)
	set_collision_layer_value(1, false)
	get_tree().create_timer(phase_duration).timeout.connect(func():
		_is_phased = false
		move_speed = _base_speed
		if has_method("set_invulnerable"): set_invulnerable(false)
		set_collision_layer_value(1, true), CONNECT_ONE_SHOT)

func _do_drain() -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		if (u as Node3D).global_position.distance_to(global_position) > drain_range: continue
		if u.has_method("take_damage"):
			u.take_damage(drain_damage, self)
			health = minf(health + drain_damage * 0.5, max_health)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(drain_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)
				
