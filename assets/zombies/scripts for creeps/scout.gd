# ============================================================
# ScoutCreep.gd — extends BaseZombie
# Fastest creep. Marks targets so allies deal more damage to them.
# Dashes through groups applying bleed.
# ============================================================
extends BaseZombie
class_name ScoutCreep

@export_group("Scout")
@export var mark_range     : float = 8.0
@export var mark_cooldown  : float = 5.0
@export var mark_duration  : float = 6.0
@export var mark_bonus     : float = 0.25   # +25% damage taken
@export var dash_range     : float = 10.0
@export var dash_cooldown  : float = 6.0
@export var dash_damage    : float = 20.0
@export var bleed_dps      : float = 8.0
@export var bleed_duration : float = 3.0

var _mark_timer  : float = 0.0
var _dash_timer  : float = 0.0
var _is_dashing  : bool  = false

func _ready() -> void:
	max_health      = 200.0
	move_speed      = 5.5
	damage          = 16.0
	attack_range    = 2.0
	attack_cooldown = 0.8
	gold_reward     = 40
	armor_physical  = 0.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_mark_timer = randf_range(1.0, mark_cooldown)
	_dash_timer = randf_range(2.0, dash_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead or _is_dashing: return
	_mark_timer -= delta
	_dash_timer -= delta
	if _mark_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= mark_range:
			_mark_timer = mark_cooldown
			_do_mark(target)
	if _dash_timer <= 0.0 and is_instance_valid(target):
		var d := global_position.distance_to(target.global_position)
		if d <= dash_range and d > attack_range:
			_dash_timer = dash_cooldown
			_do_dash()

func _do_mark(u: Node) -> void:
	# Apply damage amplification
	if "damage_taken_mult" in u:
		var orig : float = u.get("damage_taken_mult")
		u.set("damage_taken_mult", orig + mark_bonus)
		get_tree().create_timer(mark_duration).timeout.connect(
			func(): if is_instance_valid(u): u.set("damage_taken_mult", orig), CONNECT_ONE_SHOT)

func _do_dash() -> void:
	_is_dashing = true
	var dest := target.global_position if is_instance_valid(target) else global_position
	var dir  := (dest - global_position).normalized()
	var dn   := get_tree().get_first_node_in_group("damage_numbers")
	# Hit everyone along the dash path
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		var to_u := (u as Node3D).global_position - global_position
		if to_u.length() > dash_range: continue
		if to_u.normalized().dot(dir) < 0.75: continue
		if u.has_method("take_damage"):
			u.take_damage(dash_damage, self)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(dash_damage, (u as Node3D).global_position + Vector3(0,1.5,0), 0, false)
		_apply_bleed(u)
	global_position = dest
	_is_dashing = false

func _apply_bleed(u: Node) -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for i in int(bleed_duration):
		get_tree().create_timer(float(i + 1)).timeout.connect(func():
			if not is_instance_valid(u): return
			if u.has_method("take_damage"):
				u.take_damage(bleed_dps, self)
				if is_instance_valid(dn) and dn.has_method("spawn_number"):
					dn.spawn_number(bleed_dps, (u as Node3D).global_position + Vector3(0,1.2,0), 1, false),
			CONNECT_ONE_SHOT)
