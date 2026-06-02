# ============================================================
# StealthCreep.gd — extends BaseZombie
# Goes invisible periodically. First hit out of stealth = massive bonus dmg.
# ============================================================
extends BaseZombie
class_name StealthCreep

@export_group("Stealth")
@export var stealth_cooldown : float = 8.0
@export var stealth_duration : float = 4.0
@export var backstab_mult    : float = 3.5
@export var bleed_dps        : float = 10.0
@export var bleed_duration   : float = 4.0

var _stealth_timer  : float = 0.0
var _is_stealthed   : bool  = false
var _backstab_ready : bool  = false

func _ready() -> void:
	max_health      = 300.0
	move_speed      = 3.5
	damage          = 30.0
	attack_range    = 2.0
	attack_cooldown = 1.0
	gold_reward     = 60
	armor_physical  = 3.0
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")
	_stealth_timer = randf_range(1.0, stealth_cooldown)

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_stealth_timer -= delta
	if _stealth_timer <= 0.0 and not _is_stealthed:
		_stealth_timer = stealth_cooldown
		_go_stealth()

func _go_stealth() -> void:
	_is_stealthed   = true
	_backstab_ready = true
	# Visual: hide from targeting
	if has_method("set_targetable"): set_targetable(false)
	get_tree().create_timer(stealth_duration).timeout.connect(func():
		_is_stealthed = false
		if has_method("set_targetable"): set_targetable(true), CONNECT_ONE_SHOT)

func _do_attack() -> void:
	if not is_instance_valid(target): return
	var dn  := get_tree().get_first_node_in_group("damage_numbers")
	var dmg := damage
	if _backstab_ready:
		dmg             *= backstab_mult
		_backstab_ready  = false
		_is_stealthed    = false
		if has_method("set_targetable"): set_targetable(true)
	if target.has_method("take_damage"):
		target.take_damage(dmg, self)
		if is_instance_valid(dn) and dn.has_method("spawn_number"):
			dn.spawn_number(dmg, target.global_position + Vector3(0,1.5,0), 0, _backstab_ready == false and dmg > damage)
	# Apply bleed
	_apply_bleed(target)

func _apply_bleed(u: Node) -> void:
	var dn := get_tree().get_first_node_in_group("damage_numbers")
	for i in int(bleed_duration):
		get_tree().create_timer(float(i + 1)).timeout.connect(func():
			if not is_instance_valid(u): return
			if u.has_method("take_damage"):
				u.take_damage(bleed_dps, self)
				if is_instance_valid(dn) and dn.has_method("spawn_number"):
					dn.spawn_number(bleed_dps, (u as Node3D).global_position + Vector3(0,1.5,0), 1, false),
			CONNECT_ONE_SHOT)
