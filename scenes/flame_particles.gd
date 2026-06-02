# ============================================================
# FlameParticles.gd — Attach to a GPUParticles3D node
# Configure in Inspector or call setup() from code
# Creates realistic layered flame effect
# ============================================================
extends GPUParticles3D

@export var flame_color      : Color = Color(1.0, 0.45, 0.06)
@export var flame_height     : float = 2.0    # how tall the flame rises
@export var flame_width      : float = 0.6    # spread radius
@export var flame_intensity  : float = 1.0    # overall brightness/density
@export var flicker_speed    : float = 8.0    # flicker rate
@export_enum("Small:0", "Medium:1", "Large:2", "Inferno:3") var flame_size : int = 1

var _light : OmniLight3D = null
var _t     : float       = 0.0


func _ready() -> void:
	_build()
	_build_light()


func _process(delta: float) -> void:
	_t += delta
	# Flicker the light
	if is_instance_valid(_light):
		_light.light_energy = (1.5 + sin(_t * flicker_speed) * 0.5 +
			sin(_t * flicker_speed * 1.7) * 0.3) * flame_intensity


func setup(color: Color, height: float, width: float, intensity: float = 1.0) -> void:
	flame_color     = color
	flame_height    = height
	flame_width     = width
	flame_intensity = intensity
	_build()
	if is_instance_valid(_light): _build_light()


func _build() -> void:
	# Counts per flame size
	var counts := [12, 28, 55, 120]
	var lifetimes := [0.8, 1.2, 1.6, 2.2]
	amount          = counts[clampi(flame_size, 0, 3)]
	lifetime        = lifetimes[clampi(flame_size, 0, 3)]
	randomness      = 0.6
	local_coords    = true
	fixed_fps       = 0
	emitting        = true

	var pm := ParticleProcessMaterial.new()

	# Emission shape — disc at base
	pm.emission_shape        = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = minf(flame_width * 0.3, 0.25)

	# Motion — rise up with turbulence
	pm.direction              = Vector3(0.0, 1.0, 0.0)
	pm.spread                 = 18.0
	pm.initial_velocity_min   = flame_height * 1.2
	pm.initial_velocity_max   = flame_height * 2.0
	pm.gravity                = Vector3(0.0, 0.2, 0.0)  # slight upward assist

	# Turbulence for flicker
	pm.turbulence_enabled         = true
	pm.turbulence_noise_strength  = 1.2
	pm.turbulence_noise_speed     = Vector3(0.4, 0.8, 0.4) * flicker_speed * 0.1
	pm.turbulence_noise_scale     = 0.8
	pm.turbulence_influence_min   = 0.15
	pm.turbulence_influence_max   = 0.45

	# Size — grows then shrinks
	pm.scale_min = 0.08
	pm.scale_max = 0.18
	var size_curve := Curve.new()
	size_curve.add_point(Vector2(0.0, 0.3))
	size_curve.add_point(Vector2(0.2, 1.0))
	size_curve.add_point(Vector2(0.6, 0.7))
	size_curve.add_point(Vector2(1.0, 0.0))
	var size_tex := CurveTexture.new(); size_tex.curve = size_curve
	pm.scale_curve = size_tex

	# Color gradient — white core → orange → red → smoke
	var grad := Gradient.new()
	grad.add_point(0.0,  Color(1.0,  0.98, 0.85, 0.0))
	grad.add_point(0.05, Color(1.0,  0.95, 0.7,  0.95))
	grad.add_point(0.2,  Color(flame_color.r, flame_color.g, flame_color.b * 0.5, 0.9))
	grad.add_point(0.5,  Color(flame_color.r * 0.9, flame_color.g * 0.35, 0.04, 0.65))
	grad.add_point(0.75, Color(0.25, 0.14, 0.10, 0.35))
	grad.add_point(1.0,  Color(0.10, 0.08, 0.08, 0.0))
	var grad_tex := GradientTexture1D.new(); grad_tex.gradient = grad
	pm.color_ramp = grad_tex

	# Damping — slows as it rises
	pm.damping_min = 1.0
	pm.damping_max = 3.5

	process_material = pm

	# Draw mesh — stretched quad billboard
	var quad := QuadMesh.new()
	quad.size = Vector2(0.25, 0.35)
	var qmat := StandardMaterial3D.new()
	qmat.transparency         = BaseMaterial3D.TRANSPARENCY_ALPHA
	qmat.shading_mode         = BaseMaterial3D.SHADING_MODE_UNSHADED
	qmat.billboard_mode       = BaseMaterial3D.BILLBOARD_ENABLED
	qmat.emission_enabled     = true
	qmat.emission             = flame_color
	qmat.emission_energy_multiplier = 3.5 * flame_intensity
	qmat.albedo_color         = Color(1.0, 0.7, 0.3, 0.85)
	qmat.vertex_color_use_as_albedo = true
	quad.material = qmat
	draw_pass_1   = quad


func _build_light() -> void:
	if is_instance_valid(_light): _light.queue_free()
	_light = OmniLight3D.new()
	_light.light_color         = flame_color
	_light.light_energy        = 2.0 * flame_intensity
	_light.omni_range          = flame_height * 2.5
	_light.shadow_enabled      = false
	_light.light_volumetric_fog_energy = 0.3
	add_child(_light)


func set_flame_active(on: bool) -> void:
	emitting = on
	if is_instance_valid(_light): _light.visible = on
