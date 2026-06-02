extends Node

const CELL_SIZE: float = 6.0

var grid: Dictionary = {}

func clear() -> void:
	grid.clear()

func insert(i: int, p: Vector3) -> void:
	var cell: Vector2i = Vector2i(
		int(p.x / CELL_SIZE),
		int(p.z / CELL_SIZE)
	)

	if not grid.has(cell):
		grid[cell] = []

	grid[cell].append(i)

func get_nearby(p: Vector3) -> Array:
	var cell: Vector2i = Vector2i(
		int(p.x / CELL_SIZE),
		int(p.z / CELL_SIZE)
	)

	var result: Array = []

	for x: int in [-1, 0, 1]:
		for y: int in [-1, 0, 1]:
			var c: Vector2i = Vector2i(cell.x + x, cell.y + y)

			if grid.has(c):
				result += grid[c]

	return result
