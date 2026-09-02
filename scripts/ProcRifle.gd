# ============================================================
# ProcRifle.gd  —  code-built AK-style rifle
# ============================================================
# No asset: a low-poly but solid rifle built from boxes. Barrel points
# down -Z (forward), grip roughly at the origin, ~0.75 m long. Dark metal
# + wood furniture. A "Muzzle" Marker3D sits at the barrel tip for VFX.
#
# Used by basegun.gd when use_procedural_model is on -- it hides the old
# imported "ak48" child (which imported ~14x scaled and mis-oriented) and
# adds this instead. Build it facing -Z so the shared viewmodel math needs
# no rotation offset (basegun sets vm_rotation to zero).
# ============================================================
extends Node3D

var _built : bool = false


func _ready() -> void:
	if _built:
		return
	_built = true
	_build()


func _build() -> void:
	var metal := _mat(Color(0.10, 0.10, 0.12), 0.9, 0.38)
	var dark  := _mat(Color(0.05, 0.05, 0.06), 0.7, 0.5)
	var wood  := _mat(Color(0.28, 0.16, 0.07), 0.0, 0.72)

	_box("Receiver",  Vector3(0.046, 0.060, 0.26),  Vector3(0.0, 0.0, -0.04),  Vector3.ZERO, metal)
	_box("Barrel",    Vector3(0.017, 0.017, 0.34),  Vector3(0.0, 0.006, -0.30), Vector3.ZERO, dark)
	_box("Handguard", Vector3(0.044, 0.048, 0.15),  Vector3(0.0, -0.004, -0.20), Vector3.ZERO, wood)
	_box("GasTube",   Vector3(0.012, 0.012, 0.15),  Vector3(0.0, 0.030, -0.20), Vector3.ZERO, metal)
	_box("Stock",     Vector3(0.034, 0.058, 0.20),  Vector3(0.0, -0.006, 0.17), Vector3(-4.0, 0.0, 0.0), wood)
	_box("Grip",      Vector3(0.030, 0.090, 0.036), Vector3(0.0, -0.058, 0.03), Vector3(22.0, 0.0, 0.0), wood)
	_box("MagTop",    Vector3(0.030, 0.070, 0.050), Vector3(0.0, -0.070, -0.055), Vector3(14.0, 0.0, 0.0), dark)
	_box("MagCurve",  Vector3(0.028, 0.060, 0.046), Vector3(0.0, -0.128, -0.088), Vector3(32.0, 0.0, 0.0), dark)
	_box("FrontSight", Vector3(0.008, 0.028, 0.012), Vector3(0.0, 0.032, -0.44), Vector3.ZERO, metal)
	_box("RearSight",  Vector3(0.024, 0.016, 0.012), Vector3(0.0, 0.036, -0.01), Vector3.ZERO, metal)
	_box("Muzzle",     Vector3(0.022, 0.022, 0.030), Vector3(0.0, 0.006, -0.475), Vector3.ZERO, dark)

	var muzzle := Marker3D.new()
	muzzle.name = "MuzzlePoint"
	muzzle.position = Vector3(0.0, 0.006, -0.50)
	add_child(muzzle)


func _box(nm: String, size: Vector3, pos: Vector3, rot_deg: Vector3, mat: Material) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = bm
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _mat(albedo: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.metallic = metallic
	m.roughness = roughness
	return m
