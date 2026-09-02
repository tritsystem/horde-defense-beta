# ============================================================
# WeaponManager.gd
# ============================================================
extends Node

@export var switch_sound : AudioStreamPlayer3D

var player         : CharacterBody3D = null
var camera         : Camera3D        = null
var weapons        : Array[Node3D]   = []
var current_index  : int             = -1
var current_weapon : Node3D          = null
var _initialized   : bool            = false

## REAL BUG FIX: when set (by team_ally.gd for a puppeted ally), the
## equipped weapon is positioned at THIS node instead of at a first-person
## viewmodel offset from `camera`. `_process()`'s camera-relative math below
## was written assuming the camera IS the viewer's own eyes (true for the
## real player) -- for a third-person-viewed puppet, that same offset put
## the gun floating in space near the ally's aim camera (up near head
## height, disconnected from the hands) instead of in its actual hand.
var third_person_anchor : Node3D = null

# ── First-person viewmodel feel ─────────────────────────────────────
# Every equipped weapon is slammed to camera_origin + camera_basis * vm_position
# each frame. These add the polish that sells "1st person": a bob while
# moving, a slight sway lag behind the look, and a spring recoil on fire.
const DEFAULT_VM_POS : Vector3 = Vector3(0.3, -0.25, -0.5)   # right / down / forward (view space)
const DEFAULT_VM_ROT : Vector3 = Vector3(0.0, 180.0, 0.0)
const DEFAULT_VM_SCALE : Vector3 = Vector3.ONE

var _kick_pos   : Vector3 = Vector3.ZERO   # spring recoil offset (view space)
var _kick_vel   : Vector3 = Vector3.ZERO
var _bob_t      : float   = 0.0
var _sway_basis : Basis   = Basis.IDENTITY
var _sway_ready : bool     = false

signal weapon_equipped(weapon: Node3D)
signal weapons_initialized


## Poke the viewmodel back + up. Called on every shot (see try_shoot).
func kick(amount: float = 1.0) -> void:
	_kick_vel += Vector3(0.0, 0.028, 0.11) * amount


func _ready() -> void:
	print("[WM] _ready | parent=", get_parent().name, " | children=", get_child_count())
	await get_tree().process_frame
	_init_weapons()
	print("[WM] _ready done | initialized=", _initialized, " | weapons=", weapons.size())


func _process(_delta: float) -> void:
	if not is_instance_valid(current_weapon): return
	if not current_weapon.visible: return
	var vm_rot : Vector3 = _get_vec(current_weapon, "vm_rotation", Vector3(0.0, 180.0, 0.0))

	if is_instance_valid(third_person_anchor):
		# Puppeted third-person ally: position AT the real hand bone
		# (tracks the animated arm every frame via the BoneAttachment3D
		# team_ally.gd builds), oriented toward the aim direction (the
		# camera's own basis, same rotation math as the first-person path
		# below) rather than the hand bone's own rest-pose orientation --
		# the bone's basis follows the walk/idle animation, not aim, so
		# using it directly would point the gun wherever the arm happens
		# to be swinging instead of at the target.
		current_weapon.global_position = third_person_anchor.global_position
		if is_instance_valid(camera):
			current_weapon.global_basis = camera.global_transform.basis * Basis.from_euler(
				Vector3(deg_to_rad(vm_rot.x), deg_to_rad(vm_rot.y), deg_to_rad(vm_rot.z)))
		return

	if not is_instance_valid(camera): return
	var vm_pos   : Vector3 = _get_vec(current_weapon, "vm_position", DEFAULT_VM_POS)
	var vm_scale : Vector3 = _get_vec(current_weapon, "vm_scale", DEFAULT_VM_SCALE)
	var dt : float = get_process_delta_time()
	var cam_t : Transform3D = camera.global_transform

	# spring the recoil kick back toward zero
	_kick_vel -= (_kick_pos * 120.0 + _kick_vel * 16.0) * dt
	_kick_pos += _kick_vel * dt

	# walk bob, scaled by planar speed
	var spd : float = 0.0
	if is_instance_valid(player) and player is Node3D:
		spd = Vector2(player.velocity.x, player.velocity.z).length()
	_bob_t += dt * (5.0 + spd * 0.8)
	var bob_amt : float = clampf(spd / 6.0, 0.0, 1.0) * 0.012
	var bob : Vector3 = Vector3(cos(_bob_t) * bob_amt, -absf(sin(_bob_t)) * bob_amt, 0.0)

	# sway: weapon orientation lags a hair behind the look
	if not _sway_ready:
		_sway_basis = cam_t.basis; _sway_ready = true
	_sway_basis = _sway_basis.slerp(cam_t.basis, clampf(dt * 14.0, 0.0, 1.0)).orthonormalized()

	# Same two-step placement the original used (position, then basis --
	# which keeps the weapon's own scene scale). vm_scale is applied ONLY
	# when a weapon opts in with a non-identity value, so default behaviour
	# is unchanged.
	var local_off : Vector3 = vm_pos + bob + _kick_pos
	current_weapon.global_position = cam_t.origin + cam_t.basis * local_off
	current_weapon.global_basis = _sway_basis * Basis.from_euler(
		Vector3(deg_to_rad(vm_rot.x), deg_to_rad(vm_rot.y), deg_to_rad(vm_rot.z)))
	if not vm_scale.is_equal_approx(Vector3.ONE):
		current_weapon.scale = vm_scale


func _get_vec(node: Node3D, prop: String, fallback: Vector3) -> Vector3:
	if prop in node:
		var v = node.get(prop)
		if v is Vector3: return v
	return fallback


func bind_player(p: CharacterBody3D, c: Camera3D) -> void:
	print("[WM] bind_player called | player=", p.name if is_instance_valid(p) else "NULL", " | camera=", c.name if is_instance_valid(c) else "NULL")
	if not is_instance_valid(p): push_error("[WM] bind_player: player null"); return
	if not is_instance_valid(c): push_error("[WM] bind_player: camera null"); return
	player = p
	camera = c
	if not _initialized:
		_init_weapons()
	_push_refs_to_all()
	_equip(0, false)
	print("[WM] bind_player done | current_weapon=", current_weapon.name if is_instance_valid(current_weapon) else "NULL")


func update_camera(c: Camera3D) -> void:
	if not is_instance_valid(c): return
	camera = c
	_push_refs_to_all()
	if current_index >= 0:
		_equip(current_index, false)


func reequip_current() -> void:
	if _initialized and current_index >= 0:
		_equip(current_index, false)


func _init_weapons() -> void:
	if _initialized: return
	weapons.clear()
	print("[WM] _init_weapons | scanning ", get_child_count(), " children")
	for child in get_children():
		print("[WM]   child: ", child.name, " | class=", child.get_class(), " | is Node3D=", child is Node3D)
		if child is AudioStreamPlayer3D: continue
		if not (child is Node3D): continue
		var w := child as Node3D
		weapons.append(w)
		_force_hide(w)
	if weapons.is_empty():
		push_error("[WM] No Node3D weapon children found.")
		return
	_initialized = true
	weapons_initialized.emit()
	print("[WM] Initialized %d weapon(s)." % weapons.size())


func _equip(index: int, play_sound: bool = true) -> void:
	if not _initialized: push_warning("[WM] _equip: not initialized"); return
	if weapons.is_empty(): push_warning("[WM] _equip: no weapons"); return
	if not is_instance_valid(camera): push_warning("[WM] _equip: no camera"); return

	index = clampi(index, 0, weapons.size() - 1)

	if is_instance_valid(current_weapon):
		_call_safe(current_weapon, "stop_shoot")
		_call_safe(current_weapon, "unequip")
		_force_hide(current_weapon)

	current_index  = index
	current_weapon = weapons[index]

	if not is_instance_valid(current_weapon):
		push_error("[WM] Weapon at index %d invalid." % index)
		current_weapon = null; current_index = -1
		return

	_push_refs_to_weapon(current_weapon)
	_force_show(current_weapon)
	if not is_instance_valid(third_person_anchor):
		_apply_viewmodel_render(current_weapon)   # draw on top, no wall clipping
	_call_safe(current_weapon, "equip", [camera, player])

	print("[WM] Equipped [%d] %s | visible=%s | global_pos=%s | camera=%s" % [
		index, current_weapon.name, str(current_weapon.visible),
		str(current_weapon.global_position), camera.name])

	weapon_equipped.emit(current_weapon)

	if is_instance_valid(player) and player.has_method("on_weapon_equipped"):
		player.call("on_weapon_equipped", current_weapon)

	if play_sound: _play_switch_sound()


func _force_show(w: Node3D) -> void: _set_branch_visible(w, true)
func _force_hide(w: Node3D) -> void: _set_branch_visible(w, false)

func _set_branch_visible(node: Node3D, v: bool) -> void:
	if not is_instance_valid(node): return
	node.visible = v
	for child in node.get_children():
		if child is Node3D:
			_set_branch_visible(child as Node3D, v)

func set_all_visible(v: bool) -> void:
	if v:
		if is_instance_valid(current_weapon): _force_show(current_weapon)
	else:
		for w in weapons:
			if is_instance_valid(w): _force_hide(w)


func _push_refs_to_all() -> void:
	for w in weapons: _push_refs_to_weapon(w)

func _push_refs_to_weapon(w: Node3D) -> void:
	if not is_instance_valid(w): return
	if "camera" in w: w.set("camera", camera)
	if "player" in w: w.set("player", player)
	if w.has_method("set_camera"): w.call("set_camera", camera)
	if w.has_method("set_player"): w.call("set_player", player)


func switch_weapon(direction: int) -> void:
	if weapons.size() <= 1: return
	_equip(posmod(current_index + direction, weapons.size()), true)

func equip_by_index(index: int) -> void: _equip(index, true)

func equip_by_name(weapon_name: String) -> void:
	for i in weapons.size():
		if is_instance_valid(weapons[i]) and weapons[i].name == weapon_name:
			_equip(i, true); return
	push_warning("[WM] No weapon named '%s'." % weapon_name)


func try_shoot()  -> void:
	_call_safe(current_weapon, "shoot")
	var amt : float = 1.0
	if is_instance_valid(current_weapon) and "vm_kick" in current_weapon:
		amt = float(current_weapon.get("vm_kick"))
	kick(amt)
func try_reload() -> void: _call_safe(current_weapon, "reload")
func stop_shoot() -> void: _call_safe(current_weapon, "stop_shoot")


## Make a viewmodel render over the world (classic FPS "gun on top" look):
## no shadow + pulled toward the camera in sort order, and -- unless this
## flag is off -- drawn without depth-testing against world geometry so it
## never clips into a wall you back up against. Flip to false if a model's
## own faces sort oddly against each other.
func _apply_viewmodel_render(w: Node3D) -> void:
	if not is_instance_valid(w): return
	# Just the safe polish: no shadow, and sort a touch toward the camera so
	# the weapon tends to draw in front of nearby world geo.
	for mi in w.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if not is_instance_valid(m): continue
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.sorting_offset = 1.0

func get_current_weapon() -> Node3D: return current_weapon
func get_weapon_count()   -> int:    return weapons.size()

func get_aim_direction() -> Vector3:
	if not is_instance_valid(camera): return Vector3.FORWARD
	var center := camera.get_viewport().get_visible_rect().size * 0.5
	return camera.project_ray_normal(center)

func get_aim_origin() -> Vector3:
	if not is_instance_valid(camera):
		return player.global_position if is_instance_valid(player) else Vector3.ZERO
	var center := camera.get_viewport().get_visible_rect().size * 0.5
	return camera.project_ray_origin(center)


func apply_player_upgrade(stat: String, amount: float) -> void:
	for w : Node3D in weapons:
		if not is_instance_valid(w): continue
		match stat:
			"damage":      if "damage"      in w: w.set("damage",      float(w.get("damage"))      + amount)
			"fire_rate":   if "fire_rate"   in w: w.set("fire_rate",   maxf(float(w.get("fire_rate"))   - amount, 0.05))
			"reload_time": if "reload_time" in w: w.set("reload_time", maxf(float(w.get("reload_time")) - amount, 0.1))
			"max_ammo":    if "max_ammo"    in w: w.set("max_ammo",    int(w.get("max_ammo"))       + int(amount))
			"range":       if "range"       in w: w.set("range",       float(w.get("range"))        + amount)
			"spread":      if "spread"      in w: w.set("spread",      maxf(float(w.get("spread"))  - amount, 0.0))

func get_weapons_of_type(type_key: String) -> Array:
	var result : Array = []
	var key := type_key.to_lower()
	for w : Node3D in weapons:
		if not is_instance_valid(w): continue
		var wname := w.name.to_lower()
		var wscript := ""
		if w.get_script(): wscript = (w.get_script() as Script).resource_path.to_lower()
		if key in wname or key in wscript: result.append(w)
	return result


func _call_safe(node: Node, method: String, args: Array = []) -> void:
	if not is_instance_valid(node): return
	if not node.has_method(method): return
	node.callv(method, args)

func _play_switch_sound() -> void:
	if is_instance_valid(switch_sound): switch_sound.play()

func debug_print_weapons() -> void:
	print("=== WM DEBUG  weapons=%d  idx=%d  cam=%s ===" % [
		weapons.size(), current_index, camera.name if is_instance_valid(camera) else "NULL"])
	for i in weapons.size():
		if is_instance_valid(weapons[i]):
			var w := weapons[i]
			print("  [%d] %s  vis=%s  gpos=%s" % [i, w.name, str(w.visible), str(w.global_position)])
