@tool
extends EditorPlugin

## Editor entry point for dot-log. Registers the router as an inspector type.
##
## No autoload. A process running a server and a client has two routers with different
## targets and different context, and an autoload could hold only one of them.
##
## Only the [Node] is registered. Everything else here is a [Resource] with a
## [code]class_name[/code], which the inspector already offers in any typed slot — a
## custom type would put them in the "create node" dialog, where they do not belong.

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
