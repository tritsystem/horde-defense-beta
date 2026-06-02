# ============================================================
# LaserGun.gd — Spawns LaserBolt projectiles
# ============================================================
extends Node3D
class_name LaserGun

@export var max_ammo                  : int   = 30
@export var fire_rate                 : float = 0.15
@export var reload_time               : float = 1.5
@export var damage                    : float = 25.0
@export var recoil                    : float = 2.0
@export var projectile_scene          : PackedScene = null

@export var shoot_sound               : AudioStream = null
@export var shoot_volume_db           : float = 0.0
@export var shoot_pitch_scale         : float = 1.0
@export var shoot_pitch_randomness    : float = 0.0
@export var shoot_volume_randomness   : float = 0.0

@export var reload_sound              : AudioStream = null
@export var reload_volume_db          : float = 0.0
@export var reload_pitch_scale        : float = 1.0
@export var reload_pitch_randomness   : float = 0.0
@export var reload_volume_randomness  : float = 0.0

var current_ammo : int                  = 0
var reloading    : bool                 = false
var cooldown     : bool                 = false
var camera       : Camera3D             = null
var player       : CharacterBody3D      = null
var audio_player : AudioStreamPlayer3D  = null

signal ammo_changed(current: int, maximum: int)

@export var laser_bolt_scene : PackedScene
@export var enable_scope     : bool = true

var _scope  : Node = null
var _scoped : bool = false


func _ready() -> void:
	current_ammo = max_ammo
	# NOTE: Do NOT set visible here. WeaponManager owns all visibility.
	ammo_changed.emit(current_ammo, max_ammo)
	audio_player = AudioStreamPlayer3D.new()
	add_child(audio_player)
	var _bus_idx : int = AudioServer.get_bus_index("Gunshots")
	audio_player.bus = "Gunshots" if _bus_idx >= 0 else "Master"


func equip(cam: Camera3D, ply: CharacterBody3D) -> void:
	camera    = cam
	player    = ply
	# NOTE: Do NOT set visible here. WeaponManager sets visible after equip().
	reloading = false
	cooldown  = false
	if current_ammo <= 0: current_ammo = max_ammo
	if enable_scope and not is_instance_valid(_scope):
		var scr := load("res://scripts/SniperScope.gd") as Script
		if not is_instance_valid(scr): scr = load("res://SniperScope.gd") as Script
		if is_instance_valid(scr):
			_scope = Node.new(); _scope.set_script(scr); add_child(_scope)
			if _scope.has_method("setup"): _scope.setup(cam, ply)


func unequip() -> void:
	# NOTE: Do NOT set visible here. WeaponManager sets visible before unequip().
	camera = null
	player = null
	if is_instance_valid(audio_player) and audio_player.playing:
		audio_player.stop()
	if is_instance_valid(_scope) and _scope.has_method("scope_out"):
		_scope.scope_out()
	_scoped = false


func shoot() -> void:
	if not _can_shoot(): return
	current_ammo -= 1
	ammo_changed.emit(current_ammo, max_ammo)
	_fire()
	cooldown = true
	get_tree().create_timer(fire_rate).timeout.connect(
		func(): cooldown = false, CONNECT_ONE_SHOT)


func _can_shoot() -> bool:
	if not is_instance_valid(camera) or not is_instance_valid(player): return false
	if cooldown or reloading: return false
	if current_ammo <= 0: reload(); return false
	return true


func _fire() -> void:
	_play_sound(shoot_sound, shoot_volume_db, shoot_pitch_scale,
				shoot_pitch_randomness, shoot_volume_randomness)
	var origin : Vector3
	var dir    : Vector3
	if is_instance_valid(player) and player.has_method("get_shoot_origin"):
		origin = player.get_shoot_origin()
		dir    = player.get_shoot_direction()
	else:
		origin = camera.global_position
		dir    = -camera.global_transform.basis.z

	if is_instance_valid(laser_bolt_scene):
		var bolt : Node = laser_bolt_scene.instantiate()
		get_tree().current_scene.add_child(bolt)
		if bolt.has_method("init"):
			bolt.init(origin, dir, player, damage)
		else:
			bolt.global_position = origin
			if "velocity" in bolt: bolt.set("velocity", dir * 85.0)
	else:
		# Hitscan fallback
		var to    : Vector3 = origin + dir * 2000.0
		var query := PhysicsRayQueryParameters3D.create(origin, to)
		query.collision_mask = 0xFFFFFFFF
		if is_instance_valid(player):
			var rids : Array[RID] = []
			var pn : Node = player
			while is_instance_valid(pn):
				if pn is CollisionObject3D:
					rids.append((pn as CollisionObject3D).get_rid())
				pn = pn.get_parent()
			query.exclude = rids
		var space := get_world_3d().direct_space_state
		var hit   := space.intersect_ray(query)
		if not hit.is_empty():
			var target := _resolve_damageable(hit.collider)
			if is_instance_valid(target) and not _is_friendly(target):
				var dmg : float = damage
				var is_hs : bool = false
				if target is Node3D:
					if hit.position.y >= (target as Node3D).global_position.y + 1.25:
						dmg *= 2.0; is_hs = true
				target.take_damage(dmg, player)
				_show_hitmarker(is_hs)
				if is_instance_valid(player) and player.has_method("cancel_invisibility"):
					player.cancel_invisibility()
				var _etp : int = int(player.get("enchantment")) if is_instance_valid(player) and "enchantment" in player else 0
				var _dn := get_tree().get_first_node_in_group("damage_numbers")
				if is_instance_valid(_dn) and _dn.has_method("spawn_number"):
					_dn.spawn_number(dmg, (target as Node3D).global_position + Vector3(0,1.8,0), _etp, is_hs)

	if is_instance_valid(player) and player.has_method("apply_recoil"):
		player.apply_recoil(recoil * 0.01)


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


func _show_hitmarker(headshot: bool) -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("show_hitmarker"): h.show_hitmarker(headshot); break


func _resolve_damageable(node: Node) -> Node:
	var cur := node
	while is_instance_valid(cur):
		if cur.has_method("take_damage"): return cur
		cur = cur.get_parent()
	return null


func _is_friendly(target: Node) -> bool:
	if not is_instance_valid(player): return false
	var pt : int = int(player.get("team_id") if "team_id" in player else -1)
	var cur := target
	while is_instance_valid(cur):
		if "team_id" in cur: return int(cur.get("team_id")) == pt
		cur = cur.get_parent()
	return false


func apply_player_upgrade(stat: String, amount: float) -> void:
	match stat:
		"damage":       damage     += amount
		"fire_rate":    fire_rate   = maxf(fire_rate   - amount * 0.01, 0.05)
		"reload_speed": reload_time = maxf(reload_time - amount, 0.3)


func _input(event: InputEvent) -> void:
	if not visible or not is_instance_valid(_scope): return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed: _scope.scope_in()
			else:          _scope.scope_out()
			_scoped = _scope.is_scoped()
			get_viewport().set_input_as_handled()
		elif _scoped and mb.pressed and mb.button_index == MOUSE_BUTTON_MIDDLE:
			if _scope.has_method("cycle_zoom"): _scope.cycle_zoom()
			get_viewport().set_input_as_handled()
