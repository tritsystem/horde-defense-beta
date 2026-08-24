# ============================================================
# base.gd — Base node script
# Attach to Base / Base2 nodes. Set team_id in Inspector.
# team_id=1 → player base, team_id=2 → enemy base.
# ============================================================
extends Node3D

# ── Inspector ─────────────────────────────────────────────────
@export var team_id    : int   = 1
@export var max_health : float = 1000.0

@export var castle_skin          : Texture2D = null
@export var castle_skin_uv_scale : float     = 4.0

# ── Runtime ───────────────────────────────────────────────────
var health       : float = 1000.0
var health_value : float = 1000.0

var _damage_zone         : Area3D         = null
var _grav_lift_positions : Array[Vector3] = []

const GRAV_LIFT_EXCLUSION_RADIUS : float = 3.5
const TERRAIN_COLLISION_MASK     : int   = 0b00000001

signal health_changed(current: float, maximum: float)
signal base_destroyed(team: int)


# ══════════════════════════════════════════════════════════════
# CASTLE DIMENSION CONSTANTS
# All measurements in metres. Keep these in one place so tweaks
# cascade automatically through geometry and nav logic.
# ══════════════════════════════════════════════════════════════

const _W    : float = 28.0   # total castle footprint (square)
const _WT   : float = 1.4    # curtain-wall thickness
const _WH   : float = 6.0    # curtain-wall height
const _TW   : float = 5.0    # corner-tower width
const _TH   : float = 12.0   # corner-tower height
const _GW   : float = 3.6    # gate opening width  ← must be > player capsule diameter
const _GH   : float = 4.0    # gate opening height ← must be > player capsule height
const _KW   : float = 10.0   # inner keep width
const _KH   : float = 3.0    # inner keep height

# Ramp: outside ground (y = 0) → courtyard slab top (y = _SLAB_H).
# Horizontal run chosen so the slope stays under ~5°.
const _SLAB_H    : float = 0.30   # courtyard slab top-face height
const _RAMP_LEN  : float = 5.0    # horizontal run of each ramp
const _RAMP_W    : float = 3.4    # ramp width (≤ _GW keeps it flush with gate)

# Convenience aliases — derived from constants above.
const _half : float = _W * 0.5
const _woff : float = _W * 0.5 - _TW * 0.5   # wall-centre offset from castle centre


# ══════════════════════════════════════════════════════════════
# LIFECYCLE
# ══════════════════════════════════════════════════════════════

func _ready() -> void:
	health       = max_health
	health_value = max_health
	add_to_group("bases")
	add_to_group("units")
	_snap_to_ground()
	print("[Base] '%s' ready | team=%d | HP=%d" % [name, team_id, int(health)])
	_build_health_display()
	_build_damage_zone()
	call_deferred("_notify_worldgen_exclusion")
	call_deferred("_spawn_castle")
	# REMOVED (2026-07-25): "get rid of auto spawning fire turrets at player
	# base that don't do anything" -- these 3 auto-placed starter turrets per
	# base sat outside the player's actual turret economy entirely (bought
	# and upgraded through shopui.gd/_place_turret() instead) -- not
	# purchased, not tracked by the shop's upgrade/repair flow, just
	# unmanaged clutter the player never chose to place. Turrets now only
	# come from the shop.
	# call_deferred("_spawn_starting_turrets")


# ══════════════════════════════════════════════════════════════
# GROUND SNAP
# ══════════════════════════════════════════════════════════════

func _snap_to_ground() -> void:
	var state := get_world_3d().direct_space_state
	if not is_instance_valid(state): return
	var hit := _raycast(state,
		global_position + Vector3(0, 100, 0),
		global_position + Vector3(0, -200, 0))
	if not hit.is_empty():
		global_position.y = float(hit.position.y)


# ══════════════════════════════════════════════════════════════
# MATERIAL HELPERS
# ══════════════════════════════════════════════════════════════

func _make_mat(col: Color) -> StandardMaterial3D:
	var m          := StandardMaterial3D.new()
	m.albedo_color  = col
	m.roughness     = 0.85
	m.metallic      = 0.02
	if is_instance_valid(castle_skin):
		m.albedo_texture = castle_skin
		m.uv1_scale      = Vector3(castle_skin_uv_scale, castle_skin_uv_scale, 1.0)
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		m.albedo_color   = col.lightened(0.15)
	return m


# ══════════════════════════════════════════════════════════════
# CASTLE — MAIN ENTRY POINT
# ══════════════════════════════════════════════════════════════

func _spawn_castle() -> void:
	var root      := Node3D.new()
	root.name      = "Castle"
	# REAL BUG FIX (2026-07-21): this root (and every wall/tower/rampart
	# StaticBody3D built under it) is parented to current_scene, NOT to this
	# Base node -- so it was never reachable via zombie.gd's "bases"-group
	# descendant scan, which only walks descendants of group-tagged nodes.
	# The castle's own real collision was invisible to that exclusion logic
	# entirely, regardless of how the scan itself worked -- confirmed live:
	# zombies teleporting onto castle rampart-walk tops via the ground-snap
	# raycast finding them as "ground". Tag it into the same "bases" group
	# so it's found the same way the Base node itself is.
	root.add_to_group("bases")
	get_tree().current_scene.add_child(root)

	# Snap castle root to terrain as well.
	var gp    := global_position
	var state := get_tree().root.get_world_3d().direct_space_state
	if is_instance_valid(state):
		var hit := _raycast(state,
			Vector3(gp.x, gp.y + 60, gp.z),
			Vector3(gp.x, gp.y - 30, gp.z))
		if not hit.is_empty():
			gp.y = float((hit.position as Vector3).y)
	root.global_position = gp

	# Palette
	var wall_col  : Color = Color(0.50, 0.58, 0.66) if team_id == 1 else Color(0.60, 0.38, 0.35)
	var stone_col : Color = Color(0.82, 0.77, 0.68)
	var wood_col  : Color = Color(0.32, 0.22, 0.14)

	var sm := _make_mat(wall_col)
	var tm := _make_mat(stone_col)
	var dm := _make_mat(wood_col)

	_build_courtyard_floor(root, tm)
	_build_corner_towers(root, sm, tm, dm)
	_build_curtain_walls(root, sm, tm)
	_build_rampart_walks(root, tm)
	_build_wall_merlons(root, sm)
	_build_keep(root, sm, tm, dm)
	_build_gate_ramps(root, tm)
	_mark_castle_gates(root)
	_build_grav_lifts(root, sm, tm)

	print("[Base] Castle built for team %d" % team_id)
	await get_tree().process_frame
	_clear_trees_inside_castle(root.global_position)


# ══════════════════════════════════════════════════════════════
# COURTYARD FLOOR
# Fill the entire interior with slab tiles so there are no gaps
# or ledges at ground level.  The top face sits at y = _SLAB_H.
# ══════════════════════════════════════════════════════════════

func _build_courtyard_floor(root: Node3D, tm: StandardMaterial3D) -> void:
	# Top face at y=0 (flush with terrain). Box centre buried by half thickness.
	var cy    : float = -_SLAB_H * 0.5
	var inner : float = _W - _WT * 2.0
	# Centre fill
	_cb(root, Vector3(0, cy, 0), Vector3(inner, _SLAB_H, inner), tm)
	# Full-width strips through wall band — gate thresholds have no gap.
	for side in [Vector3(0, 0, -_woff), Vector3(0, 0, _woff)]:
		_cb(root, side + Vector3(0, cy, 0), Vector3(_W, _SLAB_H, _WT), tm)
	for side in [Vector3(-_woff, 0, 0), Vector3(_woff, 0, 0)]:
		_cb(root, side + Vector3(0, cy, 0), Vector3(_WT, _SLAB_H, _W - _WT * 2.0), tm)


# ══════════════════════════════════════════════════════════════
# CORNER TOWERS
# ══════════════════════════════════════════════════════════════

func _build_corner_towers(root: Node3D,
		sm: StandardMaterial3D, tm: StandardMaterial3D,
		dm: StandardMaterial3D) -> void:
	for cx in [-1, 1]:
		for cz in [-1, 1]:
			var hw  : float  = _TW * 0.5
			var tp  : Vector3 = Vector3(float(cx) * (_half - hw), 0.0, float(cz) * (_half - hw))
			_build_tower(root, tp, sm, tm, dm)


func _build_tower(root: Node3D, pos: Vector3,
		sm: StandardMaterial3D, tm: StandardMaterial3D,
		dm: StandardMaterial3D) -> void:
	var hw   : float = _TW * 0.5
	var wt   : float = _WT
	var hole : float = 1.4

	# Four walls of the tower — each split into two panels either side of the
	# arrow-slit window so the window opening is real (non-colliding).
	for axis in [0, 2]:   # 0 = X walls, 2 = Z walls
		for side in [-1, 1]:
			var sign := float(side)
			var cp   : Vector3
			if axis == 2: cp = pos + Vector3(0, _TH * 0.5, sign * (hw - wt * 0.5))
			else:         cp = pos + Vector3(sign * (hw - wt * 0.5), _TH * 0.5, 0)

			var plen := (_TW - 0.5) * 0.5
			if axis == 2:
				_cb(root, cp + Vector3(-(plen * 0.5 + 0.13), 0, 0), Vector3(plen, _TH, wt), sm)
				_cb(root, cp + Vector3( (plen * 0.5 + 0.13), 0, 0), Vector3(plen, _TH, wt), sm)
				# Lintel + sill
				_cb(root, cp + Vector3(0,  _TH * 0.5 - 0.4, 0), Vector3(0.5, 0.8, wt + 0.05), sm)
				_cb(root, cp + Vector3(0, -_TH * 0.5 + 0.6, 0), Vector3(0.5, 1.2, wt + 0.05), sm)
			else:
				_cb(root, cp + Vector3(0, 0, -(plen * 0.5 + 0.13)), Vector3(wt, _TH, plen), sm)
				_cb(root, cp + Vector3(0, 0,  (plen * 0.5 + 0.13)), Vector3(wt, _TH, plen), sm)
				_cb(root, cp + Vector3(0,  _TH * 0.5 - 0.4, 0), Vector3(wt + 0.05, 0.8, 0.5), sm)
				_cb(root, cp + Vector3(0, -_TH * 0.5 + 0.6, 0), Vector3(wt + 0.05, 1.2, 0.5), sm)

	# Interior floor platforms at two heights
	for f in [1, 2]:
		var fy  : float = pos.y + f * 4.0
		var pl  : float = hw - hole
		for sx in [-1, 1]:
			for sz in [-1, 1]:
				_cb(root,
					Vector3(pos.x + float(sx) * (hole + pl * 0.5),
							fy + 0.1,
							pos.z + float(sz) * (hole + pl * 0.5)),
					Vector3(pl, 0.2, pl), tm)

	# Roof cap and battlements
	var top_y := pos.y + _TH
	_cb(root, Vector3(pos.x, top_y + 0.15, pos.z), Vector3(_TW, 0.3, _TW), tm)

	for d in [Vector3(0,0,-1), Vector3(0,0,1), Vector3(-1,0,0), Vector3(1,0,0)]:
		var is_z : bool    = d.z != 0.0
		var pp   : Vector3 = Vector3(pos.x, top_y + 1.0, pos.z) + d * (hw - wt * 0.5)
		var bs   : Vector3 = Vector3(_TW, 0.8, wt) if is_z else Vector3(wt, 0.8, _TW)
		_cb(root, pp, bs, sm)
		var cnt : int = int(_TW / 1.6)
		for m in cnt:
			var t  := (float(m) / float(maxi(cnt - 1, 1))) - 0.5
			var mp : Vector3
			var ms : Vector3
			if is_z:
				mp = pp + Vector3(t * (_TW - 0.9), 0.7, 0)
				ms = Vector3(0.9, 1.0, 0.85)
			else:
				mp = pp + Vector3(0, 0.7, t * (_TW - 0.9))
				ms = Vector3(0.85, 1.0, 0.9)
			_cb(root, mp, ms, sm)

	_build_ladder(root, pos, _TH, dm)


# ══════════════════════════════════════════════════════════════
# CURTAIN WALLS
#
# Each wall is composed of two horizontal segments (left wing and
# right wing) with an explicit gap of exactly _GW in the centre.
# Above the gap, an arch lintel closes the wall at height _GH so
# the opening is a proper archway.  No geometry ever occupies the
# _GW × _GH rectangular passage itself.
# ══════════════════════════════════════════════════════════════

func _build_curtain_walls(root: Node3D,
		sm: StandardMaterial3D, tm: StandardMaterial3D) -> void:
	# Four walls.  'rotated' = true means the wall runs along the Z axis.
	_curtain_wall(root, Vector3(0,      0, -_woff), false, sm, tm)  # north  (X-axis wall)
	_curtain_wall(root, Vector3(0,      0,  _woff), false, sm, tm)  # south
	_curtain_wall(root, Vector3(-_woff, 0,  0),     true,  sm, tm)  # west   (Z-axis wall)
	_curtain_wall(root, Vector3( _woff, 0,  0),     true,  sm, tm)  # east


func _curtain_wall(root: Node3D, centre: Vector3, rotated: bool,
		sm: StandardMaterial3D, tm: StandardMaterial3D) -> void:
	# Total span available between the two corner towers.
	var span  : float = _W - _TW * 2.0
	var wing  : float = (span - _GW) * 0.5   # length of each side wing
	var half_wing : float = wing * 0.5
	var half_gap  : float = _GW * 0.5

	# Helper to place a box either along X or Z depending on 'rotated'.
	var _wall_box := func(offset: Vector3, size_long: float, size_h: float) -> void:
		var sz  : Vector3
		var pos : Vector3
		if rotated:
			sz  = Vector3(_WT, size_h, size_long)
			pos = centre + Vector3(offset.z, offset.y, offset.x)
		else:
			sz  = Vector3(size_long, size_h, _WT)
			pos = centre + offset
		_cb(root, Vector3(pos.x, pos.y + size_h * 0.5, pos.z), sz, sm)

	# Left wing
	_wall_box.call(Vector3(-(half_gap + half_wing), 0, 0), wing, _WH)
	# Right wing
	_wall_box.call(Vector3(  half_gap + half_wing,  0, 0), wing, _WH)

	# Arch: above the gate opening, filling _GH → _WH.
	var arch_h   : float = _WH - _GH
	var arch_pos : Vector3
	if rotated:
		arch_pos = centre + Vector3(0, _GH + arch_h * 0.5, 0)
		_cb(root, arch_pos, Vector3(_WT, arch_h, _GW + 0.2), sm)
	else:
		arch_pos = centre + Vector3(0, _GH + arch_h * 0.5, 0)
		_cb(root, arch_pos, Vector3(_GW + 0.2, arch_h, _WT), sm)

	# Decorative lintel strip
	var lintel_pos : Vector3 = centre + Vector3(0, _GH + 0.12, 0)
	if rotated:
		_cb(root, lintel_pos, Vector3(_WT + 0.1, 0.24, _GW + 0.5), tm)
	else:
		_cb(root, lintel_pos, Vector3(_GW + 0.5, 0.24, _WT + 0.1), tm)


# ══════════════════════════════════════════════════════════════
# RAMPART WALKWAYS (top of curtain walls)
# ══════════════════════════════════════════════════════════════

func _build_rampart_walks(root: Node3D, tm: StandardMaterial3D) -> void:
	var span  : float = _W - _TW * 2.0
	var ry    : float = _WH + 0.15
	for z_sign in [-1, 1]:
		_cb(root, Vector3(0, ry, float(z_sign) * _woff),
			Vector3(span - 0.2, 0.3, _WT + 0.4), tm)
	for x_sign in [-1, 1]:
		_cb(root, Vector3(float(x_sign) * _woff, ry, 0),
			Vector3(_WT + 0.4, 0.3, span - 0.2), tm)


# ══════════════════════════════════════════════════════════════
# WALL MERLONS
# ══════════════════════════════════════════════════════════════

func _build_wall_merlons(root: Node3D, sm: StandardMaterial3D) -> void:
	var span : float = _W - _TW * 2.0
	var cnt  : int   = int(span / 1.8)
	for i in cnt:
		var t := (float(i) / float(maxi(cnt - 1, 1))) - 0.5
		for z_sign in [-1, 1]:
			_cb(root, Vector3(t * (span - 0.9), _WH + 0.9, float(z_sign) * _woff),
				Vector3(0.9, 1.0, 0.85), sm)
		for x_sign in [-1, 1]:
			_cb(root, Vector3(float(x_sign) * _woff, _WH + 0.9, t * (span - 0.9)),
				Vector3(0.85, 1.0, 0.9), sm)


# ══════════════════════════════════════════════════════════════
# INNER KEEP
# ══════════════════════════════════════════════════════════════

func _build_keep(root: Node3D,
		sm: StandardMaterial3D, tm: StandardMaterial3D,
		_dm: StandardMaterial3D) -> void:
	var kwt   : float = 1.2
	var kring : float = 1.5
	var kpl   : float = _KW * 0.5 - kring

	# Corner floor tiles
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			_cb(root,
				Vector3(float(sx) * (kring + kpl * 0.5), _KH + 0.15, float(sz) * (kring + kpl * 0.5)),
				Vector3(kpl, 0.3, kpl), tm)

	# Four keep walls (each split to leave a central entrance gap)
	for d in [Vector3(0,0,-1), Vector3(0,0,1), Vector3(-1,0,0), Vector3(1,0,0)]:
		var is_z  : bool    = d.z != 0.0
		var kp    : Vector3 = d * (_KW * 0.5 - kwt * 0.5)
		var plen  : float   = (_KW - 2.2) * 0.5
		for sg in [-1, 1]:
			var poff : Vector3
			if is_z: poff = Vector3(float(sg) * (plen * 0.5 + 1.1), 0, 0)
			else:    poff = Vector3(0, 0, float(sg) * (plen * 0.5 + 1.1))
			var psz : Vector3 = Vector3(plen, _KH * 0.7, kwt) if is_z else Vector3(kwt, _KH * 0.7, plen)
			_cb(root, Vector3(kp.x, _KH * 0.65, kp.z) + poff, psz, sm)
		var psz2 : Vector3 = Vector3(_KW, 0.7, kwt) if is_z else Vector3(kwt, 0.7, _KW)
		_cb(root, Vector3(kp.x, _KH + 0.6, kp.z), psz2, sm)


# ══════════════════════════════════════════════════════════════
# GATE RAMPS
#
# Each ramp is a tilted StaticBody3D whose:
#   • outer edge sits at y = 0  (outside ground level)
#   • inner edge sits at y = _SLAB_H  (courtyard slab top)
#
# The ramp width (_RAMP_W) is smaller than the gate opening (_GW)
# so it slides through without any geometry overlap with the walls.
#
# Orientation convention (canonical = south gate):
#   - Wall face is at local z = 0.
#   - Outside is in the -Z direction.
#   - Ramp slopes upward toward +Z (into the courtyard).
# Then we apply a Y rotation to orient all four gates.
# ══════════════════════════════════════════════════════════════

func _build_gate_ramps(root: Node3D, tm: StandardMaterial3D) -> void:
	# The courtyard floor top face is at y=0 (local).
	# Outside ground is also at y=0.  So the ramp is effectively flat —
	# it just needs to bridge the wall thickness gap so there is solid
	# collision under the player's feet as they walk through the gate.
	# We give it meaningful thickness (0.4 m) so it sits slightly proud
	# of the ground on both sides and is never floating.
	const RAMP_THICKNESS : float = 0.4

	var gates : Array[Dictionary] = [
		{"pos": Vector3(0,      0, -_woff), "rot": 180.0},  # north
		{"pos": Vector3(0,      0,  _woff), "rot":   0.0},  # south
		{"pos": Vector3(-_woff, 0,  0),     "rot":  90.0},  # west
		{"pos": Vector3( _woff, 0,  0),     "rot": 270.0},  # east
	]

	for g in gates:
		# Pivot sits at wall centre, Y-rotated so local +Z faces into courtyard.
		var pivot                := Node3D.new()
		pivot.name                = "GateRampPivot"
		pivot.position            = g["pos"]
		pivot.rotation_degrees.y  = float(g["rot"])
		root.add_child(pivot)

		# Flat bridge spanning wall thickness + ramp run on the outside.
		# Box top face at y=0, centre at y = -RAMP_THICKNESS*0.5.
		# Z span: from outside edge (-_WT*0.5 - _RAMP_LEN) to inside edge (+_WT*0.5).
		var total_z : float = _WT + _RAMP_LEN
		var body            := StaticBody3D.new()
		body.name            = "GateRamp"
		body.position        = Vector3(0.0,
									   -RAMP_THICKNESS * 0.5,
									   -(_RAMP_LEN * 0.5))   # centred outside the wall

		var mi  := MeshInstance3D.new()
		var bm  := BoxMesh.new()
		bm.size              = Vector3(_RAMP_W, RAMP_THICKNESS, total_z)
		mi.mesh              = bm
		mi.material_override = tm
		mi.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(mi)

		var col   := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = bm.size
		col.shape  = shape
		body.add_child(col)

		pivot.add_child(body)


# ══════════════════════════════════════════════════════════════
# GRAVITY LIFTS
# ══════════════════════════════════════════════════════════════

func _build_grav_lifts(root: Node3D,
		_sm: StandardMaterial3D, _tm: StandardMaterial3D) -> void:
	_grav_lift_positions.clear()
	var hw        : float = _TW * 0.5
	var lift_h    : float = _TH + 1.0

	for cx in [-1, 1]:
		for cz in [-1, 1]:
			var lp := Vector3(
				float(cx) * (_half - _TW * 1.6),
				0.0,
				float(cz) * (_half - _TW * 1.6))
			_build_grav_lift(root, lp, lift_h)
			_grav_lift_positions.append(lp)


func _build_grav_lift(root: Node3D, pos: Vector3, height: float) -> void:
	var team_col  : Color = Color(0.2,  0.6,  1.0)       if team_id == 1 else Color(1.0, 0.35, 0.2)
	var beam_tint : Color = Color(0.3,  0.7,  1.0, 0.18) if team_id == 1 else Color(1.0, 0.5,  0.2, 0.18)

	# Pad
	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color               = Color(0.12, 0.18, 0.28)
	pad_mat.emission_enabled           = true
	pad_mat.emission                   = team_col
	pad_mat.emission_energy_multiplier = 3.0
	pad_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED

	var pad  := MeshInstance3D.new()
	var padm := CylinderMesh.new()
	padm.top_radius      = 0.7
	padm.bottom_radius   = 0.85
	padm.height          = 0.18
	padm.radial_segments = 12
	pad.mesh              = padm
	pad.material_override = pad_mat
	pad.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pad.position          = pos + Vector3(0, 0.09, 0)
	root.add_child(pad)

	# Beam
	var beam_mat := StandardMaterial3D.new()
	beam_mat.albedo_color               = beam_tint
	beam_mat.emission_enabled           = true
	beam_mat.emission                   = team_col
	beam_mat.emission_energy_multiplier = 1.5
	beam_mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam_mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED

	var beam := MeshInstance3D.new()
	var bm   := CylinderMesh.new()
	bm.top_radius      = 0.28
	bm.bottom_radius   = 0.28
	bm.height          = height
	bm.radial_segments = 8
	beam.mesh              = bm
	beam.material_override = beam_mat
	beam.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.position          = pos + Vector3(0, height * 0.5, 0)
	root.add_child(beam)

	# Ring at top
	var ring := MeshInstance3D.new()
	var rm   := TorusMesh.new()
	rm.inner_radius  = 0.5
	rm.outer_radius  = 0.75
	rm.rings         = 6
	rm.ring_segments = 12
	ring.mesh              = rm
	ring.material_override = pad_mat
	ring.cast_shadow       = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position          = pos + Vector3(0, height, 0)
	root.add_child(ring)

	# Trigger area
	var area := Area3D.new()
	area.name            = "GravLift"
	area.collision_layer = 0
	area.collision_mask  = 0xFFFFFFFF
	area.monitoring      = true
	area.monitorable     = false
	area.add_to_group("grav_lift")

	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 1.1
	cyl.height = height
	col.shape  = cyl
	area.add_child(col)
	area.position = pos + Vector3(0, height * 0.5, 0)

	var lift_speed : float = 8.0
	var exit_y     : float = root.global_position.y + pos.y + height
	area.body_entered.connect(func(body: Node):
		if body.has_method("enter_grav_lift"): body.enter_grav_lift(exit_y, lift_speed))
	area.body_exited.connect(func(body: Node):
		if body.has_method("exit_grav_lift"):  body.exit_grav_lift())
	root.add_child(area)


# ══════════════════════════════════════════════════════════════
# LADDERS (inside corner towers)
# ══════════════════════════════════════════════════════════════

func _build_ladder(root: Node3D, tower_pos: Vector3, height: float,
		wm: StandardMaterial3D) -> void:
	var lx    : float = 1.4
	var lz    : float = -1.4
	var rails : float = height + 0.3
	var rungs : int   = int(height / 0.5)

	_cb(root, tower_pos + Vector3(lx, rails * 0.5, lz - 0.25), Vector3(0.08, rails, 0.08), wm)
	_cb(root, tower_pos + Vector3(lx, rails * 0.5, lz + 0.25), Vector3(0.08, rails, 0.08), wm)
	for r in rungs:
		_cb(root, tower_pos + Vector3(lx, 0.5 + r * 0.5, lz), Vector3(0.08, 0.06, 0.58), wm)

	var area := Area3D.new()
	area.name = "LadderZone"
	var col  := CollisionShape3D.new()
	var box  := BoxShape3D.new()
	box.size  = Vector3(0.65, height, 0.65)
	col.shape = box
	area.add_child(col)
	area.position = tower_pos + Vector3(lx - 0.35, height * 0.5, lz)

	var top_y : float = root.global_position.y + tower_pos.y + height
	area.body_entered.connect(func(body: Node3D):
		if body.has_method("enter_ladder"): body.enter_ladder(top_y))
	area.body_exited.connect(func(body: Node3D):
		if body.has_method("exit_ladder"):  body.exit_ladder())
	root.add_child(area)


# ══════════════════════════════════════════════════════════════
# GATE MARKERS (logic reference points)
# ══════════════════════════════════════════════════════════════

func _mark_castle_gates(root: Node3D) -> void:
	var gate_positions : Array[Vector3] = [
		Vector3(0,           0.5, -(_woff - _WT)),
		Vector3(0,           0.5,  (_woff - _WT)),
		Vector3(-(_woff - _WT), 0.5, 0),
		Vector3( (_woff - _WT), 0.5, 0),
	]
	for gp in gate_positions:
		var marker := Area3D.new()
		marker.name        = "CastleGate"
		marker.monitoring  = false
		marker.monitorable = false
		marker.add_to_group("castle_gate")
		var col := CollisionShape3D.new()
		var sp  := SphereShape3D.new()
		sp.radius = 0.3
		col.shape = sp
		marker.add_child(col)
		marker.position = gp
		root.add_child(marker)


# ══════════════════════════════════════════════════════════════
# PRIMITIVE BOX BUILDER
# ══════════════════════════════════════════════════════════════

func _cb(root: Node3D, pos: Vector3, sz: Vector3, mat: StandardMaterial3D) -> StaticBody3D:
	var b  := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size              = sz
	mi.mesh              = bm
	mi.material_override = mat
	b.add_child(mi)
	var col := CollisionShape3D.new()
	var bs  := BoxShape3D.new()
	bs.size  = sz
	col.shape = bs
	b.add_child(col)
	b.position = pos
	root.add_child(b)
	return b


# ══════════════════════════════════════════════════════════════
# RAYCAST HELPER
# ══════════════════════════════════════════════════════════════

func _raycast(state: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = TERRAIN_COLLISION_MASK
	return state.intersect_ray(params)


# ══════════════════════════════════════════════════════════════
# ENVIRONMENT CLEARING
# ══════════════════════════════════════════════════════════════

const _CLEAR_HALF : float = 14.0   # _W * 0.5 + 2 m margin

func _clear_trees_inside_castle(castle_pos: Vector3) -> void:
	var cleared : int = 0

	for group in ["trees","tree","foliage","props","scatter","environment","obstacles","forest","vegetation"]:
		for node in get_tree().get_nodes_in_group(group):
			if not (node is Node3D): continue
			var np : Vector3 = (node as Node3D).global_position
			if abs(np.x - castle_pos.x) < _CLEAR_HALF and abs(np.z - castle_pos.z) < _CLEAR_HALF:
				node.queue_free()
				cleared += 1

	for parent_name in ["Trees","Forest","Foliage","Props","Scatter","Environment","WorldGen","TreeContainer"]:
		var parent := get_tree().root.find_child(parent_name, true, false)
		if not is_instance_valid(parent): continue
		for child in parent.get_children():
			if not (child is Node3D): continue
			var cp : Vector3 = (child as Node3D).global_position
			if abs(cp.x - castle_pos.x) < _CLEAR_HALF and abs(cp.z - castle_pos.z) < _CLEAR_HALF:
				child.queue_free()
				cleared += 1

	if cleared > 0:
		print("[Base] Cleared %d environment objects inside castle footprint" % cleared)


func _notify_worldgen_exclusion() -> void:
	var castle_radius : float = _W * 0.5 * 0.75
	for wg in get_tree().get_nodes_in_group("world_gen"):
		if "base_clear_radius" in wg:
			var cur : float = float(wg.get("base_clear_radius"))
			if cur < castle_radius: wg.set("base_clear_radius", castle_radius)
	for wg_name in ["WorldGen","world_gen","ForestGenerator","TreeSpawner"]:
		var wg := get_tree().root.find_child(wg_name, true, false)
		if is_instance_valid(wg) and "base_clear_radius" in wg:
			var cur : float = float(wg.get("base_clear_radius"))
			if cur < castle_radius: wg.set("base_clear_radius", castle_radius)


# ══════════════════════════════════════════════════════════════
# HEALTH DISPLAY
# ══════════════════════════════════════════════════════════════

func _build_health_display() -> void:
	var lbl          := Label3D.new()
	lbl.name          = "HealthDisplay"
	lbl.billboard     = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.font_size     = 32
	lbl.outline_size  = 8
	lbl.position      = Vector3(0, 8.0, 0)
	lbl.modulate      = Color(0.2, 0.9, 0.35) if team_id == 1 else Color(0.9, 0.3, 0.2)
	lbl.text          = "Base  %d / %d" % [int(health), int(max_health)]
	lbl.no_depth_test = true
	add_child(lbl)


func _update_health_display() -> void:
	var lbl := get_node_or_null("HealthDisplay") as Label3D
	if not is_instance_valid(lbl): return
	var ratio : float = health / maxf(max_health, 1.0)
	lbl.text = "Base  %d / %d" % [int(health), int(max_health)]
	if ratio < 0.3 and fmod(Time.get_ticks_msec() * 0.005, 1.0) > 0.5:
		lbl.modulate = Color(1.0, 0.15, 0.1)
	elif ratio < 0.3:
		lbl.modulate = Color(1.0, 0.6, 0.1)
	else:
		lbl.modulate = Color(1.0 - ratio, ratio * 0.9, 0.1 + ratio * 0.3)


# ══════════════════════════════════════════════════════════════
# DAMAGE ZONE
# ══════════════════════════════════════════════════════════════

func _build_damage_zone() -> void:
	_damage_zone                  = Area3D.new()
	_damage_zone.collision_layer  = 0
	_damage_zone.collision_mask   = 0b00000100
	_damage_zone.monitoring       = true
	_damage_zone.monitorable      = false

	var col    := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 6.0
	col.shape     = sphere
	_damage_zone.add_child(col)
	add_child(_damage_zone)
	_damage_zone.body_entered.connect(_on_enemy_entered_zone)


func _on_enemy_entered_zone(body: Node) -> void:
	if not is_instance_valid(body): return
	if "team_id" in body and int(body.get("team_id")) == team_id: return


# ══════════════════════════════════════════════════════════════
# DAMAGE / DESTRUCTION
# ══════════════════════════════════════════════════════════════

func take_damage(amount: float, instigator = null) -> void:
	if health <= 0.0: return

	# REAL BUG FIX: "zombies don't hurt base" -- this used to block 100% of
	# incoming damage as long as even ONE friendly turret was alive
	# anywhere, with no cap and no falloff. game_phase_script.gd always
	# spawns 4 starting turrets at Round 1 (_spawn_starting_turrets), so
	# the base was effectively invulnerable for most of every match by
	# default, not just when meaningfully well-defended -- confirmed as a
	# real, reported symptom, not a design choice ("the base takes no
	# damage at all" rather than "turrets make the base tanky"). Turrets
	# now reduce incoming damage instead of fully blocking it, scaling
	# with how many are alive, capped well short of 100% so the base is
	# never literally unkillable regardless of turret count.
	var alive : int = 0
	var total : int = 0
	for t in get_tree().get_nodes_in_group("turrets"):
		if not is_instance_valid(t): continue
		if "team_id" in t and int(t.get("team_id")) != team_id: continue
		total += 1
		var t_alive : bool = false
		if t.has_method("is_dead"):  t_alive = not t.is_dead()
		elif "health" in t:          t_alive = float(t.get("health")) > 0.0
		if t_alive: alive += 1
	if alive > 0:
		var shield_pct : float = minf(0.20 * alive, 0.75)   # 20%/turret, capped at 75%
		amount *= (1.0 - shield_pct)
		_flash_protected()

	health       = maxf(health - amount, 0.0)
	health_value = health

	var dn : Node = get_tree().get_first_node_in_group("damage_numbers")
	if is_instance_valid(dn) and dn.has_method("spawn_number"):
		var dtype : int = 0
		if instigator != null and instigator is Object and is_instance_valid(instigator):
			if instigator.is_in_group("zombies") or instigator.is_in_group("minions"):
				dtype = 8
		dn.spawn_number(amount, global_position + Vector3(0, 4.0, 0), dtype, false)

	health_changed.emit(health, max_health)
	_update_health_display()

	if health <= 0.0:
		print("[Base] '%s' destroyed! team=%d" % [name, team_id])
		base_destroyed.emit(team_id)
		_on_destroyed()


func _flash_protected() -> void:
	for mi in find_children("*", "MeshInstance3D", true, false):
		var mesh := mi as MeshInstance3D
		var mat  := StandardMaterial3D.new()
		mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.emission_enabled           = true
		mat.emission                   = Color(0.2, 0.5, 1.0)
		mat.emission_energy_multiplier = 4.0
		mat.albedo_color               = Color(0.2, 0.5, 1.0, 0.7)
		mesh.set_surface_override_material(0, mat)
		get_tree().create_timer(0.12).timeout.connect(
			func(): if is_instance_valid(mesh): mesh.set_surface_override_material(0, null),
			CONNECT_ONE_SHOT)


func _on_destroyed() -> void:
	var gm := get_tree().get_first_node_in_group("game_manager")
	if is_instance_valid(gm) and gm.has_method("_on_base_died"):
		gm._on_base_died(team_id)


func is_dead()           -> bool:  return health <= 0.0
func get_health_ratio()  -> float: return health / max_health if max_health > 0.0 else 0.0


# ══════════════════════════════════════════════════════════════
# TURRET SPAWNING
# ══════════════════════════════════════════════════════════════

func _turret_near_grav_lift(pos: Vector3) -> bool:
	var castle        := get_tree().current_scene.get_node_or_null("Castle")
	var castle_origin : Vector3 = castle.global_position \
		if is_instance_valid(castle) else global_position
	for lift_local in _grav_lift_positions:
		var lift_world : Vector3 = castle_origin + lift_local
		var dx : float = pos.x - lift_world.x
		var dz : float = pos.z - lift_world.z
		if sqrt(dx * dx + dz * dz) < GRAV_LIFT_EXCLUSION_RADIUS:
			return true
	return false


func _spawn_starting_turrets() -> void:
	print("[Base] _spawn_starting_turrets | name=%s | team_id=%d | pos=%s" % [
		name, team_id, str(global_position.snapped(Vector3.ONE))])

	const TURRET_COUNT  : int   = 3
	const TURRET_RADIUS : float = 8.0
	const TURRET_SPREAD : float = 50.0
	const MAX_ATTEMPTS  : int   = 24

	# Auto-assign team 2 if the second base node has no explicit team assigned.
	var all_bases : Array = get_tree().get_nodes_in_group("bases")
	if all_bases.size() >= 2:
		var has_team2 : bool = false
		for b in all_bases:
			if is_instance_valid(b) and "team_id" in b and int(b.get("team_id")) == 2:
				has_team2 = true; break
		if not has_team2:
			var max_z      : float  = -1e9
			var team2_base : Node3D = null
			for b in all_bases:
				if not is_instance_valid(b) or not (b is Node3D): continue
				var z : float = (b as Node3D).global_position.z + (b as Node3D).global_position.x * 0.001
				if z > max_z:
					max_z = z; team2_base = b as Node3D
			if is_instance_valid(team2_base) and "team_id" in team2_base:
				team2_base.set("team_id", 2)
				if team2_base == self: team_id = 2
				print("[Base] Auto-assigned team_id=2 to '%s'" % team2_base.name)

	# Find turret resource
	var t_scene  : PackedScene = null
	var t_script : Script      = null
	for p in ["res://scenes/turret.tscn","res://turret.tscn","res://scenes/Turret.tscn","res://Turret.tscn"]:
		if ResourceLoader.exists(p): t_scene = load(p); break
	if not is_instance_valid(t_scene):
		for p in ["res://scripts/turret.gd","res://turret.gd","res://scripts/Turret.gd","res://Turret.gd"]:
			if ResourceLoader.exists(p): t_script = load(p); break

	# Direction toward enemy
	var enemy_dir : Vector3 = Vector3.ZERO
	for b in get_tree().get_nodes_in_group("bases"):
		if not is_instance_valid(b) or b == self: continue
		if "team_id" in b and int(b.get("team_id")) != team_id:
			enemy_dir = ((b as Node3D).global_position - global_position)
			enemy_dir.y = 0.0
			if enemy_dir.length_squared() > 0.01:
				enemy_dir = enemy_dir.normalized()
			break
	if enemy_dir == Vector3.ZERO:
		enemy_dir = Vector3.FORWARD if team_id == 1 else Vector3.BACK
		push_warning("[Base] '%s' (team %d) couldn't find enemy base!" % [name, team_id])

	var space := get_tree().root.get_world_3d().direct_space_state

	for i in TURRET_COUNT:
		var placed     : bool  = false
		var base_angle : float = -TURRET_SPREAD + i * TURRET_SPREAD

		for attempt in MAX_ATTEMPTS:
			var jitter    : float   = 0.0 if attempt == 0 else (randf() - 0.5) * 30.0
			var rot_basis : Basis   = Basis(Vector3.UP, deg_to_rad(base_angle + jitter))
			var radius    : float   = TURRET_RADIUS + attempt * 0.8
			var candidate : Vector3 = global_position + rot_basis * enemy_dir * radius

			var floor_y   : float = candidate.y
			var hit_floor : bool  = false
			if is_instance_valid(space):
				var hit := _raycast(space,
					Vector3(candidate.x, candidate.y + 80.0, candidate.z),
					Vector3(candidate.x, candidate.y - 80.0, candidate.z))
				if not hit.is_empty():
					var normal : Vector3 = hit.normal
					if normal.dot(Vector3.UP) > 0.85:
						floor_y   = float((hit.position as Vector3).y)
						hit_floor = true

			if not hit_floor:
				print("[Base] Turret %d attempt %d: no flat floor, skipping" % [i + 1, attempt + 1])
				continue

			var pos : Vector3 = Vector3(candidate.x, floor_y, candidate.z)

			if _turret_near_grav_lift(pos):
				print("[Base] Turret %d attempt %d: too close to grav lift" % [i + 1, attempt + 1])
				continue

			var turret : Node3D = null
			if is_instance_valid(t_scene):
				turret = t_scene.instantiate() as Node3D
			elif is_instance_valid(t_script):
				turret = StaticBody3D.new()
				turret.set_script(t_script)
			else:
				_build_proc_turret(pos)
				placed = true
				break

			if not is_instance_valid(turret):
				break

			if "team_id" in turret: turret.set("team_id", team_id)
			get_tree().current_scene.add_child(turret)
			turret.global_position = pos
			if "team_id" in turret: turret.set("team_id", team_id)
			if turret.has_method("set_team"): turret.set_team(team_id)
			print("[Base] Spawned turret %d | team=%d | pos=%s" % [
				i + 1, team_id, str(pos.snapped(Vector3.ONE))])
			placed = true
			break

		if not placed:
			push_warning("[Base] Turret %d: no valid floor after %d attempts" % [i + 1, MAX_ATTEMPTS])


func _build_proc_turret(pos: Vector3) -> void:
	var root : StaticBody3D = StaticBody3D.new()
	root.name = "ProceduralTurret"

	var bt : Script = null
	for p in ["res://scripts/BaseTurret.gd","res://BaseTurret.gd","res://scripts/turret.gd"]:
		if ResourceLoader.exists(p): bt = load(p); break
	if is_instance_valid(bt):
		root.set_script(bt)
		root.set("team_id", team_id)

	get_tree().current_scene.add_child(root)
	root.global_position = pos
	if "team_id" in root: root.set("team_id", team_id)

	var mi  := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius    = 0.6
	cyl.bottom_radius = 0.8
	cyl.height        = 2.5
	mi.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color     = Color(0.2, 0.5, 0.2) if team_id == 1 else Color(0.5, 0.2, 0.2)
	mat.emission_enabled = true
	mat.emission         = mat.albedo_color * 0.4
	mi.material_override = mat
	root.add_child(mi)

	var col := CollisionShape3D.new()
	var cs  := CylinderShape3D.new()
	cs.radius = 0.8
	cs.height = 2.5
	col.shape = cs
	root.add_child(col)
