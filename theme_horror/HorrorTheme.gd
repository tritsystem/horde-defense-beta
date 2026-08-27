# ============================================================
# HorrorTheme.gd
# ============================================================
# Reusable "Wolfenstein-style dark horror" material/lighting preset
# library for horde-beta-version-1.
#
# Built entirely from this project's own tools -- StandardMaterial3D
# tints, an Environment-flavored color palette, and a SpotLight3D
# prefab. NO external assets and NO id Software/Bethesda content of
# any kind are used or referenced. This is an ORIGINAL brutalist
# stone/metal + sickly desaturated green/amber/brown aesthetic, built
# to evoke that general mood, not to copy any specific game's art.
#
# WHERE THE REAL LIVE LIGHTING/GRADING ACTUALLY LIVES (read this before
# "fixing" main.tscn's saved Environment resource -- it will not do
# anything, and a past pass on this exact task almost wasted an edit
# there before tracing the real call chain):
#
#   main.tscn's WorldEnvironment node has its OWN saved Environment
#   sub-resource, but that resource is DISCARDED at runtime --
#   WorldEnvironment's own attached script (res://postproccessing.gd)
#   rebuilds `environment` completely from scratch in its _ready()/
#   _apply() (a fresh Environment.new(), not the saved one). Godot
#   calls child _ready() before parent _ready(), so this happens
#   BEFORE GamePhaseController's own script (scripts/game_phase_script.gd)
#   runs its _apply_night_lighting()/_setup_orange_sky(), which then
#   mutates fog/ambient/sky properties on THAT freshly-built object.
#
#   So the two real touchpoints for this game's actual mood are:
#     - postproccessing.gd's exported defaults (tone_map_mode, exposure,
#       white, saturation, contrast, brightness, fog_*, sky_color_*) plus
#       its hardcoded ambient_light_color/energy in _apply().
#     - game_phase_script.gd's NIGHT_SUN_ENERGY/NIGHT_SUN_COLOR/
#       NIGHT_AMBIENT_ENERGY/SKY_*_COLOR consts, and the fog_light_color/
#       ambient_light_color literals inside _apply_night_lighting().
#
#   Both were retinted toward this same sickly green/amber/brown palette
#   as part of this pass. The env_sickly_ambient.tres preset in this
#   folder is for any NEW scene that wants this look WITHOUT that
#   runtime machinery -- point a fresh WorldEnvironment's `environment`
#   at it directly.
#
# PERFORMANCE: nothing in this file enables SDFGI, SSIL, or volumetric
# fog -- this project has a documented incident where stacking those
# three simultaneously dropped a 200-zombie scene to ~6 FPS. Only cheap,
# resolution-scaled (not zombie-count-scaled) effects are used: SSAO,
# tonemap curve, glow, color adjustment, flat distance fog.
# ============================================================
class_name HorrorTheme
extends RefCounted

# ── Palette ───────────────────────────────────────────────────
const SICKLY_GREEN    : Color = Color(0.42, 0.50, 0.30, 1.0)
const RUST_AMBER       : Color = Color(0.55, 0.38, 0.16, 1.0)
const DEEP_BROWN        : Color = Color(0.20, 0.15, 0.10, 1.0)
const ASH_BLACK          : Color = Color(0.05, 0.05, 0.045, 1.0)
const SPOTLIGHT_AMBER  : Color = Color(0.95, 0.78, 0.42, 1.0)

# ── Reusable resources ───────────────────────────────────────
const MAT_GRIMY_STONE     : StandardMaterial3D = preload("res://theme_horror/mat_grimy_stone.tres")
const MAT_CORRODED_METAL  : StandardMaterial3D = preload("res://theme_horror/mat_corroded_metal.tres")
const ENV_SICKLY_AMBIENT  : Environment         = preload("res://theme_horror/env_sickly_ambient.tres")
const SPOTLIGHT_HARSH_SCENE : PackedScene       = preload("res://theme_horror/light_spotlight_harsh.tscn")


## Applies a sickly-tone tint to a mesh's EXISTING materials without
## discarding its albedo texture -- multiplies albedo_color on a
## per-instance DUPLICATE of each surface's currently active material
## (never mutates the shared imported resource, so this is safe to call
## independently on every instance of a mesh that's reused across many
## nodes, e.g. every zombie sharing one imported .glb material).
static func apply_sickly_tint(mesh_instances: Array, tint: Color = SICKLY_GREEN, strength: float = 1.0) -> void:
	for mi_any in mesh_instances:
		var mi := mi_any as MeshInstance3D
		if not is_instance_valid(mi) or mi.mesh == null:
			continue
		var surf_count : int = mi.mesh.get_surface_count()
		for s in range(surf_count):
			var src : Material = mi.get_active_material(s)
			if src is StandardMaterial3D:
				var m : StandardMaterial3D = (src as StandardMaterial3D).duplicate()
				var base_col : Color = m.albedo_color
				m.albedo_color = base_col.lerp(base_col * tint, clampf(strength, 0.0, 1.0))
				mi.set_surface_override_material(s, m)


## Recursively applies the corroded-metal preset as a material_override on
## every MeshInstance3D under `root`, skipping any subtree whose node name
## is in `exclude_names` (e.g. a turret's own health-bar quads, which need
## to keep their own functional red/green fill color, not a metal tint).
static func apply_grimy_metal_recursive(root: Node, exclude_names: Array = []) -> void:
	if not is_instance_valid(root):
		return
	if String(root.name) in exclude_names:
		return
	if root is MeshInstance3D:
		(root as MeshInstance3D).material_override = MAT_CORRODED_METAL
	for child in root.get_children():
		apply_grimy_metal_recursive(child, exclude_names)
