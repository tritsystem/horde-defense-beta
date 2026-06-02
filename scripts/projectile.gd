# BasicProjectile.gd — fast hitscan-style visible bullet for topdown
extends Node3D

@export var speed    : float = 120.0
@export var damage   : float = 25.0
@export var lifetime : float = 1.5
@export var color    : Color = Color(1.0, 0.9, 0.3)

var velocity : Vector3 = Vector3.ZERO
var shooter  : Node    = null
var _dead    : bool    = false
var _mesh    : MeshInstance3D

func init(origin: Vector3, dir: Vector3, p_shooter: Node, dmg: float = -1.0) -> void:
	shooter = p_shooter
	if dmg > 0.0: damage = dmg
	global_position = origin
	velocity = dir.normalized() * speed
	if is_inside_tree(): _start()
	else: set_meta("_pending_init", true)

func _ready() -> void:
	_build_mesh()
	if has_meta("_pending_init"):
		remove_meta("_pending_init")
		_start()

func _start() -> void:
	get_tree().create_timer(lifetime).timeout.connect(func(): if not _dead: _die(), CONNECT_ONE_SHOT)
	set_physics_process(true)

func _build_mesh() -> void:
	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04; cyl.bottom_radius = 0.04; cyl.height = 0.35
	_mesh.mesh = cyl; _mesh.rotation_degrees.x = 90.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color; mat.emission_enabled = true
	mat.emission = color; mat.emission_energy_multiplier = 6.0
	_mesh.material_override = mat; add_child(_mesh)

func _physics_process(delta: float) -> void:
	if _dead: return
	var from := global_position
	global_position += velocity * delta
	# Orient along velocity
	if velocity.length_squared() > 0.01:
		var up := Vector3.UP if abs(velocity.normalized().dot(Vector3.UP)) < 0.95 else Vector3.FORWARD
		look_at(global_position + velocity.normalized(), up)
	_check_hit(from, global_position)

func _check_hit(from: Vector3, to: Vector3) -> void:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 0xFFFFFFFF
	if is_instance_valid(shooter):
		var rids : Array[RID] = []
		var n := shooter
		while is_instance_valid(n):
			if n is CollisionObject3D: rids.append((n as CollisionObject3D).get_rid())
			n = n.get_parent()
		if not rids.is_empty(): q.exclude = rids
	var hit := space.intersect_ray(q)
	if hit.is_empty(): return
	var target := _resolve(hit.collider)
	if not is_instance_valid(target): _die(); return
	if _is_friendly(target): _die(); return
	var dmg := damage
	if is_instance_valid(shooter) and shooter.has_method("get_damage_multiplier"):
		dmg *= shooter.get_damage_multiplier()
	var is_hs : bool = target is Node3D and hit.position.y >= (target as Node3D).global_position.y + 1.25
	if is_hs: dmg *= 2.0
	target.take_damage(dmg, shooter)
	for h in get_tree().get_nodes_in_group("hud"):
		if h.has_method("show_hitmarker"): h.show_hitmarker(is_hs); break
	var _etp3 : int = int(shooter.get("enchantment")) if is_instance_valid(shooter) and "enchantment" in shooter else 0
	var _dn := get_tree().get_first_node_in_group("damage_numbers")
	if is_instance_valid(_dn) and _dn.has_method("spawn_number"):
		_dn.spawn_number(dmg, (target as Node3D).global_position + Vector3(0,1.8,0), _etp3, is_hs)
	_die()

func _resolve(node: Node) -> Node:
	var cur := node
	while is_instance_valid(cur):
		if cur.has_method("take_damage"): return cur
		cur = cur.get_parent()
	return null

func _is_friendly(target: Node) -> bool:
	if not is_instance_valid(shooter): return false
	var st := _tid(shooter); var tt := _tid(target)
	return st != -1 and tt != -1 and st == tt

func _tid(n: Node) -> int:
	var cur := n
	while is_instance_valid(cur):
		if "team_id" in cur: return int(cur.get("team_id"))
		cur = cur.get_parent()
	return -1

func _die() -> void:
	if _dead: return
	_dead = true; set_physics_process(false); queue_free()
