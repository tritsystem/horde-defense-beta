# ============================================================
# RocketGun.gd
# ============================================================
extends Node3D
class_name RocketGun

@export var rocket_scene         : PackedScene
@export var max_ammo             : int   = 6
@export var fire_rate            : float = 1.2
@export var reload_time          : float = 2.5
@export var damage               : float = 25.0
@export var recoil               : float = 4.0
@export var speed                : float = 40.0
@export var explosion_damage     : float = 90.0
@export var explosion_radius     : float = 6.0

@export_group("Viewmodel")
@export var vm_position : Vector3 = Vector3(0.3, -0.25, -0.5)
@export var vm_rotation : Vector3 = Vector3(0.0, 180.0, 0.0)
@export var vm_scale    : Vector3 = Vector3.ONE
@export var vm_kick     : float   = 2.5
@export_group("")

@export var shoot_sound          : AudioStream = null
@export var shoot_volume_db      : float = 0.0
@export var shoot_pitch_scale    : float = 1.0
@export var shoot_pitch_randomness    : float = 0.0
@export var shoot_volume_randomness   : float = 0.0

@export var reload_sound         : AudioStream = null
@export var reload_volume_db     : float = 0.0
@export var reload_pitch_scale   : float = 1.0
@export var reload_pitch_randomness   : float = 0.0
@export var reload_volume_randomness  : float = 0.0

var current_ammo : int   = 0
var reloading    : bool  = false
var cooldown     : bool  = false
var camera       : Camera3D             = null
var player       : CharacterBody3D      = null
var audio_player : AudioStreamPlayer3D  = null

signal ammo_changed(current: int, maximum: int)


func _ready() -> void:
	current_ammo = max_ammo
	# NOTE: Do NOT set visible here. WeaponManager owns all visibility.
	ammo_changed.emit(current_ammo, max_ammo)
	audio_player = AudioStreamPlayer3D.new()
	add_child(audio_player)
	audio_player.bus = &"Gunshots"


func equip(cam: Camera3D, ply: CharacterBody3D) -> void:
	camera    = cam
	player    = ply
	# NOTE: Do NOT set visible here. WeaponManager sets visible after equip().
	reloading = false
	cooldown  = false
	if current_ammo <= 0: current_ammo = max_ammo


func unequip() -> void:
	# NOTE: Do NOT set visible here. WeaponManager sets visible before unequip().
	camera = null
	player = null
	if is_instance_valid(audio_player) and audio_player.playing:
		audio_player.stop()


func shoot() -> void:
	if not _can_shoot(): return
	current_ammo -= 1
	ammo_changed.emit(current_ammo, max_ammo)
	_fire()
	cooldown = true
	get_tree().create_timer(fire_rate).timeout.connect(
		func(): cooldown = false, CONNECT_ONE_SHOT)


func _can_shoot() -> bool:
	if not is_instance_valid(camera) or not is_instance_valid(player):
		push_warning("RocketGun: missing camera or player."); return false
	if cooldown or reloading: return false
	if current_ammo <= 0: reload(); return false
	return true


func _fire() -> void:
	_play_sound(shoot_sound, shoot_volume_db, shoot_pitch_scale,
				shoot_pitch_randomness, shoot_volume_randomness)
	if not is_instance_valid(rocket_scene):
		push_warning("RocketGun: no rocket_scene assigned."); return
	var dir    : Vector3
	var origin : Vector3
	if is_instance_valid(player) and player.has_method("get_shoot_direction"):
		dir    = player.get_shoot_direction()
		origin = player.get_shoot_origin()
	else:
		dir    = -camera.global_transform.basis.z
		origin = camera.global_position + dir * 1.5
	var rocket : Node = rocket_scene.instantiate()
	get_tree().current_scene.add_child(rocket)
	var safe_origin : Vector3 = origin + dir * 1.2
	if rocket.has_method("init"):
		rocket.init(safe_origin, dir, player, explosion_damage, explosion_radius)
	else:
		rocket.global_position = safe_origin
		if "velocity"         in rocket: rocket.set("velocity",         dir * speed)
		if "damage"           in rocket: rocket.set("damage",           explosion_damage)
		if "explosion_radius" in rocket: rocket.set("explosion_radius", explosion_radius)
		if "team_id"          in rocket and is_instance_valid(player) and "team_id" in player:
			rocket.set("team_id", player.get("team_id"))
	if is_instance_valid(player) and player.has_method("apply_recoil"):
		player.apply_recoil(recoil * 0.01)
	if is_instance_valid(player) and player.has_method("cancel_invisibility"):
		player.cancel_invisibility()


func reload() -> void:
	if reloading or current_ammo == max_ammo: return
	reloading = true
	_play_sound(reload_sound, reload_volume_db, reload_pitch_scale,
				reload_pitch_randomness, reload_volume_randomness)
	get_tree().create_timer(reload_time).timeout.connect(
		_on_reload_finished, CONNECT_ONE_SHOT)


func _on_reload_finished() -> void:
	current_ammo = max_ammo
	reloading    = false
	ammo_changed.emit(current_ammo, max_ammo)


func get_ammo() -> int: return current_ammo


func _play_sound(sound: AudioStream, volume_db: float, pitch_scale: float,
				pitch_randomness: float, volume_randomness: float) -> void:
	if not is_instance_valid(audio_player) or not sound: return
	audio_player.pitch_scale = pitch_scale  + randf_range(-pitch_randomness,  pitch_randomness)
	audio_player.volume_db   = volume_db    + randf_range(-volume_randomness, volume_randomness)
	audio_player.stream      = sound
	audio_player.play()


func apply_player_upgrade(stat: String, amount: float) -> void:
	match stat:
		"damage":       explosion_damage  += amount
		"fire_rate":    fire_rate          = maxf(fire_rate   - amount * fire_rate, 0.3)
		"reload_speed": reload_time        = maxf(reload_time - amount, 0.5)
