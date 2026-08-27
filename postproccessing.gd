# ============================================================
# PostProcessing.gd — MAX PERFORMANCE build
# Attach to WorldEnvironment node.
#
# COST RANKING (worst → best for framerate):
#   SDFGI > SSR > SSIL > SSAO > Bloom (5 levels) > DoF > Fog > ColorAdj
#
# This profile kills the expensive passes entirely, keeps only
# the near-free ones, and exposes a quality_tier export so you
# can scale up on beefy machines at runtime.
# ============================================================
extends WorldEnvironment

## 0 = Potato  1 = Low  2 = Medium  3 = High (original FPS profile)
# DARK-HORROR RESKIN (2026-08-24): bumped default Low(1) -> Medium(2).
# Tier 2 is still nowhere near the SDFGI+SSIL+volumetric-fog combo that
# caused this project's documented 200-zombie/~6FPS collapse (see
# theme_horror/HorrorTheme.gd) -- sdfgi/ssr stay unconditionally false
# below regardless of tier, and ssil only turns on at tier>=3, which this
# default does not reach. The only thing tier 2 actually adds over tier 1
# is real SSAO (already-tuned numbers a few lines down, untouched by this
# pass) -- a screen-space pass whose cost scales with resolution, not with
# zombie/scene complexity, and is explicitly called out as a safe/cheap
# win in this project's own graphics-performance lesson. Not verified
# against a live 200-zombie framerate (no way to run/play the game from
# this session) -- flagged in the session's report; revert to 1 here if a
# real playtest shows a regression.
@export_range(0, 3) var quality_tier : int = 2 :
	set(v): quality_tier = v; if is_node_ready(): _apply()

@export_group("Tone Mapping")
@export var tone_map_mode : int   = Environment.TONE_MAPPER_LINEAR  # FILMIC costs ~0.3ms; LINEAR is free
@export var exposure      : float = 0.82   # was 1.0 -- darker exposure, harsher shadow read
@export var white         : float = 1.0

@export_group("Color Correction")
## Adjustment pass is a single fullscreen blit — essentially free. Keep it.
# DARK-HORROR RESKIN: was a fairly vibrant/bright grade (sat 1.25, low
# contrast, near-full brightness). Retinted toward a sickly, desaturated,
# high-contrast Wolfenstein-style grade.
@export var saturation    : float = 0.55   # was 1.25
@export var contrast      : float = 1.32   # was 1.10
@export var brightness    : float = 0.85   # was 0.95

@export_group("Fog")
@export var fog_enabled       : bool  = true
@export var fog_density       : float = 0.0035   # was 0.002 -- slightly more atmosphere, still a flat/height fog, not volumetric
@export var fog_color         : Color = Color(0.17, 0.19, 0.10)   # was a cool blue-grey (0.10,0.12,0.18) -- now sickly olive-green
@export var fog_height        : float = -4.0
@export var fog_height_density: float = 0.06

@export_group("Sky")
# DARK-HORROR RESKIN: was a blue-purple night palette. Retinted to a
# desaturated near-black sky with a grimy amber-olive horizon glow.
@export var sky_color_top     : Color = Color(0.045, 0.05, 0.04)
@export var sky_color_horizon : Color = Color(0.24, 0.19, 0.10)
@export var sky_color_bottom  : Color = Color(0.03, 0.03, 0.025)

# ── Per-tier settings ─────────────────────────────────────────
# Bloom, SSAO, SSIL are not exported individually —
# they're driven entirely by quality_tier to avoid foot-guns.

# ── Runtime state ─────────────────────────────────────────────
var _scope_attr  : CameraAttributesPractical = null
var _active_tween: Tween = null


func _ready() -> void:
	_apply()


func _apply() -> void:
	var env := Environment.new()

	# ── Sky (ProceduralSky — GPU cost is negligible vs ReflectionProbe) ──
	var sky  := Sky.new()
	var proc := ProceduralSkyMaterial.new()
	proc.sky_top_color        = sky_color_top
	proc.sky_horizon_color    = sky_color_horizon
	proc.ground_bottom_color  = sky_color_bottom
	proc.ground_horizon_color = sky_color_horizon.darkened(0.3)
	proc.sun_angle_max        = 30.0
	sky.sky_material          = proc
	env.sky                   = sky
	env.background_mode       = Environment.BG_SKY

	# Flat color ambient is cheaper than sky-sampled ambient.
	# Bake lighting where possible and set this to AMBIENT_SOURCE_COLOR.
	# DARK-HORROR RESKIN: was a cool blue-grey ambient (0.10,0.11,0.14) at
	# 0.30 energy -- retinted to a dim, desaturated sickly olive-green and
	# darkened slightly for deeper shadow contrast against the harsher key
	# light (see game_phase_script.gd's NIGHT_SUN_ENERGY/NIGHT_SUN_COLOR).
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color  = Color(0.13, 0.15, 0.09)
	env.ambient_light_energy = 0.24

	# ── Tone mapping ──────────────────────────────────────────
	# LINEAR = no extra pass. Switch to FILMIC on tier 3 only.
	env.tonemap_mode     = Environment.TONE_MAPPER_FILMIC if quality_tier >= 3 else Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = exposure
	env.tonemap_white    = white

	# ── Bloom ─────────────────────────────────────────────────
	# Each active glow level = one downsample + upsample pass.
	# Tier 0: OFF entirely.  Tier 1: 2 levels.  Tier 2: 3 levels.  Tier 3: 5 levels.
	match quality_tier:
		0:
			env.glow_enabled = false
		1:
			env.glow_enabled       = true
			env.glow_intensity     = 0.12
			env.glow_bloom         = 0.08
			env.glow_blend_mode    = Environment.GLOW_BLEND_MODE_ADDITIVE  # cheaper than SOFTLIGHT
			env.glow_hdr_threshold = 1.4
			env.set_glow_level(0, 1.0)
			env.set_glow_level(1, 0.6)
			# Levels 2-6 stay at default 0
		2:
			env.glow_enabled       = true
			env.glow_intensity     = 0.13
			env.glow_bloom         = 0.09
			env.glow_blend_mode    = Environment.GLOW_BLEND_MODE_SOFTLIGHT
			env.glow_hdr_threshold = 1.3
			env.set_glow_level(0, 1.0)
			env.set_glow_level(1, 0.8)
			env.set_glow_level(2, 0.4)
		3:
			env.glow_enabled       = true
			env.glow_intensity     = 0.15
			env.glow_bloom         = 0.10
			env.glow_blend_mode    = Environment.GLOW_BLEND_MODE_SOFTLIGHT
			env.glow_hdr_threshold = 1.2
			env.set_glow_level(0, 1.0)
			env.set_glow_level(1, 0.8)
			env.set_glow_level(2, 0.5)
			env.set_glow_level(3, 0.3)
			env.set_glow_level(4, 0.1)

	# ── SSAO ──────────────────────────────────────────────────
	# SSAO is expensive (~1–3ms on mid GPUs). Off below tier 2.
	# ssao_detail = 0 halves sample count at small quality loss.
	match quality_tier:
		0, 1:
			env.ssao_enabled = false
		2:
			env.ssao_enabled   = true
			env.ssao_radius    = 0.5
			env.ssao_intensity = 1.2
			env.ssao_power     = 1.0
			env.ssao_detail    = 0.0   # Half samples — biggest SSAO perf lever
		3:
			env.ssao_enabled   = true
			env.ssao_radius    = 0.6
			env.ssao_intensity = 1.6
			env.ssao_power     = 1.2
			env.ssao_detail    = 0.5

	# ── SSIL ──────────────────────────────────────────────────
	# SSIL is more expensive than SSAO. Only on tier 3.
	env.ssil_enabled   = (quality_tier >= 3)
	env.ssil_radius    = 3.5
	env.ssil_intensity = 0.4

	# ── Fog ───────────────────────────────────────────────────
	# Volumetric fog is a separate pass — fog_volumetric_enabled left false.
	# Height fog is effectively free (resolved in the sky/background pass).
	env.fog_enabled            = fog_enabled
	env.fog_light_color        = fog_color
	env.fog_density            = fog_density
	env.fog_height             = fog_height
	env.fog_height_density     = fog_height_density
	env.fog_aerial_perspective = 0.0   # Zero = no extra blend; free

	# ── Color adjustment ──────────────────────────────────────
	env.adjustment_enabled    = true   # Single blit — always keep
	env.adjustment_saturation = saturation
	env.adjustment_contrast   = contrast
	env.adjustment_brightness = brightness

	# ── Kill all expensive reflections ────────────────────────
	env.ssr_enabled   = false   # SSR = very expensive, never in perf build
	env.sdfgi_enabled = false   # SDFGI = huge memory + GPU; bake GI instead

	environment = env
	print("[PostProcessing] Perf profile tier=%d applied" % quality_tier)


# ── Quality tier switching at runtime ────────────────────────
# Call from your settings menu. Rebuilds the Environment resource.
func set_quality(tier: int) -> void:
	quality_tier = clampi(tier, 0, 3)
	_apply()


# ── ADS / Scope DoF ──────────────────────────────────────────
# DoF only activates on scope raise — never runs during normal play.
# Re-uses a single CameraAttributesPractical instance to avoid allocs.
func set_scope_dof(enabled: bool) -> void:
	var cam := get_viewport().get_camera_3d() if get_viewport() else null
	if not is_instance_valid(cam): return
	if enabled:
		if _scope_attr == null:
			_scope_attr = CameraAttributesPractical.new()
			_scope_attr.dof_blur_near_enabled    = true
			_scope_attr.dof_blur_near_distance   = 4.0
			_scope_attr.dof_blur_near_transition = 2.0
			_scope_attr.dof_blur_amount          = 0.25
		cam.attributes = _scope_attr
	else:
		cam.attributes = null


# ── Bloom pulse (muzzle flash / hit confirm) ──────────────────
# Kills any in-flight tween first to prevent intensity drift on rapid fire.
func pulse_bloom(intensity: float = 1.2, duration: float = 0.12) -> void:
	if not is_instance_valid(environment) or not environment.glow_enabled: return
	if is_instance_valid(_active_tween): _active_tween.kill()
	var orig := environment.glow_intensity
	environment.glow_intensity = intensity
	_active_tween = create_tween()
	_active_tween.tween_property(environment, "glow_intensity", orig, duration)


# ── Flashbang whiteout ────────────────────────────────────────
func flash_white(peak_brightness: float = 4.0, recover_time: float = 1.8) -> void:
	if not is_instance_valid(environment): return
	var orig_b := environment.adjustment_brightness
	var orig_s := environment.adjustment_saturation
	environment.adjustment_brightness = peak_brightness
	environment.adjustment_saturation = 0.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(environment, "adjustment_brightness", orig_b, recover_time)
	tw.tween_property(environment, "adjustment_saturation", orig_s, recover_time * 0.6)


# ── Low-health damage state ───────────────────────────────────
# t = 0.0 (full health) → 1.0 (near death).
# Touches only the adjustment pass — zero GPU overhead.
func set_damage_state(t: float) -> void:
	if not is_instance_valid(environment): return
	environment.adjustment_saturation = lerp(saturation, 0.4, t)
	environment.adjustment_brightness = lerp(brightness, 0.75, t)
	environment.adjustment_contrast   = lerp(contrast,   1.25, t)
