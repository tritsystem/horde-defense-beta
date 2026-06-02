extends Label

func _ready():
	position = Vector2(10, 10)
	text = "SCRIPT IS RUNNING"  # Test text
	print("FPS counter script started!")  # Check console

func _process(delta):
	var fps = Engine.get_frames_per_second()
	text = "FPS: " + str(fps)
