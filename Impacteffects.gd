# ============================================================
# ImpactEffects.gd — Autoload
# Spawns hit sparks, blood puffs, gore explosions, footstep
# dust, shell casings and explosions.
# All fades use tween_method on material albedo_color.a
# (MeshInstance3D has no modulate property).
# ============================================================
extends Node

func _ready() -> void:
	add_to_group("impact_effects")


# ── Bullet impact spark ───────────────────────────────────────
func spawn_hit_spark(pos: Vector3, normal: Vector3, surface: String = "default") -> void:
	var root := get_tree().current_scene
	for _i in randi_range(4, 8):
		var spark := MeshInstance3D.new()
		var sm    := SphereMesh.new()
		sm.radius = 0.04; sm.height = 0.08
		spark.mesh = sm
		var col : Color
		match surface:
			"metal": col = Color(1.0, 0.85, 0.3)
			"flesh": col = Color(0.85, 0.1, 0.05)
			"wood":  col = Color(0.6, 0.35, 0.1)
			_:       col = Color(1.0, 0.9, 0.6)
		var mat := StandardMaterial3D.new()
		mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color               = col
		mat.emission_enabled           = true
		mat.emission                   = col
		mat.emission_energy_multiplier = 5.0
		spark.material_override = mat
		root.add_child(spark)
		spark.global_position = pos + normal * 0.05
		var vel  := (normal + Vector3(randf_range(-1,1), randf_range(0.2,1), randf_range(-1,1))).normalized() \
					* randf_range(2.5, 6.0)
		var life := randf_range(0.12, 0.28)
		var tw   := spark.create_tween().set_parallel(true)
		tw.tween_property(spark, "global_position", spark.global_position + vel * life, life)
		tw.tween_property(spark, "scale", Vector3.ZERO, life)
		tw.chain().tween_callback(spark.queue_free)


# ── Small blood puff (player hit) ────────────────────────────
func spawn_blood(pos: Vector3, amount: float = 1.0) -> void:
	var root  := get_tree().current_scene
	var count : int = int(clampf(amount * 5, 3, 12))
	for _i in count:
		var b  := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = randf_range(0.05, 0.15)
		b.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.6, 0.02, 0.02, 0.9)
		b.material_override = mat
		root.add_child(b)
		b.global_position = pos + Vector3(
			randf_range(-0.2, 0.2),
			randf_range(0.0,  0.3),
			randf_range(-0.2, 0.2))
		var vel  := Vector3(randf_range(-1,1), randf_range(0.5,2), randf_range(-1,1)) \
					* randf_range(1.0, 3.0)
		var life := randf_range(0.3, 0.6)
		var tw := b.create_tween().set_parallel(true)
		tw.tween_property(b, "global_position", b.global_position + vel * life, life)
		var tw2 := b.create_tween()
		tw2.tween_interval(life * 0.5)
		tw2.tween_method(
			func(a: float): if is_instance_valid(mat): mat.albedo_color.a = a,
			0.9, 0.0, life * 0.5)
		tw2.tween_callback(b.queue_free)


# ── Full gore explosion (zombie death) ───────────────────────
func spawn_gore_explosion(pos: Vector3, amount: float = 1.0) -> void:
	var root := get_tree().current_scene

	# Blood droplets — many small spheres flying outward
	for _i in int(clampf(amount * 22, 12, 45)):
		var b  := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = randf_range(0.03, 0.18)
		b.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(
			randf_range(0.4, 0.7),
			randf_range(0.0, 0.04),
			randf_range(0.0, 0.03), 1.0)
		b.material_override = mat
		root.add_child(b)
		b.global_position = pos + Vector3(
			randf_range(-0.25, 0.25),
			randf_range(0.1,  0.6),
			randf_range(-0.25, 0.25))
		var vel  := Vector3(
			randf_range(-1, 1),
			randf_range(0.5, 3.5),
			randf_range(-1, 1)).normalized() * randf_range(2.0, 9.0)
		var life := randf_range(0.35, 0.9)
		var tw := b.create_tween().set_parallel(true)
		tw.tween_property(b, "global_position", b.global_position + vel * life, life)
		tw.tween_property(b, "scale", Vector3.ZERO, life * 0.85)
		tw.tween_method(
			func(a: float): if is_instance_valid(mat): mat.albedo_color.a = a,
			1.0, 0.0, life)
		tw.chain().tween_callback(b.queue_free)

	# Flesh chunks — box-shaped, tumble outward
	for _i in randi_range(4, 8):
		var chunk := MeshInstance3D.new()
		var cm    := BoxMesh.new()
		cm.size = Vector3.ONE * randf_range(0.06, 0.20)
		chunk.mesh = cm
		var cmat := StandardMaterial3D.new()
		cmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		cmat.albedo_color = Color(
			randf_range(0.45, 0.65),
			randf_range(0.02, 0.06),
			randf_range(0.02, 0.05), 1.0)
		chunk.material_override = cmat
		root.add_child(chunk)
		chunk.global_position = pos + Vector3(0, 0.4, 0)
		var cvel  := Vector3(
			randf_range(-1, 1),
			randf_range(1.0, 4.5),
			randf_range(-1, 1)).normalized() * randf_range(3.0, 11.0)
		var clife := randf_range(0.5, 1.4)
		var ctw := chunk.create_tween().set_parallel(true)
		ctw.tween_property(chunk, "global_position",
			chunk.global_position + cvel * clife, clife)
		ctw.tween_property(chunk, "rotation_degrees",
			Vector3(randf_range(0,720), randf_range(0,720), randf_range(0,720)), clife)
		ctw.tween_method(
			func(a: float): if is_instance_valid(cmat): cmat.albedo_color.a = a,
			1.0, 0.0, clife * 0.4)
		ctw.chain().tween_callback(chunk.queue_free)

	# Blood splat decals on ground — flat quads
	for _i in randi_range(3, 6):
		var splat := MeshInstance3D.new()
		var qm    := QuadMesh.new()
		qm.size = Vector2(randf_range(0.25, 1.1), randf_range(0.25, 1.1))
		splat.mesh = qm
		var smat := StandardMaterial3D.new()
		smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		smat.albedo_color = Color(0.32, 0.01, 0.01, 0.88)
		smat.cull_mode    = BaseMaterial3D.CULL_DISABLED
		splat.material_override = smat
		root.add_child(splat)
		splat.global_position = pos + Vector3(
			randf_range(-1.8, 1.8), 0.015, randf_range(-1.8, 1.8))
		splat.rotation_degrees = Vector3(-90, randf_range(0, 360), 0)
		# Fade after 10 seconds
		var stw := splat.create_tween()
		stw.tween_interval(10.0)
		stw.tween_method(
			func(a: float): if is_instance_valid(smat): smat.albedo_color.a = a,
			0.88, 0.0, 2.5)
		stw.tween_callback(splat.queue_free)

	# Mist / spray — tiny emissive spheres
	for _i in randi_range(6, 12):
		var mist := MeshInstance3D.new()
		var mm   := SphereMesh.new()
		mm.radius = randf_range(0.02, 0.06)
		mist.mesh = mm
		var mmat := StandardMaterial3D.new()
		mmat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
		mmat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
		mmat.albedo_color               = Color(0.6, 0.02, 0.02, 0.7)
		mmat.emission_enabled           = true
		mmat.emission                   = Color(0.5, 0.01, 0.01)
		mmat.emission_energy_multiplier = 1.5
		mist.material_override = mmat
		root.add_child(mist)
		mist.global_position = pos + Vector3(
			randf_range(-0.3, 0.3),
			randf_range(0.2, 1.0),
			randf_range(-0.3, 0.3))
		var mvel  := Vector3(randf_range(-1,1), randf_range(0.3,1.5), randf_range(-1,1)) \
					* randf_range(0.5, 2.5)
		var mlife := randf_range(0.2, 0.5)
		var mtw := mist.create_tween().set_parallel(true)
		mtw.tween_property(mist, "global_position", mist.global_position + mvel * mlife, mlife)
		mtw.tween_method(
			func(a: float): if is_instance_valid(mmat): mmat.albedo_color.a = a,
			0.7, 0.0, mlife)
		mtw.chain().tween_callback(mist.queue_free)


# ── Footstep dust ─────────────────────────────────────────────
func spawn_footstep_dust(pos: Vector3) -> void:
	var root := get_tree().current_scene
	for _i in 3:
		var d  := MeshInstance3D.new()
		var sm := SphereMesh.new(); sm.radius = 0.08
		d.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.55, 0.48, 0.38, 0.5)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		d.material_override = mat
		root.add_child(d)
		d.global_position = pos + Vector3(randf_range(-0.15,0.15), 0.05, randf_range(-0.15,0.15))
		var start_pos := d.global_position
		var tw := d.create_tween().set_parallel(true)
		tw.tween_property(d, "scale", Vector3(2.5, 0.5, 2.5), 0.35)
		tw.tween_property(d, "global_position", start_pos + Vector3(0, 0.3, 0), 0.35)
		tw.tween_method(
			func(a: float): if is_instance_valid(mat): mat.albedo_color.a = a,
			0.5, 0.0, 0.35)
		tw.chain().tween_callback(d.queue_free)


# ── Shell casing ──────────────────────────────────────────────
func spawn_shell(pos: Vector3, right: Vector3) -> void:
	var root  := get_tree().current_scene
	var shell := MeshInstance3D.new()
	var cyl   := CylinderMesh.new()
	cyl.top_radius = 0.01; cyl.bottom_radius = 0.01; cyl.height = 0.04
	shell.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.62, 0.18)
	mat.metallic     = 0.9
	mat.roughness    = 0.2
	shell.material_override = mat
	root.add_child(shell)
	shell.global_position = pos
	var vel  := right * randf_range(1.5, 3.0) + Vector3(0, randf_range(0.5, 1.5), 0)
	var life := randf_range(1.0, 2.5)
	var tw   := shell.create_tween().set_parallel(true)
	tw.tween_property(shell, "global_position", shell.global_position + vel * life, life)
	tw.tween_property(shell, "rotation_degrees:z", randf_range(180.0, 720.0), life)
	tw.chain().tween_callback(shell.queue_free)


# ── Explosion ─────────────────────────────────────────────────
func spawn_explosion(pos: Vector3, radius: float = 3.0) -> void:
	var root := get_tree().current_scene

	# Central flash
	var flash := MeshInstance3D.new()
	var fsm   := SphereMesh.new(); fsm.radius = radius * 0.4
	flash.mesh = fsm
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.albedo_color               = Color(1.0, 0.9, 0.6, 1.0)
	fmat.emission_enabled           = true
	fmat.emission                   = Color(1.0, 0.8, 0.3)
	fmat.emission_energy_multiplier = 10.0
	flash.material_override = fmat
	root.add_child(flash)
	flash.global_position = pos
	var ftw := flash.create_tween().set_parallel(true)
	ftw.tween_property(flash, "scale", Vector3(radius, radius, radius) * 0.8, 0.15)
	ftw.tween_method(
		func(a: float): if is_instance_valid(fmat): fmat.albedo_color.a = a,
		1.0, 0.0, 0.2)
	ftw.chain().tween_callback(flash.queue_free)

	# Debris chunks
	for _i in randi_range(8, 14):
		var d    := MeshInstance3D.new()
		var dm   := BoxMesh.new()
		dm.size  = Vector3.ONE * randf_range(0.08, 0.25)
		d.mesh   = dm
		var dmat := StandardMaterial3D.new()
		dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		dmat.albedo_color = Color(randf_range(0.2,0.4), randf_range(0.15,0.3), 0.1, 1.0)
		d.material_override = dmat
		root.add_child(d)
		d.global_position = pos
		var dvel  := Vector3(randf_range(-1,1), randf_range(0.5,2), randf_range(-1,1)).normalized() \
					* randf_range(2.0, radius * 2.0)
		var dlife := randf_range(0.6, 1.4)
		var dtw   := d.create_tween().set_parallel(true)
		dtw.tween_property(d, "global_position", d.global_position + dvel * dlife, dlife)
		dtw.tween_property(d, "rotation_degrees:y", randf_range(180.0, 540.0), dlife)
		dtw.tween_method(
			func(a: float): if is_instance_valid(dmat): dmat.albedo_color.a = a,
			1.0, 0.0, dlife * 0.4)
		dtw.chain().tween_callback(d.queue_free)

	# Shockwave ring
	var ring := MeshInstance3D.new()
	var tm   := TorusMesh.new()
	tm.inner_radius = 0.0; tm.outer_radius = 0.1
	tm.rings = 24; tm.ring_segments = 8
	ring.mesh = tm
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.albedo_color = Color(1.0, 0.7, 0.3, 0.6)
	ring.material_override = rmat
	root.add_child(ring)
	ring.global_position = pos + Vector3(0, 0.1, 0)
	var rtw := ring.create_tween().set_parallel(true)
	rtw.tween_property(ring, "scale", Vector3(radius*2, 1, radius*2), 0.35)
	rtw.tween_method(
		func(a: float): if is_instance_valid(rmat): rmat.albedo_color.a = a,
		0.6, 0.0, 0.35)
	rtw.chain().tween_callback(ring.queue_free)
