# ============================================================
# ProcGreatsword.gd  —  procedurally-built "bad ass" blade
# ============================================================
# No asset download: builds a tapered double-edged greatsword in code --
# dark chrome blade with a glowing edge shell, bronze swept crossguard,
# wrapped grip, faceted pommel, three emissive runes, an ember drift and
# a soft blade light. Blade points down -Z (forward, away from the viewer).
#
# Materials are set at the MESH level (not material_override) on purpose:
# sword.gd's enchant / swing FX slam material_override on every mesh child
# to tint the blade, then clear it back to null -- with mesh-level
# materials that tint lands on this blade too and cleanly reverts.
# set_glow_color() separately retints the glow shell / runes / light /
# embers, which sword.gd doesn't touch.
# ============================================================
extends Node3D

const BLADE_LEN   : float = 0.98
const BLADE_HW    : float = 0.052   # half-width at the guard
const BLADE_HT    : float = 0.010   # half-thickness at the guard
const RINGS       : int   = 9
const DEFAULT_GLOW : Color = Color(0.30, 0.85, 1.0)

var glow_color : Color = DEFAULT_GLOW

var _glow_mat  : StandardMaterial3D
var _rune_mats : Array[StandardMaterial3D] = []
var _light     : OmniLight3D
var _embers    : GPUParticles3D
var _built     : bool = false


func _ready() -> void:
	if _built:
		return
	_built = true
	_build()


func _build() -> void:
	var steel := _mat(Color(0.13, 0.14, 0.17), 1.0, 0.22)
	var bronze := _mat(Color(0.46, 0.35, 0.16), 0.9, 0.42)
	var grip_m := _mat(Color(0.07, 0.06, 0.06), 0.0, 0.92)

	# ── blade ────────────────────────────────────────────────
	var blade_mesh := _make_blade_mesh(1.0)
	blade_mesh.surface_set_material(0, steel)
	var blade := MeshInstance3D.new()
	blade.name = "Blade"
	blade.mesh = blade_mesh
	blade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(blade)

	# glow shell -- same silhouette, slightly inflated, additive emissive
	_glow_mat = StandardMaterial3D.new()
	_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_glow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_glow_mat.albedo_color = Color(glow_color.r, glow_color.g, glow_color.b, 0.10)
	_glow_mat.emission_enabled = true
	_glow_mat.emission = glow_color
	_glow_mat.emission_energy_multiplier = 4.5

	var shell_mesh := _make_blade_mesh(1.18)
	shell_mesh.surface_set_material(0, _glow_mat)
	var shell := MeshInstance3D.new()
	shell.name = "GlowShell"
	shell.mesh = shell_mesh
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shell)

	# ── runes on the blade flat ──────────────────────────────
	for i in 3:
		var bm := BoxMesh.new()
		bm.size = Vector3(0.018, 0.0006, 0.018)
		var rm := StandardMaterial3D.new()
		rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		rm.emission_enabled = true
		rm.emission = glow_color
		rm.emission_energy_multiplier = 5.0
		rm.albedo_color = glow_color
		bm.material = rm
		_rune_mats.append(rm)
		var r := MeshInstance3D.new()
		r.name = "Rune%d" % i
		r.mesh = bm
		r.position = Vector3(0.0, BLADE_HT + 0.001, -0.20 - 0.22 * i)
		add_child(r)

	# ── crossguard ───────────────────────────────────────────
	var gm := BoxMesh.new()
	gm.size = Vector3(0.24, 0.028, 0.055)
	gm.material = bronze
	var guard := MeshInstance3D.new()
	guard.name = "Crossguard"
	guard.mesh = gm
	add_child(guard)
	for s in [-1.0, 1.0]:
		var cbm := BoxMesh.new()
		cbm.size = Vector3(0.055, 0.026, 0.05)
		cbm.material = bronze
		var cap := MeshInstance3D.new()
		cap.name = "GuardTip%s" % ("L" if s < 0.0 else "R")
		cap.mesh = cbm
		cap.position = Vector3(s * 0.135, 0.0, -0.006)
		cap.rotation_degrees = Vector3(0.0, s * -22.0, 0.0)
		add_child(cap)

	# ── grip + pommel ────────────────────────────────────────
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0135
	cm.bottom_radius = 0.0135
	cm.height = 0.15
	cm.radial_segments = 12
	cm.material = grip_m
	var grip := MeshInstance3D.new()
	grip.name = "Grip"
	grip.mesh = cm
	grip.rotation_degrees = Vector3(90.0, 0.0, 0.0)   # cylinder axis -> Z
	grip.position = Vector3(0.0, 0.0, 0.086)
	add_child(grip)

	var sm := SphereMesh.new()
	sm.radius = 0.028
	sm.height = 0.056
	sm.radial_segments = 8
	sm.rings = 4
	sm.material = bronze
	var pommel := MeshInstance3D.new()
	pommel.name = "Pommel"
	pommel.mesh = sm
	pommel.position = Vector3(0.0, 0.0, 0.17)
	add_child(pommel)

	# ── blade light + embers ─────────────────────────────────
	_light = OmniLight3D.new()
	_light.name = "BladeLight"
	_light.light_color = glow_color
	_light.light_energy = 0.7
	_light.omni_range = 1.7
	_light.shadow_enabled = false
	_light.position = Vector3(0.0, 0.0, -0.4)
	add_child(_light)

	_embers = GPUParticles3D.new()
	_embers.name = "Embers"
	_embers.amount = 22
	_embers.lifetime = 0.9
	_embers.local_coords = true
	_embers.position = Vector3(0.0, 0.0, -0.45)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(0.02, 0.02, 0.5)
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 25.0
	pm.gravity = Vector3(0.0, 0.15, 0.0)
	pm.initial_velocity_min = 0.05
	pm.initial_velocity_max = 0.18
	pm.scale_min = 0.15
	pm.scale_max = 0.5
	pm.color = glow_color
	_embers.process_material = pm
	var qd := QuadMesh.new()
	qd.size = Vector2(0.01, 0.01)
	var em := StandardMaterial3D.new()
	em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	em.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	em.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	em.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	em.emission_enabled = true
	em.emission = glow_color
	em.emission_energy_multiplier = 3.0
	em.albedo_color = Color(glow_color.r, glow_color.g, glow_color.b, 0.8)
	qd.material = em
	_embers.draw_pass_1 = qd
	add_child(_embers)


func set_glow_color(c: Color) -> void:
	glow_color = c
	if is_instance_valid(_glow_mat):
		_glow_mat.emission = c
		_glow_mat.albedo_color = Color(c.r, c.g, c.b, 0.10)
	for rm in _rune_mats:
		if is_instance_valid(rm):
			rm.emission = c
			rm.albedo_color = c
	if is_instance_valid(_light):
		_light.light_color = c
	if is_instance_valid(_embers) and _embers.process_material is ParticleProcessMaterial:
		(_embers.process_material as ParticleProcessMaterial).color = c
		if _embers.draw_pass_1 is QuadMesh and (_embers.draw_pass_1 as QuadMesh).material is StandardMaterial3D:
			var m := (_embers.draw_pass_1 as QuadMesh).material as StandardMaterial3D
			m.emission = c
			m.albedo_color = Color(c.r, c.g, c.b, 0.8)


# ── blade mesh: 4-point lens cross-section swept + tapered to a tip ──
func _make_blade_mesh(width_mul: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var ring_pts : Array = []      # each entry: [right, front, left, back] Vector3
	for i in RINGS:
		var f : float = float(i) / float(RINGS - 1)
		var z : float = -BLADE_LEN * f
		var w : float = BLADE_HW * width_mul * pow(1.0 - f, 0.62)
		var t : float = BLADE_HT * width_mul * (1.0 - 0.55 * f)
		w = maxf(w, 0.0008)
		t = maxf(t, 0.0006)
		ring_pts.append([
			Vector3( w, 0.0, z),
			Vector3(0.0,  t, z),
			Vector3(-w, 0.0, z),
			Vector3(0.0, -t, z),
		])

	var r0 : Array = ring_pts[0]                       # base cap
	_tri(st, r0[0], r0[1], r0[2])
	_tri(st, r0[0], r0[2], r0[3])

	for i in RINGS - 1:                                # body
		var a : Array = ring_pts[i]
		var b : Array = ring_pts[i + 1]
		for k in 4:
			var k2 : int = (k + 1) % 4
			_quad(st, a[k], b[k], b[k2], a[k2])

	var tip := Vector3(0.0, 0.0, -BLADE_LEN - 0.02)    # tip fan
	var last : Array = ring_pts[RINGS - 1]
	for k in 4:
		var k2 : int = (k + 1) % 4
		_tri(st, last[k], tip, last[k2])

	st.generate_normals()
	var m : ArrayMesh = st.commit()
	return m


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)


func _mat(albedo: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.metallic = metallic
	m.roughness = roughness
	return m
