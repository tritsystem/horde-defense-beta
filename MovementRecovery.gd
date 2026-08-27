class_name MovementRecovery
extends RefCounted

## Shared stuck-detection + nav-checked random-hop recovery. Replaces the
## logic that used to be duplicated near-verbatim in both zombie.gd's
## _unstuck() and team_ally.gd's own copy of the same thing. Holds only its
## own bookkeeping (last position, timers) -- never touches a Node directly,
## so any host (zombie.gd today; team_ally.gd or bosszombie.gd later) just
## applies the returned deltas to its own global_position/velocity.
##
## The host is still responsible for deciding WHEN to call tick() at all --
## e.g. zombie.gd's combat-aware guard ("don't flag deliberately-still melee
## as stuck") skips calling tick() on those frames and calls reset_progress()
## instead, exactly like it skipped the equivalent logic inline before.

const HOP_SPEED         : float = 5.0
const HOP_Y_VELOCITY    : float = 4.0
const NUDGE_DIST        : float = 1.5
const NAV_SNAP_MAX_DIST : float = 1.0
const CHECK_INTERVAL    : float = 0.5

var last_position       : Vector3 = Vector3.ZERO
var last_position_timer : float   = 0.0
var stuck_timer         : float   = 0.0
var _initialized        : bool    = false

## Call every physics frame while the host wants stuck-detection active.
## Returns {fired, teleport_to, velocity_add (Vector2 xz), set_velocity_y
## (float or null)} -- host applies these to its own global_position/velocity
## only when fired == true.
func tick(delta: float, current_pos: Vector3, stuck_distance: float, stuck_time: float,
		world_3d: World3D, is_on_floor: bool) -> Dictionary:

	var result := {"fired": false, "teleport_to": current_pos, "velocity_add": Vector2.ZERO, "set_velocity_y": null}

	if not _initialized:
		last_position = current_pos
		_initialized = true
		return result

	last_position_timer += delta
	if last_position_timer < CHECK_INTERVAL:
		return result
	last_position_timer = 0.0

	var moved : float = Vector2(
		current_pos.x - last_position.x,
		current_pos.z - last_position.z
	).length()
	last_position = current_pos

	if moved < stuck_distance:
		stuck_timer += CHECK_INTERVAL
		if stuck_timer >= stuck_time:
			stuck_timer = 0.0
			return _unstuck(current_pos, world_3d, is_on_floor)
	else:
		stuck_timer = 0.0

	return result

## Host calls this instead of tick() on frames where a stuck check
## shouldn't run at all (e.g. deliberately holding still to melee an
## in-range target) -- keeps progress tracking honest for when it resumes.
func reset_progress(current_pos: Vector3) -> void:
	stuck_timer = 0.0
	last_position = current_pos
	_initialized = true

func _unstuck(current_pos: Vector3, world_3d: World3D, is_on_floor: bool) -> Dictionary:
	var dir := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	if dir.length_squared() <= 0.01:
		dir = Vector3.FORWARD
	dir = dir.normalized()

	var test_pos : Vector3 = current_pos + dir * NUDGE_DIST
	var new_pos : Vector3 = test_pos

	if is_instance_valid(world_3d):
		var nav_map : RID = world_3d.navigation_map
		if nav_map != RID():
			var closest : Vector3 = NavigationServer3D.map_get_closest_point(nav_map, test_pos)
			new_pos = test_pos if closest.distance_to(test_pos) < NAV_SNAP_MAX_DIST else closest

	return {
		"fired": true,
		"teleport_to": new_pos,
		"velocity_add": Vector2(dir.x, dir.z) * HOP_SPEED,
		"set_velocity_y": (HOP_Y_VELOCITY if is_on_floor else null),
	}
