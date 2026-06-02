# ============================================================
# BaseLocator.gd — Autoload
# All systems wait for this before doing anything location-based
# Add to Project → Autoloads as "BaseLocator"
# ============================================================
extends Node

signal bases_ready(base1_pos: Vector3, base2_pos: Vector3)

var base1 : Node3D = null
var base2 : Node3D = null
var base1_pos : Vector3 = Vector3.ZERO
var base2_pos : Vector3 = Vector3.ZERO
var is_ready  : bool = false

var _retry_timer : float = 0.0
var _max_wait    : float = 10.0  # give up after 10s


func _ready() -> void:
	add_to_group("base_locator")
	set_process(true)


func _process(delta: float) -> void:
	if is_ready: set_process(false); return
	_retry_timer += delta
	if _retry_timer > _max_wait:
		push_error("[BaseLocator] Could not find both bases after %.1fs" % _max_wait)
		set_process(false); return
	_try_find()


func _try_find() -> void:
	# Try group first
	var bases := get_tree().get_nodes_in_group("bases")
	for b in bases:
		if not is_instance_valid(b) or not (b is Node3D): continue
		var tid : int = int(b.get("team_id") if "team_id" in b else 0)
		if tid == 1: base1 = b as Node3D
		elif tid == 2: base2 = b as Node3D

	# Name fallback
	if not is_instance_valid(base1):
		for n in ["Base", "base", "Base1", "base1", "PlayerBase"]:
			var nd := get_tree().root.find_child(n, true, false)
			if is_instance_valid(nd) and nd is Node3D:
				base1 = nd as Node3D; break

	if not is_instance_valid(base2):
		for n in ["Base 2", "base2", "Base2", "EnemyBase"]:
			var nd := get_tree().root.find_child(n, true, false)
			if is_instance_valid(nd) and nd is Node3D:
				base2 = nd as Node3D; break

	if is_instance_valid(base1) and is_instance_valid(base2):
		base1_pos = base1.global_position
		base2_pos = base2.global_position
		is_ready  = true
		print("[BaseLocator] ✓ Bases found | B1=%s B2=%s" % [
			str(base1_pos.snapped(Vector3.ONE)),
			str(base2_pos.snapped(Vector3.ONE))])
		bases_ready.emit(base1_pos, base2_pos)


# ── Helper used by other systems ─────────────────────────────
func get_midpoint() -> Vector3:
	return (base1_pos + base2_pos) * 0.5

func get_distance() -> float:
	return base1_pos.distance_to(base2_pos)

func get_axis() -> Vector3:
	return (base2_pos - base1_pos).normalized()

func get_spawn_pos(team_id: int, offset: Vector3 = Vector3.ZERO) -> Vector3:
	var base := base1 if team_id == 1 else base2
	if is_instance_valid(base):
		return base.global_position + offset
	return Vector3.ZERO

# Wait for bases if not ready yet — await this
func wait_for_bases() -> void:
	if is_ready: return
	await bases_ready
