# ============================================================
# CastleGenerator.gd  — Procedural castle around base node
# Put in res://scripts/CastleGenerator.gd
# base.gd calls generate(global_position, team_id) automatically.
# ============================================================
extends Node3D

@export var auto_generate  : bool  = true
@export var castle_size    : float = 24.0
@export var wall_thickness : float = 1.8
@export var tower_radius   : float = 4.0
@export var floor_height   : float = 4.5
@export var team_id        : int   = 1

var _stone : StandardMaterial3D
var _trim  : StandardMaterial3D
var _wood  : StandardMaterial3D

const MERLON_W : float = 0.9
const MERLON_H : float = 1.1
const MERLON_D : float = 0.85

func _ready() -> void:
	if auto_generate:
		generate(Vector3.ZERO, team_id)

# ─────────────────────────────────────────────────────────────
func generate(center: Vector3, tid: int) -> void:
	team_id = tid
	for ch in get_children(): ch.queue_free()
	_init_mats()
	var root := Node3D.new()
	root.name = "CastleRoot"
	root.position = center
	add_child(root)
	_build(root)

func _init_mats() -> void:
	var sc : Color = Color(0.50, 0.58, 0.65) if team_id == 1 else Color(0.60, 0.38, 0.36)
	_stone = _make_mat(sc)
	_trim  = _make_mat(Color(0.85, 0.80, 0.70))
	_wood  = _make_mat(Color(0.40, 0.28, 0.18))

func _make_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness    = 0.85
	m.metallic     = 0.02
	return m

# ─────────────────────────────────────────────────────────────
func _build(root: Node3D) -> void:
	var half := castle_size * 0.5
	var tr   := tower_radius

	# Corner positions
	var corners : Array[Vector3] = [
		Vector3(-half + tr, 0.0, -half + tr),
		Vector3( half - tr, 0.0, -half + tr),
		Vector3( half - tr, 0.0,  half - tr),
		Vector3(-half + tr, 0.0,  half - tr),
	]

	for i in 4:
		_build_tower(root, corners[i])

	# Curtain walls
	var gap    : float = castle_size - tr * 2.0
	var wall_h : float = floor_height * 2.0 + 1.0
	var woff   : float = half - tr * 0.5

	_wall_run(root, Vector3(0, wall_h*0.5, -woff), gap, wall_h, false, true)
	_wall_run(root, Vector3(0, wall_h*0.5,  woff), gap, wall_h, false, false)
	_wall_run(root, Vector3(-woff, wall_h*0.5, 0), gap, wall_h, true,  false)
	_wall_run(root, Vector3( woff, wall_h*0.5, 0), gap, wall_h, true,  false)

	# Courtyard floor
	var inner := castle_size - tr * 2.2
	_box(root, Vector3(0, -0.15, 0), Vector3(inner, 0.3, inner), _trim)

# ─────────────────────────────────────────────────────────────
#  TOWER
# ─────────────────────────────────────────────────────────────
func _build_tower(root: Node3D, pos: Vector3) -> void:
	var tw := tower_radius * 2.0

	# Floor 0 — ground room with arched entrance
	_tower_floor(root, pos, 0, tw)
	# Floor 1 — window room
	_tower_floor(root, pos + Vector3(0, floor_height, 0), 1, tw)
	# Floor 2 — battlements
	_tower_battlements(root, pos + Vector3(0, floor_height * 2.0, 0), tw)
	# Spiral staircase
	_spiral_stair(root, pos, tw)
	# Flag on top
	_flagpole(root, pos + Vector3(0, floor_height * 3.0 + 0.3, 0))

func _tower_floor(root: Node3D, pos: Vector3, level: int, tw: float) -> void:
	var hw := tw * 0.5
	var wt := wall_thickness
	var fh := floor_height

	# Floor slab (not on ground floor)
	if level > 0:
		_box(root, pos + Vector3(0, 0.1, 0), Vector3(tw, 0.22, tw), _trim)

	# Four walls
	# North / South (along X axis)
	for sg in [-1, 1]:
		var wp := pos + Vector3(0, fh * 0.5, float(sg) * (hw - wt * 0.5))
		if level == 0 and sg == -1:
			_arched_wall(root, wp, tw, fh, wt, true, false)
		elif level == 1:
			_arched_wall(root, wp, tw, fh, wt, false, true)
		else:
			_box(root, wp, Vector3(tw, fh, wt), _stone)

	# East / West (along Z axis)
	for sg in [-1, 1]:
		var wp := pos + Vector3(float(sg) * (hw - wt * 0.5), fh * 0.5, 0)
		if level == 1:
			_arched_wall_rot(root, wp, tw, fh, wt, false, true)
		else:
			_box(root, wp, Vector3(wt, fh, tw), _stone)

func _arched_wall(root: Node3D, pos: Vector3, tw: float, fh: float, wt: float,
		entrance: bool, window: bool) -> void:
	var aw : float = tw * 0.40 if entrance else tw * 0.28
	var ah : float = fh * 0.75 if entrance else fh * 0.48
	var sw := (tw - aw) * 0.5

	# Left pillar
	_box(root, pos + Vector3(-(sw * 0.5 + aw * 0.5), 0, 0), Vector3(sw, fh, wt), _stone)
	# Right pillar
	_box(root, pos + Vector3( (sw * 0.5 + aw * 0.5), 0, 0), Vector3(sw, fh, wt), _stone)
	# Header above arch
	var header_h := fh - ah
	_box(root, pos + Vector3(0, fh * 0.5 - header_h * 0.5, 0), Vector3(aw, header_h, wt), _stone)
	# Keystone trim
	_box(root, pos + Vector3(0, -fh * 0.5 + ah + 0.05, 0), Vector3(aw + 0.3, 0.18, wt + 0.06), _trim)
	if window:
		# Window sill
		_box(root, pos + Vector3(0, -fh * 0.5 + 0.6, 0), Vector3(aw, 0.25, wt + 0.05), _trim)

func _arched_wall_rot(root: Node3D, pos: Vector3, tw: float, fh: float, wt: float,
		entrance: bool, window: bool) -> void:
	# Same as _arched_wall but X/Z swapped (east/west faces)
	var aw : float = tw * 0.40 if entrance else tw * 0.28
	var ah : float = fh * 0.75 if entrance else fh * 0.48
	var sw := (tw - aw) * 0.5

	_box(root, pos + Vector3(0, 0, -(sw * 0.5 + aw * 0.5)), Vector3(wt, fh, sw), _stone)
	_box(root, pos + Vector3(0, 0,  (sw * 0.5 + aw * 0.5)), Vector3(wt, fh, sw), _stone)
	var header_h := fh - ah
	_box(root, pos + Vector3(0, fh * 0.5 - header_h * 0.5, 0), Vector3(wt, header_h, aw), _stone)
	_box(root, pos + Vector3(0, -fh * 0.5 + ah + 0.05, 0), Vector3(wt + 0.06, 0.18, aw + 0.3), _trim)
	if window:
		_box(root, pos + Vector3(0, -fh * 0.5 + 0.6, 0), Vector3(wt + 0.05, 0.25, aw), _trim)

func _tower_battlements(root: Node3D, pos: Vector3, tw: float) -> void:
	var hw := tw * 0.5
	var wt := wall_thickness
	var ph := 1.0   # parapet height below merlons

	# Platform slab
	_box(root, pos + Vector3(0, 0.15, 0), Vector3(tw, 0.30, tw), _trim)

	# Parapets on all 4 sides
	var dirs : Array[Vector3] = [
		Vector3(0, 0, -1), Vector3(0, 0, 1),
		Vector3(-1, 0, 0), Vector3(1, 0, 0)
	]
	for dir in dirs:
		var is_z : bool = dir.z != 0.0
		var pw : float = tw if is_z else wt
		var pd : float = wt if is_z else tw
		var ppos := pos + dir * (hw - wt * 0.5) + Vector3(0, ph * 0.5 + 0.3, 0)
		_box(root, ppos, Vector3(tw, ph, wt) if is_z else Vector3(wt, ph, tw), _stone)
		# Merlons
		var mlen := tw
		var count := int(mlen / (MERLON_W * 1.8))
		for m in count:
			var t : float = (float(m) / float(maxi(count-1, 1))) - 0.5
			var mpos : Vector3
			if is_z:
				mpos = ppos + Vector3(t * (mlen - MERLON_W), ph * 0.5 + MERLON_H * 0.5, 0)
			else:
				mpos = ppos + Vector3(0, ph * 0.5 + MERLON_H * 0.5, t * (mlen - MERLON_W))
			var msz : Vector3 = Vector3(MERLON_W, MERLON_H, MERLON_D) if is_z else Vector3(MERLON_D, MERLON_H, MERLON_W)
			_box(root, mpos, msz, _stone)

# ─────────────────────────────────────────────────────────────
#  STAIRCASE
# ─────────────────────────────────────────────────────────────
func _spiral_stair(root: Node3D, tower_center: Vector3, tw: float) -> void:
	var total_h := floor_height * 3.0
	var steps   := int(total_h / 0.35)
	var radius  := tower_radius * 0.52
	var angle   := 0.0
	var ainc    := TAU / float(steps)

	for s in steps:
		var y    := s * 0.35
		var sp   := tower_center + Vector3(cos(angle) * radius, y, sin(angle) * radius)
		var step := _box(root, sp, Vector3(0.85, 0.37, 0.55), _trim)
		step.rotation.y = angle
		angle += ainc

	# Wood floor landings
	for f in 3:
		_box(root, tower_center + Vector3(0, f * floor_height + 0.12, 0),
			Vector3(tw * 0.7, 0.18, tw * 0.7), _wood)

# ─────────────────────────────────────────────────────────────
#  CURTAIN WALL
# ─────────────────────────────────────────────────────────────
func _wall_run(root: Node3D, pos: Vector3, length: float, wall_h: float,
		rotated: bool, with_gate: bool) -> void:
	var wt := wall_thickness

	if with_gate:
		var gate_w : float = 4.0
		var side_l : float = (length - gate_w) * 0.5
		var side_off : float = (side_l + gate_w) * 0.5

		# Left and right wall panels
		for sg in [-1, 1]:
			var offset : Vector3
			if rotated:
				offset = Vector3(0, 0, float(sg) * side_off)
				_box(root, pos + offset, Vector3(wt, wall_h, side_l), _stone)
				_wall_merlons(root, pos + offset + Vector3(0, wall_h * 0.5, 0), side_l, true)
			else:
				offset = Vector3(float(sg) * side_off, 0, 0)
				_box(root, pos + offset, Vector3(side_l, wall_h, wt), _stone)
				_wall_merlons(root, pos + offset + Vector3(0, wall_h * 0.5, 0), side_l, false)

		# Gate lintel
		_box(root, pos + Vector3(0, wall_h * 0.5 - 0.7, 0),
			Vector3(gate_w + 0.2, 1.4, wt) if not rotated else Vector3(wt, 1.4, gate_w + 0.2), _stone)
		_box(root, pos + Vector3(0, wall_h * 0.5 - 1.4, 0),
			Vector3(gate_w + 0.5, 0.22, wt + 0.1) if not rotated else Vector3(wt + 0.1, 0.22, gate_w + 0.5), _trim)
	else:
		if rotated:
			_box(root, pos, Vector3(wt, wall_h, length), _stone)
			_wall_merlons(root, pos + Vector3(0, wall_h * 0.5, 0), length, true)
		else:
			_box(root, pos, Vector3(length, wall_h, wt), _stone)
			_wall_merlons(root, pos + Vector3(0, wall_h * 0.5, 0), length, false)

func _wall_merlons(root: Node3D, top_pos: Vector3, length: float, rotated: bool) -> void:
	var count := int(length / (MERLON_W * 1.8))
	for i in count:
		var t : float = (float(i) / float(maxi(count-1,1))) - 0.5
		var mpos : Vector3
		var msz  : Vector3
		if rotated:
			mpos = top_pos + Vector3(0, MERLON_H * 0.5, t * (length - MERLON_W))
			msz  = Vector3(MERLON_D, MERLON_H, MERLON_W)
		else:
			mpos = top_pos + Vector3(t * (length - MERLON_W), MERLON_H * 0.5, 0)
			msz  = Vector3(MERLON_W, MERLON_H, MERLON_D)
		_box(root, mpos, msz, _stone)

# ─────────────────────────────────────────────────────────────
#  FLAGPOLE
# ─────────────────────────────────────────────────────────────
func _flagpole(root: Node3D, pos: Vector3) -> void:
	_box(root, pos + Vector3(0, 1.8, 0), Vector3(0.14, 3.6, 0.14), _wood)
	var flag := MeshInstance3D.new()
	var qm   := QuadMesh.new(); qm.size = Vector2(1.4, 0.8)
	flag.mesh = qm
	var fm := StandardMaterial3D.new()
	fm.albedo_color     = Color(0.15, 0.5, 0.9) if team_id == 1 else Color(0.8, 0.2, 0.2)
	fm.emission_enabled = true
	fm.emission         = fm.albedo_color * 0.5
	fm.emission_energy_multiplier = 1.5
	fm.cull_mode        = BaseMaterial3D.CULL_DISABLED
	flag.material_override = fm
	flag.position = pos + Vector3(0.8, 3.2, 0)
	flag.rotation.y = PI * 0.5
	flag.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(flag)

# ─────────────────────────────────────────────────────────────
#  BOX HELPER
# ─────────────────────────────────────────────────────────────
func _box(root: Node3D, pos: Vector3, sz: Vector3,
		mat: StandardMaterial3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	var mi   := MeshInstance3D.new()
	var bm   := BoxMesh.new(); bm.size = sz
	mi.mesh  = bm; mi.material_override = mat
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var bs  := BoxShape3D.new(); bs.size = sz
	col.shape = bs; body.add_child(col)
	body.position = pos
	root.add_child(body)
	return body
