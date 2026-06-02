# ============================================================
# TrapperCreep.gd — extends BaseZombie
# Lays invisible snare traps. Trapped enemies are rooted.
# ============================================================
extends BaseZombie
class_name TrapperCreep

@export_group("Trapper")
@export var trap_cooldown  : float = 5.0
@export var max_traps      : int   = 5
@export var trap_radius    : float = 1.5   # trigger radius
@export var trap_damage    : float = 30.0
@export var root_duration  : float = 2.5
@export var trap_lifetime  : float = 30.0

var _trap_timer : float = 0.0
# Array of {pos, lifetime, triggered}
var _traps      : Array  = []

func _ready() -> void:
	max_health      = 350.0
	move_speed      = 2.8
	damage          = 15.0
	attack_range    = 2.0
	attack_cooldown = 1.2
	gold_reward     = 60
	armor_physical  = 3.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_trap_timer = randf_range(1.0, trap_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_trap_timer -= delta
	if _trap_timer <= 0.0 and _traps.size() < max_traps:
		_trap_timer = trap_cooldown
		_lay_trap()
	_tick_traps(delta)

func _lay_trap() -> void:
	_traps.append({
		"pos": global_position,
		"lifetime": trap_lifetime,
		"triggered": false
	})

func _tick_traps(delta: float) -> void:
	var dn      := get_tree().get_first_node_in_group("damage_numbers")
	var expired := []
	for i in _traps.size():
		var trap = _traps[i]
		trap["lifetime"] -= delta
		if trap["lifetime"] <= 0.0 or trap["triggered"]:
			expired.append(i)
			continue
		var trap_pos : Vector3 = trap["pos"]
		for u in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(u) or not ("team_id" in u): continue
			if int(u.get("team_id")) == team_id: continue
			if (u as Node3D).global_position.distance_to(trap_pos) > trap_radius: continue
			trap["triggered"] = true
			if u.has_method("take_damage"):
				u.take_damage(trap_damage, self)
				if is_instance_valid(dn) and dn.has_method("spawn_number"):
					dn.spawn_number(trap_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)
			# Root: zero speed temporarily
			if "move_speed" in u:
				var orig : float = u.get("move_speed")
				u.set("move_speed", 0.0)
				get_tree().create_timer(root_duration).timeout.connect(
					func(): if is_instance_valid(u): u.set("move_speed", orig), CONNECT_ONE_SHOT)
			if u.has_method("apply_stun"): u.apply_stun(root_duration)
			break
	# Remove in reverse order to keep indices valid
	for i in range(expired.size() - 1, -1, -1):
		_traps.remove_at(expired[i])
