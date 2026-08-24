# ============================================================
# Sword.gd — Melee weapon with enchantments
# ============================================================
extends Node3D

@export var damage          : float = 85.0
@export var attack_range    : float = 3.8
@export var swing_cooldown  : float = 0.55
@export var knockback_force : float = 18.0

@export_group("Audio")
@export var swing_sounds : Array[AudioStream] = []
@export var hit_sounds   : Array[AudioStream] = []

@export_group("Visuals")
@export var swing_color : Color = Color(0.8, 0.85, 1.0)

@export_group("Skin")
@export var custom_skin : PackedScene = null

@export_group("Viewmodel")
# REAL BUG FIX (2026-07-25): "reconfigure weapons to be positioned all
# correctly and identically" -- every other weapon (gun.gd, rocketgun.gd,
# projectilegun.gd, grapplergun.gd, flamethrower.gd) has no vm_position of
# its own, so WeaponsManager.gd falls back to its shared default
# Vector3(0.3, -0.25, -0.5). This was the one weapon with its own,
# slightly different default (-0.3 instead of -0.25 on Y), rendering the
# sword visibly lower on screen than every gun. Match the shared default.
@export var vm_position : Vector3 = Vector3(0.3, -0.25, -0.5)
@export var vm_rotation : Vector3 = Vector3(0.0, 180.0, 0.0)

# ── enchantment ──────────────────────────────────────────────
enum Enchant { NONE, FIRE, ICE, POISON, ELECTRIC, SHADOW, VAMPIRIC }
var enchantment : int = Enchant.NONE

const ENCHANT_COLORS : Dictionary = {
	Enchant.FIRE:     Color(1.0, 0.3, 0.0),
	Enchant.ICE:      Color(0.3, 0.8, 1.0),
	Enchant.POISON:   Color(0.3, 1.0, 0.2),
	Enchant.ELECTRIC: Color(1.0, 0.95, 0.1),
	Enchant.SHADOW:   Color(0.5, 0.0, 0.8),
	Enchant.VAMPIRIC: Color(0.8, 0.0, 0.2),
}
const ENCHANT_NAMES : Dictionary = {
	Enchant.NONE:     "None",     Enchant.FIRE:     "Fire",
	Enchant.ICE:      "Ice",      Enchant.POISON:   "Poison",
	Enchant.ELECTRIC: "Electric", Enchant.SHADOW:   "Shadow",
	Enchant.VAMPIRIC: "Vampiric",
}

# ── refs ─────────────────────────────────────────────────────
var camera : Camera3D        = null
var player : CharacterBody3D = null

# ── state ────────────────────────────────────────────────────
var _cooldown : bool = false
var _sfx      : AudioStreamPlayer3D = null
var _blade_glow_tweens : Array[Tween] = []

# Satisfies any WeaponManager ammo-signal listener
signal ammo_changed(cur: int, max: int)


# ============================================================
# READY
# ============================================================
func _ready() -> void:
	# Do NOT set visible here — WeaponManager owns visibility.
	_sfx = AudioStreamPlayer3D.new()
	add_child(_sfx)
	_sfx.max_distance = 20.0


# ============================================================
# EQUIP / UNEQUIP
# called by WeaponManager AFTER reparenting this node to Camera3D
# and AFTER setting the whole branch visible = true.
# So: only set refs + local transform here. Do NOT touch visible.
# ============================================================
func equip(cam: Camera3D, ply: CharacterBody3D) -> void:
	camera    = cam
	player    = ply
	_cooldown = false
	position         = vm_position
	rotation_degrees = vm_rotation
	_sword_message("⚔ Sword  [R] cycle enchant  [G] enchant zombies")


func unequip() -> void:
	camera = null
	player = null
	# WeaponManager sets visible = false after this returns


# ============================================================
# SHOOT alias (WeaponManager calls shoot())
# ============================================================
func shoot() -> void:
	swing()

func stop_shoot() -> void:
	pass


# ============================================================
# SWING
# ============================================================
func swing() -> void:
	if _cooldown:
		return
	_cooldown = true
	_play_sfx(swing_sounds)
	_do_swing_vfx()
	_apply_hits()
	# Use a plain SceneTreeTimer — no lambda capture issues
	var t := get_tree().create_timer(swing_cooldown)
	t.timeout.connect(_on_cooldown_done, CONNECT_ONE_SHOT)

func _on_cooldown_done() -> void:
	_cooldown = false


# ============================================================
# HIT DETECTION
# ============================================================
func _apply_hits() -> void:
	if not is_instance_valid(player):
		push_warning("[Sword] player null")
		return

	var origin  : Vector3 = player.global_position + Vector3.UP * 1.0
	var my_team : int = int(player.get("team_id") if "team_id" in player else 1)
	var hit_any : bool = false

	for group in ["zombies", "units", "players", "minions"]:
		for node in get_tree().get_nodes_in_group(group):
			if not is_instance_valid(node): continue
			if not node is Node3D: continue
			if node == player: continue
			if "team_id" in node and int(node.get("team_id")) == my_team: continue
			if node.has_method("is_dead") and node.is_dead(): continue
			if not node.has_method("take_damage"): continue

			var dist : float = origin.distance_to((node as Node3D).global_position)
			if dist > attack_range: continue

			# Damage
			var dmg : float = damage
			if player.has_method("get_damage_multiplier"):
				dmg *= player.get_damage_multiplier()
			if player.has_method("get_enchant_mult"):
				dmg *= player.get_enchant_mult(enchantment)
			node.take_damage(dmg, player)

			# Knockback
			var kb_dir : Vector3 = (node as Node3D).global_position - origin
			kb_dir.y = 0.25
			kb_dir = kb_dir.normalized()
			if node.has_method("apply_knockback"):
				node.apply_knockback(kb_dir * knockback_force)
			elif node is CharacterBody3D:
				(node as CharacterBody3D).velocity += kb_dir * knockback_force

			# Enchantment
			_apply_enchantment(node, dmg)

			# Screen shake
			var ss := get_tree().get_first_node_in_group("screen_shake")
			if is_instance_valid(ss): ss.shake(0.18, 0.12)

			# Hit-stop on kill
			if "health" in node and float(node.get("health")) <= 0.0:
				Engine.time_scale = 0.05
				get_tree().create_timer(0.04, true, false, true).timeout.connect(
					func(): Engine.time_scale = 1.0, CONNECT_ONE_SHOT)
				# REAL FEATURE (2026-07-24): "sword slice" dismemberment.
				# Melee hits here are proximity-based (no raycast/arc data),
				# so there's no real "which limb" signal like the gun's
				# precise hitbox system has -- a killing sword blow
				# decapitates instead, a real flourish using the same
				# detach_limb()/partial-ragdoll mechanism, not a fake effect.
				if node.has_method("detach_limb"):
					var slice_dir : Vector3 = (node as Node3D).global_position - origin
					slice_dir.y = 0.0
					node.call("detach_limb", "head", slice_dir)

			_play_sfx(hit_sounds)
			hit_any = true

	if hit_any:
		for h in get_tree().get_nodes_in_group("hud"):
			if h.has_method("show_hitmarker"):
				h.show_hitmarker(false)
				break

# ============================================================
# ENCHANTMENT
# ============================================================
func _apply_enchantment(target: Node, base_dmg: float) -> void:
	match enchantment:
		Enchant.FIRE:
			_start_dot(target, base_dmg * 0.25, 4, 0.8, Color(1.0, 0.3, 0.0))
		Enchant.ICE:
			if target.has_method("apply_slow"):
				target.apply_slow(0.4, 3.0)
			_flash_enchant(target, Color(0.3, 0.8, 1.0))
		Enchant.POISON:
			_start_dot(target, base_dmg * 0.15, 6, 1.0, Color(0.2, 0.9, 0.1))
		Enchant.ELECTRIC:
			_flash_enchant(target, Color(1.0, 0.95, 0.1))
			_chain_lightning(target, base_dmg * 0.5)
		Enchant.SHADOW:
			if "health" in target and "max_health" in target:
				if float(target.get("health")) / float(target.get("max_health")) < 0.5:
					target.take_damage(base_dmg, player)
			_flash_enchant(target, Color(0.5, 0.0, 0.8))
		Enchant.VAMPIRIC:
			if is_instance_valid(player) and "health" in player and "max_health" in player:
				var heal : float = base_dmg * 0.3
				player.health = minf(float(player.health) + heal, float(player.max_health))
				if player.has_signal("health_changed"):
					player.health_changed.emit(player.health, player.max_health)
			_flash_enchant(target, Color(0.8, 0.0, 0.2))


# ── DoT — avoid nested-lambda capture bugs by using a dedicated helper ──
func _start_dot(target: Node, dmg: float, ticks: int, interval: float, col: Color) -> void:
	_flash_enchant(target, col)
	_dot_tick(target, dmg, ticks, 0, interval, col)

func _dot_tick(target: Node, dmg: float, total: int, current: int, interval: float, col: Color) -> void:
	if not is_instance_valid(target):
		return
	if target.has_method("is_dead") and target.is_dead():
		return
	target.take_damage(dmg, player)
	if current + 1 < total:
		var t := get_tree().create_timer(interval)
		# Store args in a bound callable — no closure capture issues
		t.timeout.connect(_dot_tick.bind(target, dmg, total, current + 1, interval, col), CONNECT_ONE_SHOT)


func _chain_lightning(origin_target: Node, dmg: float) -> void:
	if not (origin_target is Node3D):
		return
	var origin_pos : Vector3 = (origin_target as Node3D).global_position
	var my_team    : int     = int(player.get("team_id") if "team_id" in player else 1)
	# REAL BUG FIX: this only ever searched the "minions" group, but real
	# zombies are tagged "zombies"/"units" (see zombie.gd's _ready()) --
	# "minions" isn't a group anything in this project actually joins, so
	# Electric enchant's chain lightning could never hit a real zombie, the
	# entire enemy type in this game. Search the same groups _apply_hits()
	# already uses for the initial swing hit.
	var seen : Dictionary = {}
	for group in ["zombies", "units", "players", "minions"]:
		for node in get_tree().get_nodes_in_group(group):
			if node == origin_target or not is_instance_valid(node) or seen.has(node):
				continue
			seen[node] = true
			if not (node is Node3D):
				continue
			if "team_id" in node and int(node.get("team_id")) == my_team:
				continue
			if (node as Node3D).global_position.distance_to(origin_pos) > 4.0:
				continue
			if node.has_method("take_damage"):
				node.take_damage(dmg, player)
			_flash_enchant(node, Color(1.0, 0.95, 0.1))


func _flash_enchant(target: Node, col: Color) -> void:
	for mi in (target as Node).find_children("*", "MeshInstance3D", true, false):
		var mesh := mi as MeshInstance3D
		for s in mesh.get_surface_override_material_count():
			var flash := StandardMaterial3D.new()
			flash.shading_mode             = BaseMaterial3D.SHADING_MODE_UNSHADED
			flash.albedo_color             = col
			flash.emission_enabled         = true
			flash.emission                 = col
			flash.emission_energy_multiplier = 5.0
			mesh.set_surface_override_material(s, flash)
			var ms : int = s
			get_tree().create_timer(0.18).timeout.connect(
				func(): if is_instance_valid(mesh): mesh.set_surface_override_material(ms, null),
				CONNECT_ONE_SHOT)


func set_enchantment(e: int) -> void:
	enchantment = e
	if e == Enchant.NONE:
		# Stop any running glow tweens first -- otherwise a tween can still
		# try to animate material_override:emission_energy_multiplier right
		# after material_override was just set to null here.
		for old_tw in _blade_glow_tweens:
			if is_instance_valid(old_tw):
				old_tw.kill()
		_blade_glow_tweens.clear()
		for mesh in find_children("*", "MeshInstance3D", true, false):
			(mesh as MeshInstance3D).material_override = null
	else:
		_update_blade_color()
	_sword_message("✦ %s  •  [G] enchant zombies" % get_enchantment_name())

func get_enchantment_name() -> String:
	return ENCHANT_NAMES.get(enchantment, "None")


func _update_blade_color() -> void:
	var col : Color = ENCHANT_COLORS.get(enchantment, swing_color) as Color
	# REAL BUG FIX: this used to create a brand-new infinite-looping tween
	# PER MESH, EVERY call, with no reference kept and nothing ever killed --
	# and _do_swing_vfx() calls this again after every single swing while
	# enchanted, so every swing piled another full set of infinite tweens
	# onto the same properties, fighting each other and leaking forever for
	# as long as combat continued. Kill every previous glow tween up front
	# (one per mesh child, since the loop below creates one per mesh too).
	for old_tw in _blade_glow_tweens:
		if is_instance_valid(old_tw):
			old_tw.kill()
	_blade_glow_tweens.clear()
	for mesh in find_children("*", "MeshInstance3D", true, false):
		var mi  := mesh as MeshInstance3D
		var src : Material = mi.material_override
		if not is_instance_valid(src) and mi.get_surface_override_material_count() > 0:
			src = mi.get_surface_override_material(0)
		if not is_instance_valid(src) and is_instance_valid(mi.mesh):
			src = mi.mesh.surface_get_material(0)
		var mat : StandardMaterial3D
		if src is StandardMaterial3D:
			mat = (src as StandardMaterial3D).duplicate() as StandardMaterial3D
		else:
			mat = StandardMaterial3D.new()
			mat.albedo_color = col
		mat.emission_enabled             = true
		mat.emission                     = col
		mat.emission_energy_multiplier   = 3.0
		mi.material_override = mat
		var tw := create_tween().set_loops()
		tw.tween_property(mi, "material_override:emission_energy_multiplier", 6.0, 0.6)
		tw.tween_property(mi, "material_override:emission_energy_multiplier", 2.5, 0.6)
		_blade_glow_tweens.append(tw)


# ============================================================
# VFX
# ============================================================
func _do_swing_vfx() -> void:
	var col    : Color = ENCHANT_COLORS.get(enchantment, Color.WHITE) as Color
	var meshes : Array = find_children("*", "MeshInstance3D", true, false)

	for mesh in meshes:
		var mi  := mesh as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.shading_mode             = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color             = Color.WHITE
		mat.emission_enabled         = true
		mat.emission                 = col
		mat.emission_energy_multiplier = 14.0
		mi.material_override = mat

	# Swing arc
	rotation_degrees.z = -50.0
	var tw := create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)
	tw.tween_property(self, "rotation_degrees:z",  50.0, 0.18)
	tw.tween_property(self, "rotation_degrees:z",   0.0, 0.10)

	# Tilt on z (weapon body)
	var tw2 := create_tween().set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	tw2.tween_property(self, "rotation_degrees:z", -55.0, 0.06)
	tw2.tween_property(self, "rotation_degrees:z",  55.0, 0.12)
	tw2.tween_property(self, "rotation_degrees:z",   0.0, 0.08)

	get_tree().create_timer(0.12).timeout.connect(func():
		if enchantment == Enchant.NONE:
			# Restore original material so texture shows again
			for m in find_children("*", "MeshInstance3D", true, false):
				(m as MeshInstance3D).material_override = null
		else:
			_update_blade_color()
	, CONNECT_ONE_SHOT)


# ============================================================
# HELPERS
# ============================================================
func _sword_message(text: String) -> void:
	if is_instance_valid(player) and player.has_method("_show_message"):
		player._show_message(text, Color(0.9, 0.75, 0.2))

func _play_sfx(sounds: Array[AudioStream]) -> void:
	if sounds.is_empty() or not is_instance_valid(_sfx):
		return
	_sfx.stream      = sounds[randi() % sounds.size()]
	_sfx.pitch_scale = randf_range(0.9, 1.1)
	_sfx.play()
