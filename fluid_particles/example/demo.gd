extends Spatial
# Builds a tiny test scene in code: floor, sky, light, camera and a squirting emitter.
#   Space / Enter ... fire again
#   1-9, 0, Q, W, E, R, T ... stream presets (Squirt ... Long Goo Line)
#   M ............... cycle the emitter look (Clear Water, Milky, Milky Rope, Syrup, Slime)
#   B ............... toggle blended surface / plain balls

const STREAM_SCRIPT = preload("res://addons/fluid_particles/fluid_stream.gd")
const EMITTER_SCRIPT = preload("res://addons/fluid_particles/fluid_emitter.gd")

var emitter
var stream
var label
var stream_names = []
var emitter_names = []
var look = 7   # start on "Milky Rope"


func _ready():
	stream_names = STREAM_SCRIPT.PRESET_NAMES.split(",")
	emitter_names = EMITTER_SCRIPT.PRESET_NAMES.split(",")

	# A sky gives the glossy fluid something to reflect.
	var env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.background_sky = ProceduralSky.new()
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.9

	var cam = Camera.new()
	cam.environment = env
	add_child(cam)
	cam.look_at_from_position(Vector3(0, 1.3, 4.0), Vector3(0.3, 0.6, 0), Vector3.UP)

	var light = DirectionalLight.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	add_child(light)

	var floor_mesh = MeshInstance.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(30, 30)
	floor_mesh.mesh = plane
	var fm = SpatialMaterial.new()
	fm.albedo_color = Color(0.22, 0.24, 0.28)
	fm.roughness = 0.9
	floor_mesh.material_override = fm
	add_child(floor_mesh)

	# A wall to stick to (goo presets stick to physics bodies).
	var wall = StaticBody.new()
	wall.translation = Vector3(1.2, 1.0, 0.0)
	var wcs = CollisionShape.new()
	var wbox = BoxShape.new()
	wbox.extents = Vector3(0.05, 1.0, 1.5)
	wcs.shape = wbox
	wall.add_child(wcs)
	var wmesh = MeshInstance.new()
	var wcube = CubeMesh.new()
	wcube.size = Vector3(0.1, 2.0, 3.0)
	wmesh.mesh = wcube
	wmesh.material_override = fm
	wall.add_child(wmesh)
	add_child(wall)

	# Add the stream to the emitter BEFORE the emitter enters the tree,
	# so it is picked up when the emitter starts.
	emitter = EMITTER_SCRIPT.new()
	emitter.floor_enabled = true
	emitter.floor_height = 0.0
	emitter.translation = Vector3(-1.5, 0.8, 0.0)
	emitter.set("preset", look)

	stream = STREAM_SCRIPT.new()
	stream.rotation_degrees = Vector3(15, -90, 0)   # forward (-Z) points along +X, tilted up
	stream.set("preset", 5)                          # "Line Squirt"
	emitter.add_child(stream)

	add_child(emitter)

	var layer = CanvasLayer.new()
	label = Label.new()
	label.rect_position = Vector2(16, 12)
	layer.add_child(label)
	add_child(layer)
	_update_label(5)


func _update_label(stream_preset):
	label.text = "Stream: %s    Look: %s\nSpace: fire   1-9/0/Q/W/E/R/T: stream preset   M: look   B: surface on/off" % [
		stream_names[stream_preset], emitter_names[look]]


func _unhandled_input(event):
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var preset = -1
	match event.scancode:
		KEY_1: preset = 1
		KEY_2: preset = 2
		KEY_3: preset = 3
		KEY_4: preset = 4
		KEY_5: preset = 5
		KEY_6: preset = 6
		KEY_7: preset = 7
		KEY_8: preset = 8
		KEY_9: preset = 9
		KEY_0: preset = 10
		KEY_Q: preset = 11
		KEY_W: preset = 12
		KEY_E: preset = 13
		KEY_R: preset = 14
		KEY_T: preset = 15
	if preset > 0:
		stream.set("preset", preset)
		_update_label(preset)
		emitter.restart()
	elif event.scancode == KEY_M:
		look = look + 1
		if look >= emitter_names.size():
			look = 5
		emitter.set("preset", look)
		_update_label(stream._preset_shown)
		emitter.restart()
	elif event.scancode == KEY_B:
		emitter.fluid_surface = not emitter.fluid_surface
		emitter.restart()
	elif event.scancode == KEY_SPACE or event.scancode == KEY_ENTER:
		emitter.restart()
