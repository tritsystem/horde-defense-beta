# ============================================================
# PlayerEnergyAura.gd — Ghost spirit orbs around the player
# Auto-attached by player.gd _ready()
# ============================================================
extends Node

@export var aura_radius       : float = 36.0   # bigger field
@export var pulse_interval    : float = 0.25
@export var energize_duration : float = 1.5
@export var num_spirits       : int   = 9      # more wisps
@export var spirit_color      : Color = Color(0.35, 0.85, 1.0, 0.72)

var _player  : Node3D = null
var _timer   : float  = 0.0
var _spirits : Array  = []   # visible to SniperScope for hiding
var _time    : float  = 0.0


func _ready() -> void:
	if get_parent() is Node3D:
		_player = get_parent() as Node3D
	_build_spirits()


func _process(delta: float) -> void:
	_time  += delta
	_timer += delta
	_animate_spirits()
	if _timer >= pulse_interval:
		_timer = 0.0
		_pulse()


func _pulse() -> void:
	if not is_instance_valid(_player): return
	var origin  : Vector3 = _player.global_position
	var my_team : int     = int(_player.get("team_id") if "team_id" in _player else 1)
	var candidates : Array = []
	candidates.append_array(get_tree().get_nodes_in_group("minions"))
	candidates.append_array(get_tree().get_nodes_in_group("units"))
	for m in candidates:
		if not is_instance_valid(m) or not (m is Node3D): continue
		if not ("team_id" in m): continue
		if int(m.get("team_id")) != my_team: continue
		if m == _player: continue
		if origin.distance_to((m as Node3D).global_position) > aura_radius: continue
		if m.has_method("receive_energy"):
			m.receive_energy(energize_duration)
		elif "energized_timer" in m:
			m.set("energized_timer", maxf(float(m.get("energized_timer")), energize_duration))


func _build_spirits() -> void:
	for i in num_spirits:
		var spirit := MeshInstance3D.new()

		# Tiny particle sphere — much smaller than before
		var sm := SphereMesh.new()
		sm.radius = 0.045
		sm.height = 0.09
		sm.radial_segments = 6
		sm.rings = 3
		spirit.mesh = sm

		var mat := StandardMaterial3D.new()
		mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color               = Color(spirit_color.r, spirit_color.g, spirit_color.b, 0.18)
		mat.emission_enabled           = true
		mat.emission                   = spirit_color.lightened(0.2)
		mat.emission_energy_multiplier = 2.5
		mat.depth_draw_mode            = BaseMaterial3D.DEPTH_DRAW_DISABLED
		mat.billboard_mode             = BaseMaterial3D.BILLBOARD_ENABLED
		spirit.material_override       = mat
		spirit.cast_shadow             = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		# Very soft outer haze — extremely transparent
		var halo  := MeshInstance3D.new()
		var hm    := SphereMesh.new()
		hm.radius = 0.11; hm.height = 0.22; hm.radial_segments = 5; hm.rings = 2
		halo.mesh  = hm
		var hmat   := StandardMaterial3D.new()
		hmat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
		hmat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
		hmat.albedo_color               = Color(spirit_color.r, spirit_color.g, spirit_color.b, 0.055)
		hmat.emission_enabled           = true
		hmat.emission                   = spirit_color
		hmat.emission_energy_multiplier = 0.8
		hmat.depth_draw_mode            = BaseMaterial3D.DEPTH_DRAW_DISABLED
		hmat.billboard_mode             = BaseMaterial3D.BILLBOARD_ENABLED
		halo.material_override          = hmat
		halo.cast_shadow                = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		spirit.add_child(halo)

		# Very dim point light — just enough to see on nearby surfaces
		var light            := OmniLight3D.new()
		light.light_color     = spirit_color
		light.light_energy    = 0.25
		light.omni_range      = 1.5
		light.shadow_enabled  = false
		spirit.add_child(light)

		get_tree().current_scene.add_child(spirit)
		_spirits.append(spirit)


func _animate_spirits() -> void:
	if not is_instance_valid(_player): return
	var origin : Vector3 = _player.global_position + Vector3(0, 1.0, 0)

	for i in _spirits.size():
		var spirit := _spirits[i] as MeshInstance3D
		if not is_instance_valid(spirit): continue

		var phase  : float = float(i) / float(_spirits.size()) * TAU

		# Variable orbit radius — some hug the player, some drift further out
		var base_r : float = 0.7 + float(i % 3) * 0.35
		var r      : float = base_r + sin(_time * 0.6 + phase * 1.4) * 0.2

		# Different angular speeds so they never line up
		var speed  : float = 0.4 + float(i % 4) * 0.15
		var angle  : float = _time * speed + phase

		# Ghost vertical drift — slow, independent per spirit
		var y : float = sin(_time * 0.9 + phase * 2.1) * 0.5 \
					  + sin(_time * 0.35 + phase)        * 0.22

		spirit.global_position = origin + Vector3(cos(angle) * r, y, sin(angle) * r)

		# Pulse scale — very small variation for subtle shimmer
		spirit.scale = Vector3.ONE * (0.8 + sin(_time * 2.5 + phase) * 0.2)

		# Pulse alpha — stays very transparent, just flickers slightly
		if spirit.material_override is StandardMaterial3D:
			var mat := spirit.material_override as StandardMaterial3D
			var base_a : float = 0.12 + float(i % 3) * 0.05
			mat.albedo_color.a = clampf(base_a + sin(_time * 1.6 + phase * 1.8) * 0.08, 0.04, 0.28)
			# Slow hue drift between cyan and ghostly purple
			var hue : float = fmod(spirit_color.h + sin(_time * 0.25 + phase) * 0.1, 1.0)
			mat.emission = Color.from_hsv(hue, spirit_color.s * 0.85, spirit_color.v + 0.2)


func _exit_tree() -> void:
	for s in _spirits:
		if is_instance_valid(s): s.queue_free()
