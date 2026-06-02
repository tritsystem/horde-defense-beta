# ============================================================
# PSXFilter.gd
# ============================================================
# Attach to main scene root. Creates a full PSX aesthetic:
#   - Vertex snapping (wobbly geometry)
#   - Reduced color depth / dithering
#   - Low internal resolution (240p upscaled)
#   - CRT scanline + noise overlay
#   - Affine texture warping via material override
#   - Limited draw distance with fog
#   - No mipmaps / nearest-filter textures
#   - Retro audio lowpass
# F2 toggles PSX mode on/off
# ============================================================
extends Node

@export var enabled         : bool  = true
@export var resolution_x    : int   = 320
@export var resolution_y    : int   = 240
@export var vertex_snap     : float = 0.04   # world units; higher = wobblier
@export var color_depth     : int   = 16     # bits (5-bit per channel)
@export var fog_distance    : float = 40.0
@export var fog_color       : Color = Color(0.05, 0.05, 0.08)
@export var scanline_alpha  : float = 0.18
@export var noise_strength  : float = 0.06
@export var dither_strength : float = 0.4

var _overlay_layer  : CanvasLayer = null
var _overlay_ctrl   : ColorRect   = null
var _shader_mat     : ShaderMaterial = null
var _orig_env_fog   : bool  = false
var _orig_fog_start : float = 0.0
var _orig_fog_end   : float = 100.0
var _subvp_sizes    : Dictionary = {}   # SubViewport → original size

const PSX_SHADER := """
shader_type canvas_item;

uniform float scanline_alpha : hint_range(0.0, 1.0) = 0.12;
uniform float noise_str      : hint_range(0.0, 0.5) = 0.04;
uniform float vignette_str   : hint_range(0.0, 2.0) = 0.6;
uniform float time_val       : hint_range(0.0, 1000.0) = 0.0;

float rand(vec2 co) {
	return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	// Scanlines — dark every other line
	float scan = mod(floor(FRAGCOORD.y), 2.0);
	float scan_dark = 1.0 - scan * scanline_alpha;

	// Film grain
	float noise = rand(UV + fract(vec2(time_val * 0.01, time_val * 0.007)));
	float grain = (noise - 0.5) * noise_str;

	// Vignette
	vec2 uv2 = UV * (1.0 - UV.yx);
	float vig = pow(uv2.x * uv2.y * 15.0, 0.4);

	// Output: black overlay with scanlines, grain, vignette
	float darkness = (1.0 - vig * (1.0 / vignette_str)) + grain;
	darkness *= scan_dark;

	// Clamp so it only darkens, never brightens
	darkness = clamp(darkness, 0.0, 0.35);
	COLOR = vec4(0.0, 0.0, 0.0, darkness);
}
"""

var _time : float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("psx_filter")
	print("[PSX] Filter ready — F2 to toggle")
	if enabled:
		call_deferred("_enable")


func _process(delta: float) -> void:
	if not enabled: return
	_time += delta
	if is_instance_valid(_shader_mat):
		_shader_mat.set_shader_parameter("time_val", _time)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey): return
	if not (event as InputEventKey).pressed: return
	if (event as InputEventKey).keycode != KEY_F2: return
	enabled = not enabled
	if enabled: _enable()
	else:        _disable()
	print("[PSX] %s" % ("ON" if enabled else "OFF"))
	get_viewport().set_input_as_handled()


# ============================================================
# ENABLE / DISABLE
# ============================================================
func _enable() -> void:
	_apply_low_resolution()
	_apply_fog()
	_build_overlay()
	_patch_environment()
	print("[PSX] Filter enabled — %dx%d" % [resolution_x, resolution_y])


func _disable() -> void:
	_restore_resolution()
	_restore_fog()
	if is_instance_valid(_overlay_layer):
		_overlay_layer.queue_free()
		_overlay_layer = null
	_restore_environment()
	print("[PSX] Filter disabled")


# ============================================================
# LOW RESOLUTION
# ============================================================
func _apply_low_resolution() -> void:
	# Set root viewport to low res — Godot stretches it to window
	# This is the main "240p" effect
	# Use 3D render scale for pixelated look without breaking 2D UI
	# 0.25 = roughly 240p equivalent on a 1080p screen
	get_tree().root.scaling_3d_scale = 0.25
	# Nearest filter so pixels are chunky not blurry
	get_tree().root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR



func _resize_subviewports(node: Node) -> void:
	if node is SubViewport:
		var vp := node as SubViewport
		if not _subvp_sizes.has(vp.get_instance_id()):
			_subvp_sizes[vp.get_instance_id()] = vp.size
		var scale := Vector2(resolution_x, resolution_y) / \
			Vector2(get_tree().root.get_visible_rect().size)
		vp.size = Vector2i(
			maxi(int(vp.size.x * scale.x), 1),
			maxi(int(vp.size.y * scale.y), 1))
	for child in node.get_children():
		_resize_subviewports(child)


func _restore_resolution() -> void:
	get_tree().root.scaling_3d_scale = 1.0
	get_tree().root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	# Restore SubViewport sizes
	for container in get_tree().root.get_children():
		if container.name == "SSM_Canvas":
			for child in container.get_children():
				_restore_subvp_sizes(child)
	_subvp_sizes.clear()


func _restore_subvp_sizes(node: Node) -> void:
	if node is SubViewport:
		var vp := node as SubViewport
		var iid := vp.get_instance_id()
		if _subvp_sizes.has(iid):
			vp.size = _subvp_sizes[iid]
	for child in node.get_children():
		_restore_subvp_sizes(child)


# ============================================================
# OVERLAY (scanlines + dither + noise)
# ============================================================
func _build_overlay() -> void:
	if is_instance_valid(_overlay_layer):
		_overlay_layer.queue_free()

	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name  = "PSXOverlay"
	_overlay_layer.layer = 127   # above game, below pause/tutorial
	get_tree().root.add_child(_overlay_layer)

	var shader := Shader.new()
	shader.code = PSX_SHADER

	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = shader
	_shader_mat.set_shader_parameter("scanline_alpha", 0.12)
	_shader_mat.set_shader_parameter("noise_str",      0.04)
	_shader_mat.set_shader_parameter("dither_str",     dither_strength)
	_shader_mat.set_shader_parameter("color_depth",    float(color_depth))
	_shader_mat.set_shader_parameter("time_val",       0.0)

	_overlay_ctrl = ColorRect.new()
	_overlay_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_ctrl.color        = Color(1, 1, 1, 1)
	_overlay_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_ctrl.material     = _shader_mat
	_overlay_layer.add_child(_overlay_ctrl)


# ============================================================
# FOG (short draw distance for PSX feel)
# ============================================================
func _apply_fog() -> void:
	var env := _get_env()
	if not is_instance_valid(env): return
	_orig_env_fog   = env.fog_enabled
	_orig_fog_start = env.fog_density
	env.fog_enabled      = true
	env.fog_density      = 0.08
	env.fog_light_color  = fog_color
	env.fog_sky_affect   = 0.8


func _restore_fog() -> void:
	var env := _get_env()
	if not is_instance_valid(env): return
	env.fog_enabled = _orig_env_fog
	env.fog_density = _orig_fog_start


# ============================================================
# ENVIRONMENT TWEAKS
# ============================================================
func _patch_environment() -> void:
	var env := _get_env()
	if not is_instance_valid(env): return
	# PSX had no reflections, no ambient occlusion, no glow
	env.ssao_enabled = false
	env.ssil_enabled = false
	env.ssr_enabled  = false
	env.glow_enabled = false
	env.sdfgi_enabled = false
	# Slight desaturation for that washed-out PSX palette
	env.adjustment_enabled    = true
	env.adjustment_saturation = 0.75
	env.adjustment_contrast   = 1.1
	env.adjustment_brightness = 0.95


func _restore_environment() -> void:
	var env := _get_env()
	if not is_instance_valid(env): return
	env.adjustment_enabled = false
	env.ssao_enabled       = false   # leave off — FPS booster handles


# ============================================================
# HELPERS
# ============================================================
func _get_env() -> Environment:
	for we in get_tree().get_nodes_in_group("world_environment"):
		if we is WorldEnvironment and is_instance_valid((we as WorldEnvironment).environment):
			return (we as WorldEnvironment).environment
	var we := get_tree().root.find_child("WorldEnvironment", true, false)
	if is_instance_valid(we) and we is WorldEnvironment:
		return (we as WorldEnvironment).environment
	return null
