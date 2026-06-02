# ============================================================
# EliteCreep.gd — extends BaseZombie
# Mini-boss tier. Shield, counter, execute below 20% HP.
# ============================================================
extends BaseZombie
class_name EliteCreep

@export_group("Elite")
@export var shield_amount     : float = 250.0
@export var shield_cooldown   : float = 20.0
@export var counter_window    : float = 0.4    # sec after hit to counter
@export var counter_damage    : float = 60.0
@export var execute_threshold : float = 0.20
@export var execute_bonus_pct : float = 2.0    # multiplier on attacks vs low-HP targets
@export var cleave_arc        : float = 0.6    # dot threshold for cleave (~53 deg)

var _shield_timer   : float = 0.0
var _shield_current : float = 0.0
var _counter_ready  : bool  = false
var _counter_timer  : float = 0.0

func _ready() -> void:
	max_health      = 1500.0
	move_speed      = 2.2
	damage          = 35.0
	attack_range    = 2.8
	attack_cooldown = 1.4
	gold_reward     = 150
	armor_physical  = 20.0
	armor_slash     = 15.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_shield_timer = shield_cooldown

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_shield_timer -= delta
	if _counter_ready:
		_counter_timer -= delta
		if _counter_timer <= 0.0: _counter_ready = false
	if _shield_timer <= 0.0 and _shield_current <= 0.0:
		_shield_timer   = shield_cooldown
		_shield_current = shield_amount

func take_damage(amount: float, source) -> void:
	# Absorb with shield first
	if _shield_current > 0.0:
		var absorbed := minf(amount, _shield_current)
		_shield_current -= absorbed
		amount          -= absorbed
	if amount <= 0.0: return
	super.take_damage(amount, source)
	# Trigger counter window
	_counter_ready = true
	_counter_timer = counter_window
	if is_instance_valid(source) and _counter_ready:
		_do_counter(source)

func _do_counter(source: Node) -> void:
	_counter_ready = false
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	if source.has_method("take_damage"):
		source.take_damage(counter_damage, self)
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(counter_damage, (source as Node3D).global_position + Vector3(0,1.5,0), 0, true)

func _do_attack() -> void:
	if not is_instance_valid(target): return
	var dn  := get_tree().get_first_node_in_group("damage_numbers")
	var dir := (target.global_position - global_position).normalized()
	# Cleave all enemies in arc
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u) or not ("team_id" in u): continue
		if int(u.get("team_id")) == team_id: continue
		var to_u := ((u as Node3D).global_position - global_position)
		if to_u.length() > attack_range + 0.5: continue
		if to_u.normalized().dot(dir) < cleave_arc: continue
		var dmg := damage
		# Execute bonus
		if "health" in u and "max_health" in u:
			if u.get("health") / u.get("max_health") < execute_threshold:
				dmg *= execute_bonus_pct
		if u.has_method("take_damage"):
			u.take_damage(dmg, self)
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(dmg, (u as Node3D).global_position + Vector3(0,1.5,0), 0, dmg > damage)
