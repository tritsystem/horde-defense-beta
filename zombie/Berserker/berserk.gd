# ============================================================
# BerserkerCreep.gd — extends BaseZombie AAA
# Fast attacker. Enrages below 40% HP.
# ============================================================
extends "res://assets/weapons/resources/Player/zombie.gd"
class_name BerserkerCreep

@export_group("Berserker")
@export var enrage_threshold    : float = 0.4
@export var enrage_dmg_mult     : float = 1.6
@export var enrage_attack_speed : float = 1.4
# enrage_speed_mult and enrage_sounds inherited from BaseZombie

var _enraged       : bool  = false
var _base_speed    : float = 0.0
var _base_damage   : float = 0.0
var _base_cooldown : float = 0.0

func _ready() -> void:
	max_health      = 280.0
	move_speed      = 5.2
	damage          = 22.0
	attack_range    = 1.8
	attack_cooldown = 0.75
	gold_reward     = 45
	super._ready()
	add_to_group("minions")
	add_to_group("zombies")  # enables enchant + ZHM systems
	_base_speed    = move_speed
	_base_damage   = damage
	_base_cooldown = attack_cooldown

func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if is_dead: return
	_check_enrage()

func _check_enrage() -> void:
	if _enraged: return
	if health / maxf(max_health, 1.0) > enrage_threshold: return
	_enraged = true
	move_speed      = _base_speed    * enrage_speed_mult
	damage          = _base_damage   * enrage_dmg_mult
	attack_cooldown = _base_cooldown / enrage_attack_speed
	# Use the AAA status enrage
	apply_status(StatusType.ENRAGED, 9999.0, enrage_dmg_mult - 1.0)
	_play_sound(enrage_sounds, 8.0)
	# Flash red
	for mi in find_children("*", "MeshInstance3D", true, false):
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.15, 0.05)
		mat.emission_enabled = true; mat.emission = Color(1.0,0.1,0.0)
		mat.emission_energy_multiplier = 3.0
		(mi as MeshInstance3D).material_override = mat
