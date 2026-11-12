tool
extends EditorPlugin


func _enter_tree():
	add_custom_type("FluidEmitter", "Spatial",
		preload("res://addons/fluid_particles/fluid_emitter.gd"),
		preload("res://addons/fluid_particles/icons/fluid_emitter.png"))
	add_custom_type("FluidStream", "Spatial",
		preload("res://addons/fluid_particles/fluid_stream.gd"),
		preload("res://addons/fluid_particles/icons/fluid_stream.png"))


func _exit_tree():
	remove_custom_type("FluidEmitter")
	remove_custom_type("FluidStream")
