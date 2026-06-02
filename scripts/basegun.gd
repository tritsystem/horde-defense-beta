# ============================================================
# BaseGun.gd
# ============================================================
# WeaponManager._process() positions us every frame.
# equip() only sets refs + resets state. Never touch visible.
# ============================================================
extends Node3D
class_name BaseGun

@export var max_ammo    : int   = 30
@export var fire_rate   : float = 0.15
@export var reload_time : float = 1.5
@export var damage      : float = 25.0
@export var recoil      : float = 2.0
@export var projectile_scene : PackedScene = null

@export_group("Viewmodel")
@export var vm_position : Vector3 = Vector3(0.3, -0.25, -0.5)
@export var vm_rotation : Vector3 = Vector3(0.0, 180.0, 0.0)

@export_group("Shoot Sound")
@export var shoot_sound             : AudioStream = null
@export var shoot_volume_db         : float       = 0.0
@export var shoot_pitch_scale       : float       = 1.0
@export var shoot_pitch_randomness  : float       = 0.0
@export var shoot_volume_randomness : float       = 0.0

@export_group("Reload Sound")
@export var reload_sound              : AudioStream = null
@export var reload_volume_db          : float       = 0.0
@export var reload_pitch_scale        : float       = 1.0
@export var reload_pitch_randomness   : float       = 0.0
@export var reload_volume_randomness  : float       = 0.0

var current_ammo : int                 = 0
var reloading    : bool                = false
var cooldown     : bool                = false
var camera       : Camera3D            = null
var player       : CharacterBody3D     = null
var audio_player : AudioStreamPlayer3D = null

signal ammo_changed(current: int, max: int)


func _ready() -> void:
	current_ammo = max_ammo
	visible      = false   # WeaponManager shows us on equip
	ammo_changed.emit(current_ammo, max_ammo)
	audio_player = AudioStreamPlayer3D.new()
	add_child(audio_player)
	audio_player.bus = &"Gunshots"


# WeaponManager calls this after _force_show(). Do NOT touch visible.
func equip(cam: Camera3D, ply: CharacterBody3D) -> void:
	camera    = cam
	player    = ply
	reloading = false
	cooldown  = false
	# WeaponManager._process() sets global_position/basis every frame — no transform here.
	print("[BaseGun] equip '%s' | cam=%s" % [name, cam.name if is_instance_valid(cam) else "NULL"])


func unequip() -> void:
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

func stop_shoot() -> void: pass

func _can_shoot() -> bool:
	if not is_instance_valid(camera):
		push_warning("[BaseGun] '%s': no camera" % name); return false
	if not is_instance_valid(player):
		push_warning("[BaseGun] '%s': no player" % name); return false
	if cooldown or reloading: return false
	if current_ammo <= 0: reload(); return false
	return true


func _fire() -> void:
	_play_sound(shoot_sound, shoot_volume_db, shoot_pitch_scale,
				shoot_pitch_randomness, shoot_volume_randomness)
	var from : Vector3
	var dir  : Vector3
	if is_instance_valid(player) and player.has_method("get_shoot_origin"):
		from = player.get_shoot_origin()
		dir  = player.get_shoot_direction()
	else:
		from = camera.global_position
		dir  = -camera.global_transform.basis.z

	var is_topdown : bool = is_instance_valid(player) and player.get("topdown_mode") == true
	if is_topdown and is_instance_valid(projectile_scene):
		var proj : Node = projectile_scene.instantiate()
		get_tree().current_scene.add_child(proj)
		if proj.has_method("init"): proj.init(from, dir, player, damage)
		if is_instance_valid(player) and player.has_method("apply_recoil"):
			player.apply_recoil(recoil * 0.01)
		return

	var to    := from + dir * 2000.0
	var space := camera.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 0xFFFFFFFF
	if is_instance_valid(player):
		var rids : Array[RID] = []
		var pnode : Node = player
		while is_instance_valid(pnode):
			if pnode is CollisionObject3D: rids.append((pnode as CollisionObject3D).get_rid())
			pnode = pnode.get_parent()
		for child in player.find_children("*", "CollisionObject3D", true, false):
			rids.append((child as CollisionObject3D).get_rid())
		query.exclude = rids

	var hit := space.intersect_ray(query)
	if hit.is_empty(): return

	if multiplayer.is_server() or not multiplayer.has_multiplayer_peer():
		var target := _resolve_damageable(hit.collider)
		var ie3 := get_tree().get_first_node_in_group("impact_effects")
		if is_instance_valid(ie3):
			if ie3.has_method("spawn_hit_spark"): ie3.spawn_hit_spark(hit.position, hit.normal)
			if ie3.has_method("spawn_shell") and is_instance_valid(player):
				ie3.spawn_shell(global_position, player.global_transform.basis.x)
		var ss3 := get_tree().get_first_node_in_group("screen_shake")
		if is_instance_valid(ss3) and ss3.has_method("gun_shot"): ss3.gun_shot()
		if is_instance_valid(target) and is_instance_valid(player):
			if (target.is_in_group("turrets") or target.is_in_group("towers")) \
					and player.has_method("notify_turret_hit_without_rocket"):
				player.notify_turret_hit_without_rocket(target)
		if is_instance_valid(target):
			var dmg : float = damage
			if is_instance_valid(player) and player.has_method("get_damage_multiplier"):
				dmg *= player.get_damage_multiplier()
			if "team_id" in target and is_instance_valid(player):
				if int(target.get("team_id")) == int(player.get("team_id")): return
			var is_headshot : bool = false
			if target is Node3D:
				var target_top : float = (target as Node3D).global_position.y + 1.6
				if hit.position.y >= target_top - 0.35:
					dmg *= 2.0; is_headshot = true
			target.take_damage(dmg, player)
			_show_hitmarker(is_headshot)
			if is_headshot and is_instance_valid(player) and player.has_method("record_quest_event"):
				player.record_quest_event("headshots", 1)

	if is_instance_valid(player) and player.has_method("apply_recoil"):
		player.apply_recoil(recoil * 0.01)


func reload() -> void:
	if reloading or current_ammo == max_ammo: return
	reloading = true
	_play_reload_sound()
	get_tree().create_timer(reload_time).timeout.connect(_on_reload_finished, CONNECT_ONE_SHOT)

func _on_reload_finished() -> void:
	current_ammo = max_ammo; reloading = false
	ammo_changed.emit(current_ammo, max_ammo)


func _play_sound(sound: AudioStream, volume_db: float, pitch_scale: float,
				 pitch_randomness: float, volume_randomness: float) -> void:
	if not is_instance_valid(audio_player) or not sound: return
	audio_player.pitch_scale = pitch_scale  + (randf_range(-pitch_randomness,  pitch_randomness)  if pitch_randomness  > 0 else 0.0)
	audio_player.volume_db   = volume_db    + (randf_range(-volume_randomness, volume_randomness) if volume_randomness > 0 else 0.0)
	audio_player.stream = sound; audio_player.play()

func _play_shoot_sound()  -> void:
	_play_sound(shoot_sound,  shoot_volume_db,  shoot_pitch_scale,  shoot_pitch_randomness,  shoot_volume_randomness)
func _play_reload_sound() -> void:
	_play_sound(reload_sound, reload_volume_db, reload_pitch_scale, reload_pitch_randomness, reload_volume_randomness)


func _resolve_damageable(node: Node) -> Node:
	var cur := node
	while is_instance_valid(cur):
		if cur.has_method("take_damage"): return cur
		cur = cur.get_parent()
	if node is PhysicsBody3D and node.has_method("take_damage"): return node
	var par := node.get_parent()
	if is_instance_valid(par) and par is PhysicsBody3D and par.has_method("take_damage"): return par
	return null

func _show_hitmarker(headshot: bool) -> void:
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("show_hitmarker"): h.show_hitmarker(headshot); break

func get_ammo() -> int: return current_ammo

func apply_player_upgrade(stat: String, amount: float) -> void:
	match stat:
		"damage":       damage      += amount
		"fire_rate":    fire_rate    = maxf(fire_rate   - amount, 0.05)
		"reload_speed": reload_time  = maxf(reload_time - amount, 0.3)
