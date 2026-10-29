@tool
extends EditorPlugin

## Editor entry point for dot-log. Registers the router as an inspector type.
## No autoload: a server and a client in one process need two routers. Only the [Node] is registered; Resources already appear in typed slots.

const _ICON := "res://addons/dot_log/icon_placeholder.svg"

const _TYPES := [
	[
		"DotLogRouter",
		"Node",
		"res://addons/dot_log/runtime/dot_log_router.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for entry in _TYPES:
		remove_custom_type(entry[0])
