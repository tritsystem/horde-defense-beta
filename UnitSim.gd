extends Node

# ============================================================
# PURE DATA ARRAYS (NO NODES)
# ============================================================

var pos: PackedVector3Array = []
var vel: PackedVector2Array = []
var hp: PackedFloat32Array = []
var dmg: PackedFloat32Array = []
var team: PackedInt32Array = []

var alive: PackedByteArray = []

var count: int = 0

# ============================================================
# SPAWN UNIT
# ============================================================
func spawn(p_position: Vector3, p_velocity: Vector2, p_team: int, p_hp: float, p_dmg: float) -> int:
	pos.append(p_position)
	vel.append(p_velocity)
	hp.append(p_hp)
	dmg.append(p_dmg)
	team.append(p_team)
	alive.append(1)

	count += 1
	return count - 1

# ============================================================
# KILL UNIT
# ============================================================
func kill(i: int) -> void:
	alive[i] = 0

# ============================================================
# SIMPLE UPDATE HOOK (optional damage / cleanup)
# ============================================================
func is_alive(i: int) -> bool:
	return alive[i] == 1
