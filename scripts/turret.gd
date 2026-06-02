# ============================================================
# turret.gd — Full Rework
# ============================================================
extends BaseTurret

@export_group("Combat")
@export var range            : float = 18.0
@export var fire_rate        : float = 1.0
@export var base_damage      : float = 20.0
@export var projectile_scene : PackedScene
@export var targeting_mode   : String = "closest"

@export_group("Burst")
@export var burst_count : int   = 1
@export var burst_delay : float = 0.08

@export_group("Rotation")
@export var rotation_speed : float = 6.0

@export_group("Economy")
@export var repair_cost : int = 40

@export_group("UI")
@export var ui_height : float = 3.0

@export_group("Muzzle")
@export var muzzle_local_offset : Vector3 = Vector3(0.0, 0.5, -1.2)
# ↑ Tweak this in Inspector: x=left/right, y=up/down, z=forward (negative = barrel tip)

var damage               : float  = 0.0
var target               : Node3D = null
var fire_timer           : float  = 0.0
var burst_timer          : float  = 0.0
var burst_shots_left     : int    = 0
var target_refresh_timer : float  = 0.0
var selected             : bool   = false

# Muzzle — found in scene or auto-created
var _muzzle     : Node3D = null
var _range_mesh : Node3D = null


# ============================================================
# READY
# ============================================================
func _ready() -> void:
	_base_ready()
	damage     = base_damage
	fire_timer = 0.0

	# Find or create muzzle
	_muzzle = get_node_or_null("Muzzle")
	if not is_instance_valid(_muzzle):
		_muzzle = _find_muzzle_in_children()
	if not is_instance_valid(_muzzle):
		_muzzle = _auto_create_muzzle()

	_range_mesh = get_node_or_null("RangeMesh")
	if is_instance_valid(_range_mesh):
		_range_mesh.visible = false

	print("[Turret] ready | team=%d muzzle=%s offset=%s" % [
		team_id,
		_muzzle.get_path() if is_instance_valid(_muzzle) else "NULL",
		str(muzzle_local_offset)])


func _find_muzzle_in_children() -> Node3D:
	# Look for any child named Muzzle, muzzle, MuzzlePoint, FirePoint etc.
	for name in ["Muzzle", "muzzle", "MuzzlePoint", "FirePoint", "Barrel", "BarrelTip"]:
		var n := get_node_or_null(name)
		if is_instance_valid(n) and n is Node3D: return n as Node3D
	# Deep search
	for child in find_children("*", "Node3D", true, false):
		var cn := child.name.to_lower()
		if "muzzle" in cn or "barrel" in cn or "fire" in cn:
			return child as Node3D
	return null


func _auto_create_muzzle() -> Node3D:
	# Create a marker at the export offset — visible in editor as a small sphere
	var marker := Node3D.new()
	marker.name = "Muzzle"
	marker.position = muzzle_local_offset
	add_child(marker)

	# Debug visual so you can see where shots originate in editor
	var dbg := MeshInstance3D.new()
	dbg.name = "MuzzleDebug"
	var sphere := SphereMesh.new()
	sphere.radius = 0.06; sphere.height = 0.12
	dbg.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.5, 0.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.0)
	mat.emission_energy_multiplier = 2.0
	dbg.material_override = mat
	marker.add_child(dbg)

	print("[Turret] Auto-created Muzzle at local offset: ", muzzle_local_offset)
	return marker


# ============================================================
# PROCESS
# ============================================================
func _process(delta: float) -> void:
	_handle_targeting(delta)
	_handle_rotation(delta)
	_handle_shooting(delta)
	_handle_hotkeys()


# ============================================================
# TARGETING
# ============================================================
func _handle_targeting(delta: float) -> void:
	target_refresh_timer -= delta
	if target_refresh_timer > 0.0: return
	target_refresh_timer = 0.2
	target = _find_target()

func _find_target() -> Node3D:
	var best   : Node3D = null
	var best_d : float  = range
	var candidates : Array = []
	candidates.append_array(get_tree().get_nodes_in_group("units"))
	candidates.append_array(get_tree().get_nodes_in_group("minions"))
	candidates.append_array(get_tree().get_nodes_in_group("zombies"))
	for unit in candidates:
		if not is_instance_valid(unit) or unit == self: continue
		if not (unit is Node3D): continue
		if unit.is_in_group("bases") or unit.is_in_group("towers"): continue
		if not ("team_id" in unit) or int(unit.get("team_id")) == team_id: continue
		if unit.has_method("is_dead") and unit.is_dead(): continue
		var d := global_position.distance_to(unit.global_position)
		if d >= best_d: continue
		if not _has_los(unit as Node3D): continue
		best_d = d; best = unit
	return best

func _has_los(tgt: Node3D) -> bool:
	if not is_instance_valid(tgt): return false
	var space := get_world_3d().direct_space_state
	if not is_instance_valid(space): return true
	var from  := global_position + Vector3(0, 0.5, 0)
	var to    := tgt.global_position + Vector3(0, 0.8, 0)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 0b00000001
	var excl : Array[RID] = []
	if tgt is CollisionObject3D: excl.append((tgt as CollisionObject3D).get_rid())
	query.exclude = excl
	return space.intersect_ray(query).is_empty()


# ============================================================
# ROTATION — turret body aims at target
# ============================================================
func _handle_rotation(delta: float) -> void:
	if not is_instance_valid(target): return
	# Flatten to XZ — turret rotates around Y only
	var tpos := target.global_position
	tpos.y   = global_position.y
	var desired : Vector3 = (tpos - global_position).normalized()
	if desired.length_squared() < 0.001: return
	var current : Vector3 = -global_transform.basis.z
	var new_dir  : Vector3 = current.slerp(desired, rotation_speed * delta)
	if new_dir.length_squared() > 0.001:
		look_at(global_position + new_dir, Vector3.UP)


# ============================================================
# SHOOTING
# ============================================================
func _handle_shooting(delta: float) -> void:
	if not is_instance_valid(target): return
	fire_timer -= delta
	if fire_timer <= 0.0 and burst_shots_left <= 0:
		burst_shots_left = burst_count
		burst_timer      = 0.0
		fire_timer       = fire_rate
	if burst_shots_left > 0:
		burst_timer -= delta
		if burst_timer <= 0.0:
			_fire_projectile()
			burst_shots_left -= 1
			burst_timer       = burst_delay

func _fire_projectile() -> void:
	if not is_instance_valid(target): return
	var tgt := target

	# ── Direct damage (reliable) ─────────────────────────────
	if tgt.has_method("take_damage"):
		if int(tgt.get("team_id") if "team_id" in tgt else -1) != team_id:
			tgt.take_damage(damage, self)
			var dn := get_tree().get_first_node_in_group("damage_numbers")
			if is_instance_valid(dn) and dn.has_method("spawn_number"):
				dn.spawn_number(damage, tgt.global_position + Vector3.UP * 1.8, 0, false)

	# ── Cosmetic projectile ───────────────────────────────────
	if not is_instance_valid(projectile_scene): return
	var p := projectile_scene.instantiate()
	get_tree().current_scene.add_child(p)

	# Spawn at muzzle world position
	var spawn_pos : Vector3
	if is_instance_valid(_muzzle):
		spawn_pos = _muzzle.global_position
	else:
		spawn_pos = global_transform * muzzle_local_offset

	p.global_position = spawn_pos

	# Aim from muzzle toward target center of mass
	var aim_target : Vector3 = tgt.global_position + Vector3(0, 0.8, 0)
	var dir : Vector3 = (aim_target - spawn_pos).normalized()

	# Init projectile — supports several common APIs
	if   p.has_method("init"):    p.init(spawn_pos, dir, self, 0.0)
	elif "velocity"   in p:       p.set("velocity",  dir * 30.0)
	elif "direction"  in p:       p.set("direction", dir)
	if "team_id" in p: p.set("team_id", team_id)


# ============================================================
# GOLD
# ============================================================
func _get_gold() -> int:
	var gm := get_tree().get_first_node_in_group("game_manager")
	return gm.get_gold(team_id) if is_instance_valid(gm) and gm.has_method("get_gold") else 0

func _spend_gold(amount: int) -> bool:
	var gm := get_tree().get_first_node_in_group("game_manager")
	if is_instance_valid(gm) and gm.has_method("spend_gold"):
		return gm.spend_gold(team_id, amount)
	return false


# ============================================================
# UPGRADE / REPAIR
# ============================================================
func upgrade() -> bool:
	if level >= max_level: return false
	var cost := get_upgrade_cost()
	if not _spend_gold(cost): return false
	level    += 1
	damage    = base_damage * _dmg_scale()
	fire_rate = maxf(0.12, fire_rate * 0.9)
	range    += _range_bonus()
	var old_max := max_health
	max_health  *= _health_scale()
	health      *= max_health / old_max
	armor        = (level - 1) * 3.0
	health_changed.emit(health, max_health)
	turret_upgraded.emit(self)
	return true

func repair() -> bool:
	if health >= max_health: return false
	if not _spend_gold(repair_cost): return false
	health = max_health
	health_changed.emit(health, max_health)
	return true

func get_upgrade_cost() -> int: return int(50 * pow(level, 1.5))
func get_cost()         -> int: return get_upgrade_cost()


# ============================================================
# INTERACTION / SELECTION
# ============================================================
func interact() -> void:
	turret_selected.emit(self)
	set_selected(true)

func set_selected(v: bool) -> void:
	selected = v
	if is_instance_valid(_range_mesh): _range_mesh.visible = v

func _handle_hotkeys() -> void:
	if not selected: return
	if InputMap.has_action("upgrade_turret") and Input.is_action_just_pressed("upgrade_turret"):
		upgrade()
	if InputMap.has_action("repair_turret")  and Input.is_action_just_pressed("repair_turret"):
		repair()

func get_ui_world_position() -> Vector3:
	return global_position + Vector3.UP * ui_height
