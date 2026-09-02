# ============================================================
# PlayerSkins.gd  —  per-class body recolour for the player rig
# ============================================================
# The player/ally rigs are one shared Mixamo body mesh (Ch15 / Ch35 under
# Skeleton3D) with the imported Mixamo texture baked into the mesh
# surfaces. Every one of the 15 classes looked identical. This keeps the
# real texture (albedo + normal) and lays a per-class tint + emission +
# rim over it via a surface override material, so a Necromancer reads
# green-sick, a Berserker blood-red, a Paladin gold, etc.
#
# Pure code, no new assets. Body is only visible in third person / to
# team-mates / on the ally puppet -- the first-person local view hides it.
#
# Usage:  const PlayerSkins := preload("res://scripts/PlayerSkins.gd")
#         PlayerSkins.apply(self, int(player_class))          # recolour
#         PlayerSkins.set_body_variant(self, 1)               # Ch35 vs Ch15
# ============================================================
extends RefCounted

# class enum int (player.gd PlayerClass) -> look
#   tint     : multiplies the Mixamo albedo texture
#   emit     : emission colour (0 energy = off)
#   energy   : emission strength
#   metallic : 0..1 sheen (tanks/knights)
#   rim      : rim-light colour (assassins/casters pop against dark)
const LOOK : Dictionary = {
	0:  {"tint": Color(1.00, 1.00, 1.00), "emit": Color.BLACK,             "energy": 0.0, "metallic": 0.0, "rim": Color(0,0,0,0)},  # NONE
	1:  {"tint": Color(0.55, 0.85, 0.55), "emit": Color(0.20, 0.85, 0.30), "energy": 0.35, "metallic": 0.0, "rim": Color(0.4, 1.0, 0.5)},   # NECROMANCER
	2:  {"tint": Color(0.95, 0.42, 0.38), "emit": Color(0.80, 0.10, 0.05), "energy": 0.30, "metallic": 0.05, "rim": Color(1.0, 0.3, 0.2)},  # BERSERKER
	3:  {"tint": Color(1.00, 0.90, 0.55), "emit": Color(1.00, 0.82, 0.35), "energy": 0.25, "metallic": 0.55, "rim": Color(1.0, 0.95, 0.7)}, # PALADIN
	4:  {"tint": Color(0.55, 0.50, 0.70), "emit": Color(0.35, 0.10, 0.55), "energy": 0.30, "metallic": 0.10, "rim": Color(0.6, 0.3, 1.0)},  # SHADOWBLADE
	5:  {"tint": Color(0.60, 0.80, 1.00), "emit": Color(0.25, 0.55, 1.00), "energy": 0.50, "metallic": 0.15, "rim": Color(0.5, 0.8, 1.0)},  # STORMCALLER
	6:  {"tint": Color(0.85, 0.35, 0.45), "emit": Color(0.70, 0.05, 0.20), "energy": 0.40, "metallic": 0.05, "rim": Color(1.0, 0.2, 0.35)}, # BLOODMAGE
	7:  {"tint": Color(0.70, 0.85, 0.90), "emit": Color(0.45, 0.80, 0.85), "energy": 0.35, "metallic": 0.20, "rim": Color(0.7, 0.95, 1.0)}, # TIMEWEAVER
	8:  {"tint": Color(0.45, 0.40, 0.55), "emit": Color(0.30, 0.10, 0.45), "energy": 0.45, "metallic": 0.10, "rim": Color(0.5, 0.2, 0.8)},  # VOIDWALKER
	9:  {"tint": Color(0.72, 0.75, 0.80), "emit": Color.BLACK,             "energy": 0.0, "metallic": 0.85, "rim": Color(0.8, 0.85, 0.95)}, # IRONCLAD
	10: {"tint": Color(0.70, 0.80, 0.45), "emit": Color(0.45, 0.70, 0.15), "energy": 0.40, "metallic": 0.0, "rim": Color(0.6, 0.9, 0.3)},   # PLAGUEMASTER
	11: {"tint": Color(0.55, 0.65, 0.70), "emit": Color(0.30, 0.65, 0.70), "energy": 0.45, "metallic": 0.10, "rim": Color(0.4, 0.85, 0.9)}, # SOULREAPER
	12: {"tint": Color(0.60, 0.45, 0.75), "emit": Color(0.45, 0.20, 0.75), "energy": 0.40, "metallic": 0.05, "rim": Color(0.7, 0.4, 1.0)},  # WARLOCK
	13: {"tint": Color(1.00, 0.65, 0.35), "emit": Color(1.00, 0.45, 0.10), "energy": 0.70, "metallic": 0.0, "rim": Color(1.0, 0.6, 0.2)},   # PHOENIX
	14: {"tint": Color(0.55, 0.70, 0.60), "emit": Color(0.25, 0.60, 0.40), "energy": 0.35, "metallic": 0.05, "rim": Color(0.4, 0.9, 0.6)},  # GRAVEMIND
	15: {"tint": Color(0.80, 0.45, 0.35), "emit": Color(0.85, 0.25, 0.10), "energy": 0.35, "metallic": 0.30, "rim": Color(1.0, 0.4, 0.2)},  # DOOMSLAYER
}


static func _body_meshes(player_root: Node) -> Array:
	var out : Array = []
	var skel := player_root.get_node_or_null("Skeleton3D")
	if skel == null:
		return out
	for c in skel.get_children():
		if c is MeshInstance3D:
			out.append(c)
	return out


## Recolour the player's body to its class. Safe to call repeatedly.
static func apply(player_root: Node, class_int: int) -> void:
	if player_root == null:
		return
	var look : Dictionary = LOOK.get(class_int, LOOK[0])
	for mi in _body_meshes(player_root):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		for si in range(m.mesh.get_surface_count()):
			var base : Material = m.get_active_material(si)
			if not (base is BaseMaterial3D):
				base = m.mesh.surface_get_material(si)
			var mat := StandardMaterial3D.new()
			if base is BaseMaterial3D:
				var b := base as BaseMaterial3D
				mat.albedo_texture  = b.albedo_texture
				mat.normal_texture  = b.normal_texture
				mat.normal_enabled  = b.normal_texture != null
				mat.roughness       = b.roughness
			mat.albedo_color = look["tint"]
			if float(look["energy"]) > 0.0:
				mat.emission_enabled = true
				mat.emission = look["emit"]
				mat.emission_energy_multiplier = float(look["energy"])
			mat.metallic = float(look["metallic"])
			var rim : Color = look["rim"]
			if rim.a > 0.0:
				mat.rim_enabled = true
				mat.rim = 0.6
				mat.rim_tint = 0.5
			m.set_surface_override_material(si, mat)


## Body-shape variant: 0 = Ch15 (default), 1 = Ch35. Returns the chosen index.
static func set_body_variant(player_root: Node, variant: int) -> int:
	var meshes := _body_meshes(player_root)
	if meshes.size() < 2:
		return 0
	var ch15 : MeshInstance3D = null
	var ch35 : MeshInstance3D = null
	for mi in meshes:
		if String(mi.name).to_lower().contains("ch35"): ch35 = mi
		elif String(mi.name).to_lower().contains("ch15"): ch15 = mi
	if ch15 == null or ch35 == null:
		return 0
	var use35 := (variant % 2) == 1
	ch35.visible = use35
	ch15.visible = not use35
	return 1 if use35 else 0
