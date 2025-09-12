extends EditorContextMenuPlugin


signal debug_requested
signal function_requested
signal examine_requested
signal popup_requested


func _popup_menu(paths: PackedStringArray) -> void:
	popup_requested.emit()
	add_context_menu_item("[Codebot] Debug this", request_debug)
	add_context_menu_item("[Codebot] Make a function here", request_function)
	add_context_menu_item("[Codebot] Examine", request_examine)


func request_debug(args) -> void: debug_requested.emit(args)
func request_function(args) -> void: function_requested.emit(args)
func request_examine(args) -> void: examine_requested.emit(args)
