extends Node3D

@export var base_a_path      : NodePath
@export var base_b_path      : NodePath
@export var color            : Color = Color(1.0, 0.45, 0.0, 0.85)
@export var width            : float = 0.4
@export var segments         : int   = 20
@export var arc_height       : float = 30.0
@export var particle_count   : int   = 12
@export var particle_speed   : float = 0.4
@export var particle_size_min: float = 0.3
@export var particle_size_max: float = 0.9
@export var particle_trail_length: float = 0.06

var _mesh_instance  : MeshInstance3D
var _immediate_mesh : ImmediateMesh
var _base_a         : Node3D
var _base_b         : Node3D
var _particles      : Array = []
var _time           : float = 0.0


func _ready() -> void:
	_base_a = get_node_or_null(base_a_path)
	_base_b = get_node_or_null(base_b_path)

	if not is_instance_valid(_base_a) or not is_instance_valid(_base_b):
		await _resolve_bases()

	_build_mesh()
	_build_particles()


# ── Base resolution ───────────────────────────────────────────
func _resolve_bases() -> void:
	var bl := get_node_or_null("/root/BaseLocator")
	if is_instance_valid(bl):
		if bl.has_signal("bases_ready") and not (bl.get("is_ready") if "is_ready" in bl else true):
			await bl.bases_ready
		if "base1" in bl and is_instance_valid(bl.base1): _base_a = bl.base1
		if "base2" in bl and is_instance_valid(bl.base2): _base_b = bl.base2
		if is_instance_valid(_base_a) and is_instance_valid(_base_b):
			print("[BaseArcBeam] Got bases from BaseLocator")
			return
	_find_bases_auto()


func _find_bases_auto() -> void:
	var bases := get_tree().get_nodes_in_group("bases")
	if bases.size() >= 2:
		_base_a = bases[0] as Node3D
		_base_b = bases[1] as Node3D
		return
	if bases.size() == 1:
		_base_a = bases[0] as Node3D

	if not is_instance_valid(_base_a):
		for n in ["Base","base","Base1","base1","PlayerBase","Team1Base"]:
			var nd := get_tree().root.find_child(n, true, false)
			if is_instance_valid(nd) and nd is Node3D: _base_a = nd; break

	if not is_instance_valid(_base_b):
		for n in ["Base 2","base2","Base2","EnemyBase","Team2Base"]:
			var nd := get_tree().root.find_child(n, true, false)
			if is_instance_valid(nd) and nd is Node3D: _base_b = nd; break

	if is_instance_valid(_base_a) and is_instance_valid(_base_b):
		print("[BaseArcBeam] Auto-found: %s → %s" % [_base_a.name, _base_b.name])
	else:
		push_warning("[BaseArcBeam] Could not find both bases — assign base_a_path/base_b_path in Inspector")


# ── Mesh setup ────────────────────────────────────────────────
func _build_mesh() -> void:
	_immediate_mesh = ImmediateMesh.new()
	_mesh_instance  = MeshInstance3D.new()
	_mesh_instance.mesh = _immediate_mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled           = true
	mat.emission                   = color
	mat.emission_energy_multiplier = 3.0
	mat.albedo_color               = color
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	_mesh_instance.material_override = mat
	add_child(_mesh_instance)


func _build_particles() -> void:
	_particles.clear()
	for i in particle_count:
		_particles.append({
			"t":     float(i) / float(particle_count),
			"size":  randf_range(particle_size_min, particle_size_max),
			"speed": particle_speed * randf_range(0.8, 1.2),
		})


# ── Process ───────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not is_instance_valid(_base_a) or not is_instance_valid(_base_b):
		_find_bases_auto(); return
	if not is_instance_valid(_immediate_mesh): return

	_time += delta
	for p in _particles:
		p["t"] = fmod(p["t"] + p["speed"] * delta, 1.0)

	_immediate_mesh.clear_surfaces()
	var cam     := get_viewport().get_camera_3d()
	var cam_pos := cam.global_position if is_instance_valid(cam) else Vector3.UP * 999.0

	# Arc ribbon
	_immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in segments:
		var t0 := float(i)     / float(segments)
		var t1 := float(i + 1) / float(segments)
		_add_ribbon_quad(t0, t1, cam_pos, color, width)
	_immediate_mesh.surface_end()

	# Particle streaks
	_immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in _particles:
		var t_head : float = p["t"]
		var t_tail : float = maxf(t_head - particle_trail_length, 0.0)
		var sz     : float = p["size"]
		var streak := Color(
			minf(color.r * 1.8, 1.0),
			minf(color.g * 1.8, 1.0),
			minf(color.b * 1.8, 1.0), 1.0)
		_add_ribbon_quad(t_tail, t_head, cam_pos, streak, width * sz)
		_add_billboard_quad(_arc_point(t_head), cam_pos, width * sz * 1.6, color)
	_immediate_mesh.surface_end()


# ── Geometry helpers ──────────────────────────────────────────
func _add_ribbon_quad(t0: float, t1: float, cam_pos: Vector3,
		col: Color, w: float) -> void:
	var p0    := _arc_point(t0)
	var p1    := _arc_point(t1)
	var mid   := (p0 + p1) * 0.5
	var dir   := (p1 - p0).normalized()
	var right := dir.cross((cam_pos - mid).normalized()).normalized() * (w * 0.5)
	var v0 := p0 - right;  var v1 := p0 + right
	var v2 := p1 - right;  var v3 := p1 + right
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v0)
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v1)
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v2)
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v1)
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v3)
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v2)


func _add_billboard_quad(pos: Vector3, cam_pos: Vector3,
		size: float, col: Color) -> void:
	var to_cam := (cam_pos - pos).normalized()
	var up     := Vector3.UP
	if absf(to_cam.dot(up)) > 0.99: up = Vector3.RIGHT
	var right  := to_cam.cross(up).normalized()  * (size * 0.5)
	var up_vec := to_cam.cross(right).normalized() * (size * 0.5)
	var v0 := pos - right - up_vec;  var v1 := pos + right - up_vec
	var v2 := pos - right + up_vec;  var v3 := pos + right + up_vec
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v0)
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v1)
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v2)
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v1)
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v3)
	_immediate_mesh.surface_set_color(col); _immediate_mesh.surface_add_vertex(v2)


func _arc_point(t: float) -> Vector3:
	var a := _base_a.global_position
	var b := _base_b.global_position
	var p := a.lerp(b, t)
	p.y   += arc_height * 4.0 * t * (1.0 - t)
	return p
