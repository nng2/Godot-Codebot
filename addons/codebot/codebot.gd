@tool
extends EditorPlugin
## AI powered coding chatbot assistant



## API URL
const URL := "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

## Codebot conversation
var conversation := []

## Currently open or used scripts
var open_scripts := []

## Dock control scene
var dock : Control

## Input control
var query_input : TextEdit

## Message list
var message_list : VBoxContainer

## Current query text object
var current_query_object : RichTextLabel = null

## HttpRequestor
var requestor := HTTPRequest.new()

## Context menu plugin
var context_plugin : EditorContextMenuPlugin

## Inline prompt input
var inline_prompt = null

## Represents how to handle API responses
## 0 - default. 1 - replace. 2 - append
var response_action := 0

## Emitted when debug/function code has been received
signal code_receieved



func _enter_tree() -> void:
	while EditorInterface.get_script_editor().get_current_editor() == null:
		await get_tree().process_frame
	
	context_plugin = load("res://addons/codebot/editor_context_menu.gd").new()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCRIPT_EDITOR_CODE, context_plugin)
	context_plugin.debug_requested.connect(debug_requested)
	context_plugin.function_requested.connect(function_requested)
	context_plugin.examine_requested.connect(examine_requested)
	
	dock = preload("res://addons/codebot/code_bot.tscn").instantiate()
	query_input = dock.get_node("Codebot/Input")
	message_list = dock.get_node("Codebot/ScrollContainer/Messages")
	dock.get_node("Clear").connect("pressed", clear_conversation)
	dock.gui_input.connect(_input_deselected)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_BR, dock)
	dock.show()
	requestor.request_completed.connect(_request_completed)
	dock.add_child(requestor)
	ProjectSettings.set_setting("Codebot/API/API Key", "")
	ProjectSettings.set_initial_value("Codebot/API/API Key", "")
	ProjectSettings.add_property_info({
		"name": "Codebot/API/API Key",
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_NONE
	})
	
	if FileAccess.file_exists("user://setting.env"):
		ProjectSettings.set_setting("Codebot/API/API Key", FileAccess.get_file_as_string("user://setting.env"))
	
	ProjectSettings.settings_changed.connect(_check_key)
	if ProjectSettings.get_setting("Codebot/API/API Key") != "":
		message_list.get_node("Reply/Message").text = "Hello there!"
	
	EditorInterface.get_script_editor().get_current_editor().get_base_editor().gui_input.connect(free_inline_prompt)
	context_plugin.popup_requested.connect(free_inline_prompt.bind(InputEventMouseButton.new()))
	
	# Load conversation from disc
	if FileAccess.file_exists("res://addons/codebot/convo.dat"):
		conversation = JSON.parse_string(FileAccess.get_file_as_string("res://addons/codebot/convo.dat"))
		for m in conversation:
			var part = m.parts[0]
			if m.role == "user" and len(part.text) <= 300:
				var query_object := preload("res://addons/codebot/query.tscn").instantiate()
				query_object.get_node("Message").text = part.text
				message_list.add_child(query_object)
			elif m.role == "model":
				var reply_object := preload("res://addons/codebot/reply.tscn").instantiate()
				if part.text.left(1) == "{":
					reply_object.get_node("Message").text = JSON.parse_string(part.text).text
				else:
					reply_object.get_node("Message").text = part.text
				message_list.add_child(reply_object)
		for i in range(20):
			await get_tree().process_frame
			dock.get_node("Codebot/ScrollContainer").scroll_vertical = message_list.size.y+16


## Clears the conversation history
func clear_conversation() -> void:
	conversation = []
	for i in range(dock.get_node("Codebot/ScrollContainer/Messages").get_child_count()-1):
		dock.get_node("Codebot/ScrollContainer/Messages").get_child(1+i).queue_free()
	print("[Codebot] Cache cleared!")


## Checks for updated API key
func _check_key() -> void:
	var file = FileAccess.open("user://setting.env", FileAccess.WRITE)
	file.store_string(ProjectSettings.get_setting("Codebot/API/API Key"))
	file.close()
	if ProjectSettings.get_setting("Codebot/API/API Key") != "":
		message_list.get_node("Reply/Message").text = "Hello there!"
	else:
		message_list.get_node("Reply/Message").text = "Set API Key in settings to get started!"


func _exit_tree() -> void:
	remove_control_from_docks(dock)
	remove_context_menu_plugin(context_plugin)
	ProjectSettings.set_setting("Codebot/API/API Key", null)
	free_inline_prompt(InputEventMouseButton.new())


func _input_deselected(event : InputEvent) -> void: if event is InputEventMouseButton: dock.hide(); dock.show()


func _input(event: InputEvent) -> void:
	if Input.is_key_pressed(KEY_ENTER) and query_input.has_focus():
		if Input.is_key_pressed(KEY_SHIFT):
			query_input.text += "\n"
			query_input.set_caret_line(query_input.get_line_count())
		elif query_input.text != "":
			make_query(query_input.text)


func make_query(query : String, add_chat : bool = true) -> void:
	if add_chat:
		var query_object := preload("res://addons/codebot/query.tscn").instantiate()
		query_object.get_node("Message").text = query
		message_list.add_child(query_object)
		response_action = 0
	
	var reply_object := preload("res://addons/codebot/reply.tscn").instantiate()
	current_query_object = reply_object.get_node("Message")
	current_query_object.text = "."
	message_list.add_child(reply_object)
	think()
	
	var edited_script := EditorInterface.get_script_editor().get_current_script()
	var edited_script_name := edited_script.resource_path if edited_script != null else "None"
	open_scripts = []
	for s in EditorInterface.get_script_editor().get_open_scripts():
		open_scripts.append(s)
	var edited_scene_name := EditorInterface.get_edited_scene_root().scene_file_path if EditorInterface.get_edited_scene_root() != null else ""
	var scripts := {}
	var scenes := {}
	for s in EditorInterface.get_open_scenes():
		scenes[s] = FileAccess.get_file_as_string(s)
	for s in open_scripts:
		scripts[s.resource_path] = s.source_code 
	var project_description := JSON.stringify({
		"Project Name": ProjectSettings.get("application/config/name"),
		"Project Description": ProjectSettings.get("application/config/description"),
		"Currently Edited Scene Name": edited_scene_name,
		"Currently Edited Script Name": edited_script_name,
		"Scene Descriptions": scenes,
		"Script Codes": scripts,
		"FileSystem Description": build_file_tree()
	})
	
	conversation.append({
		"role": "user",
		"parts": [{
			"text": query
		}]
	})
	var schema := {
		"type": "OBJECT",
		"description": "An object containing details about the response to a query.",
		"properties": {
			"text": {
				"type": "STRING",
				"description": "The text only portion of the response to the user's query. This will go in a text chat that the user will read so make sure it's concise and to the point."
			},
			"function": {
				"type": "OBJECT",
				"description": "A singular new function requested by the user, if any.",
				"properties": {
					"name": {
						"type": "STRING",
						"description": "The name of the function."
					},
					"code": {
						"type": "STRING",
						"description": "The code of the function requested by the user."
					}
				},
				"required": ["name", "code"]
			},
			"scripts": {
				"type": "ARRAY",
				"description": "A list of new gdscript files requested by the user, if any.",
				"items": {
					"type": "OBJECT",
					"description": "An object containing details about a new gdscript file.",
					"properties": {
						"filepath": {
							"type": "STRING",
							"description": "The filepath to the new gdscript file to be created."
						},
						"source_code": {
							"type": "STRING",
							"description": "The source code of the new gdscript file to be created. Make sure to use the same indentation type as other script files."
						}
					},
					"required": ["filepath", "source_code"]
				}
			},
			"scenes": {
				"type": "ARRAY",
				"description": "A list of NEW tscn scene files requested by the user, if any. If the user requested to modify part of a scene, use the modifications field instead.",
				"items": {
					"type": "OBJECT",
					"description": "An object containing details about a new tscn scene file.",
					"properties": {
						"filepath": {
							"type": "STRING",
							"description": "The filepath to the new tscn scene file to be created."
						},
						"contents": {
							"type": "STRING",
							"description": "The tscn file contents of the new tscn scene file to be created."
						}
					},
					"required": ["filepath", "contents"]
				}
			},
			"modifications": {
				"type": "ARRAY",
				"description": "A list of modifications requested by the user. These are used for setting properties on nodes or creating new nodes if there is not a node at the specified nodepath. If the node referenced doesn't exist, it will be created with the given type (Do NOT attempt to create nodes by modifying the 'children' property of the parent, you MUST create the child node directly). (Moving nodes, changing modulate colors, setting scale, etc.)",
				"items": {
					"type": "OBJECT",
					"description": "An object containing modifications to a singular node in a scene.",
					"properties": {
						"scenepath": {
							"type": "STRING",
							"description": "The path to the tscn scene file in the filesystem the modified node belongs to."
						},
						"nodepath": {
							"type": "STRING",
							"description": "The nodepath to the node to be modified relative to the scene root. If creating a new node this should be the path to the node to be created."
						},
						"nodetype": {
							"type": "STRING",
							"description": "The type of the node modified."
						},
						"properties": {
							"type": "STRING",
							"description": "A JSON.stringified dictionary with {property_name : value} pairs to change, (Format vectors/colors/etc. like so: '(val1, val2, val3...)'). Nodes do NOT have a children property, the can NOT be used for creating new nodes."
						}
					},
					"required": ["scenepath", "nodepath", "nodetype", "properties"]
				}
			},
		},
		"required": ["text"]
	}
	if response_action == 1 or response_action == 2:
		schema = {
			"type": "OBJECT",
			"description": "A reply answering the users query.",
			"properties": {
				"text": {
					"type": "STRING",
					"description": "The text portion of the reply to the user. This should describe the solution but avoid putting large code chunks here"
				},
				"code": {
					"type": "STRING",
					"description": "Drop-in ready code snippet. The user should be able to copy this and paste it in place of the previous code without any issues."
				}
			},
			"required": ["text", "code"]
		}
	if response_action == 3:
		schema = {
			"type": "OBJECT",
			"description": "Your opinion on the submitted code.",
			"properties": {
				"text": {
					"type": "STRING",
					"description": "The text of the response"
				}
			},
			"required": ["text"]
		}
	var contents = conversation.duplicate()
	contents.back().parts[0].text += "\n\nHere are the details about my project: " + project_description
	var data := {
		"system_instruction": {
			"parts": [{
				"text": "
				You are a GDscript expert responding to queries regarding Godot 4.
				Your name is Codebot and your purpose is to help users debug code and solve other challenges that may present themselves during development.
				Look at the currently edited scene/script of the user first if they ask for help as they'll likely be needed help on something they're currently working on.
				The most recent user message will include a JSON object containing details about the user's project, scenes, and scripts. Scenes and scripts are stored in {filename : filecontents} pairs."
			}]
		},
		"contents": contents,
		"generationConfig": {
			"responseMimeType": "application/json",
			"responseSchema": schema,
			"thinkingConfig": {
				"thinkingBudget": -1
			}
		}
	}
	requestor.request(URL, ["x-goog-api-key: " + ProjectSettings.get_setting("Codebot/API/API Key"), "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(data))
	
	query_input.editable = false
	query_input.placeholder_text = "Working..."
	query_input.text = ""
	dock.hide()
	dock.show()
	for i in range(20):
		await get_tree().process_frame
		dock.get_node("Codebot/ScrollContainer").scroll_vertical = message_list.size.y+16


func think() -> void:
	while current_query_object != null:
		current_query_object.text += "."
		if current_query_object.text == "....": current_query_object.text = "."
		await get_tree().create_timer(0.2).timeout


## Recursively builds details about the project file structure
func build_file_tree(path : String = "res://", directory : bool = true) -> Dictionary:
	var children = []
	if directory:
		for c in DirAccess.get_directories_at(path): if c.left(1) != ".":
			if path == "res://": children.append(build_file_tree(path + c))
			else: children.append(build_file_tree(path + "/" + c))
		for c in DirAccess.get_files_at(path):
			if path == "res://": children.append(build_file_tree(path + c, false))
			else: children.append(build_file_tree(path + "/" + c, false))
	
	return {
		"path": path,
		"type": "Directory" if directory else "File",
		"children": children
	}


## Handles a response from Gemini
func _request_completed(_result : int, response_code : int, _headers : PackedStringArray, body : PackedByteArray) -> void:
	query_input.placeholder_text = "What's wrong with this function?"
	var data = JSON.parse_string(body.get_string_from_utf8())
	
	if response_code == 200:
		if data is Dictionary and data.has("candidates"):
			handle_query_response(data, current_query_object)
		else:
			current_query_object.text = "There was a problem trying to answer your query, sorry"
	else:
		current_query_object.text = "Hmmm... I can't seem to reach the internet right now"
		if data is Dictionary and data.has("error"):
			if data.error.has("details") and data.error.details[0].reason == "API_KEY_INVALID":
				current_query_object.text = "Hmmm... Looks like your API key is invalid"
			if data.error.has("code") and int(data.error.code) == 503:
				current_query_object.text = "This model is overloaded. Try again in a bit"
	
	current_query_object.get_node("../AnimationPlayer").play("Slide")
	current_query_object = null
	query_input.editable = true


## This is the main heavy lifter of the bot. Handles responses from Gemini
func handle_query_response(data : Dictionary, reply : RichTextLabel) -> void:
	var response = data.candidates[0].content.parts[0].text
	var response_data
	while response[0] != "{" and len(response) > 2: response = response.substr(1)
	while response[len(response)-1] != "}" and len(response) > 2: response = response.substr(0, len(response)-1)
	response_data = JSON.parse_string(response)
	
	if response_action == 0 and response_data is Dictionary and response_data.has("text"):
		var text = response_data.text
		
		# Handle function suggestion
		if response_data.has("function"):
			var new_function = response_data.function
			var suggestion = preload("res://addons/codebot/code_suggestion.tscn").instantiate()
			message_list.add_child(suggestion)
			if new_function.name.right(2) == "()": suggestion.get_node("Add").text = "Add " + new_function.name
			else: suggestion.get_node("Add").text = "Add " + new_function.name + "()"
			suggestion.get_node("Copy").tooltip_text = new_function.code
			suggestion.get_node("Add").pressed.connect(_add_function.bind(new_function.code))
			suggestion.get_node("Copy").pressed.connect(_copy_function.bind(new_function.code))
		
		# Handle script suggestions
		if response_data.has("scripts"):
			for script in response_data.scripts:
				if FileAccess.file_exists(script.filepath):
					push_error("[Codebot] Tried to create new script, but script already exists!")
				else:
					if script.filepath.left(6) == "res://":
						create_directories(script.filepath)
						var file = FileAccess.open(script.filepath, FileAccess.WRITE)
						if file != null:
							file.store_string(script.source_code)
							file.close()
							EditorInterface.get_resource_filesystem().scan()
							print("[Codebot] I created a new script for you: " + script.filepath)
							EditorInterface.edit_script(load(script.filepath))
						else:
							push_error("[Codebot] Error creating new script!")
		
		# Handle scene suggestions
		if response_data.has("scenes"):
			for new_scene in response_data.scenes:
				if FileAccess.file_exists(new_scene.filepath):
					push_error("[Codebot] Tried to create new scene, but scene already exists!")
				else:
					if new_scene.filepath.left(6) == "res://":
						create_directories(new_scene.filepath)
						build_scene_from_string(new_scene.contents, new_scene.filepath)
		
		# Handle scene modifications / node creations
		if response_data.has("modifications"):
			var scene_path = EditorInterface.get_edited_scene_root().scene_file_path
			#var root = load(scene_path).instantiate()
			var root = EditorInterface.get_edited_scene_root()
			
			for modification in response_data.modifications:
				if modification.scenepath != scene_path: continue
				
				var node_to_modify = null
				if modification.scenepath == modification.nodepath or modification.nodepath == root.name:
					node_to_modify = root
				else:
					if modification.nodepath.left(5) == "root/": modification.nodepath = modification.nodepath.substr(5)
					if modification.nodepath.left(len(root.name)) == root.name: modification.nodepath = modification.nodepath.substr(len(root.name)+1)
					if root.has_node(modification.nodepath):
						node_to_modify = root.get_node(modification.nodepath)
					elif modification.nodepath.split("/")[0] == root.name:
						node_to_modify = root.get_node("/".join(Array(modification.nodepath.split("/")).slice(1)))
				
				if node_to_modify == null:
					# Try to create new node
					var path_to_node = Array(modification.nodepath.split("/"))
					node_to_modify = ClassDB.instantiate(modification.nodetype)
					if node_to_modify == null:
						push_error("[Codebot] Failed to create new node!")
					else:
						node_to_modify.name = path_to_node.back()
						root.get_node("/".join(path_to_node.slice(0, -1))).add_child(node_to_modify)
						node_to_modify.owner = root
						print("[Codebot] New node " + node_to_modify.name + " created!")
						await get_tree().process_frame
				if node_to_modify != null:
					var props = JSON.parse_string(modification.properties)
					if props is Dictionary:
						for key in props:
							var value_type = type_string(typeof(node_to_modify.get(key)))
							if props[key] is String:
								var value = props[key]
								if value.left(1) == "(": value = value_type + value
								var result = str_to_var(value)
								if typeof(result) == typeof(node_to_modify.get(key)):
									node_to_modify.set.call_deferred(key, result)
							elif props[key] is Dictionary:
								var node_prop = node_to_modify.get(key)
								for prop in props[key]:
									node_prop[prop] = props[key][prop]
								node_to_modify.set.call_deferred(key, node_prop)
							else:
								node_to_modify.set.call_deferred(key, props[key])
						print("[Codebot] Modified node " + modification.nodepath + ", in scene " + modification.scenepath)
				else:
					push_error("[Codebot] Failed to modify node " + modification.nodepath + ", in scene " + modification.scenepath)
		
		conversation.append({
			"role": "model",
			"parts": [{
				"text": text
			}]
		})
		
		reply.text = str(text)
		for i in range(20):
			await get_tree().process_frame
			dock.get_node("Codebot/ScrollContainer").scroll_vertical = message_list.size.y+16
	elif response_action == 1 or response_action == 2:
		code_receieved.emit(response_data.code)
		
		conversation.append({
			"role": "model",
			"parts": [{
				"text": response_data.text
			}]
		})
		
		reply.text = response_data.text
		for i in range(20):
			await get_tree().process_frame
			dock.get_node("Codebot/ScrollContainer").scroll_vertical = message_list.size.y+16
	elif response_action == 3 and response_data is Dictionary:
		conversation.append({
			"role": "model",
			"parts": [{
				"text": response_data.text
			}]
		})
		
		reply.text = response_data.text
		for i in range(20):
			await get_tree().process_frame
			dock.get_node("Codebot/ScrollContainer").scroll_vertical = message_list.size.y+16
	else:
		print(response)
		reply.text = "Sorry. I can't seem to help with that right now."
	
	save_convo()


## Creates any required directories for the given file to be created
func create_directories(path : String) -> void:
	if path.left(6) == "res://":
		var scriptpath : Array = Array(path.substr(6).split("/"))
		var fullpath = "res:/"
		for dir in scriptpath: if !dir.contains("."):
			fullpath += "/" + dir
			if !DirAccess.dir_exists_absolute(fullpath):
				DirAccess.make_dir_absolute(fullpath)


## Splits a parenthesisized string into an array of value
func split_string(str : String) -> Array:
	str = str.lstrip("(")
	str = str.rstrip(")")
	return str.split(", ")


## Builds a scene from string contents
func build_scene_from_string(data : String, path : String) -> void:
	var old_scene_data = ""
	if FileAccess.file_exists(path): old_scene_data = FileAccess.get_file_as_string(path) + "\n"
	old_scene_data += data
	old_scene_data = Array(old_scene_data.split("\n\n"))
	for i in range(old_scene_data.size()): old_scene_data[i] = Array(old_scene_data[i].split("\n"))
	
	var new_scene_data : Array = Array(data.replace("	", "").split("\n\n"))
	for i in range(new_scene_data.size()): new_scene_data[i] = Array(new_scene_data[i].split("\n"))
	
	var sub_resources := {}
	var ext_resources := {}
	
	# Create scene
	var new_root = null if !FileAccess.file_exists(path) else load(path).instantiate()
	
	# Gather sub and ext resources
	for instruction_set in old_scene_data:
		var instruction_header = instruction_set[0]
		var parameters := []
		if instruction_set.size() > 1: parameters = instruction_set.slice(1)
		if instruction_header.left(13) == "[sub_resource":
			var details = Array(instruction_header.split(" "))
			var resource_type = details[1]
			var resource_id = details[2]
			
			while len(resource_type) > 1 and resource_type[0] != '"': resource_type = resource_type.substr(1)
			resource_type = resource_type.substr(1)
			while len(resource_type) > 1 and resource_type[len(resource_type)-1] != '"': resource_type = resource_type.substr(0, len(resource_type)-1)
			resource_type = resource_type.substr(0, len(resource_type)-1)
			
			while len(resource_id) > 1 and resource_id[0] != '"': resource_id = resource_id.substr(1)
			resource_id = resource_id.substr(1)
			while len(resource_id) > 1 and resource_id[len(resource_id)-1] != '"': resource_id = resource_id.substr(0, len(resource_id)-1)
			resource_id = resource_id.substr(0, len(resource_id)-1)
			
			# Create resource
			var new_resource = ClassDB.instantiate(resource_type)
			sub_resources[resource_id] = new_resource
			
			# Set resource parameters
			for p in parameters:
				var pair := Array(p.split(" = "))
				if pair.size() == 2:
					var value_type = type_string(typeof(pair[1]))
					if pair[1] is String:
						var value = pair[1]
						if value.left(1) == "(": value = value_type + value
						var result = str_to_var(value)
						new_resource.set(pair[0], result)
					elif pair[1] is Dictionary:
						var node_prop = new_resource.get(pair[0])
						for prop in pair[1]:
							node_prop[prop] = pair[1][prop]
						new_resource.set(pair[0], node_prop)
					else:
						new_resource.set(pair[0], pair[1])
		elif instruction_header.left(13) == "[ext_resource":
			var details = Array(instruction_header.split(" "))
			if details.size() == 5:
				var resource_path = details[3].split('"')[1]
				var resource_id = details[4].split('"')[1]
				ext_resources[resource_id] = resource_path
	
	# Create new nodes
	for instruction_set in new_scene_data:
		while instruction_set[0] == "": instruction_set.remove_at(0)
		var instruction_header = instruction_set[0]
		var parameters := []
		if instruction_set.size() > 1: parameters = instruction_set.slice(1)
		if instruction_header.left(5) == "[node":
			var details = Array(instruction_header.split(" "))
			var node_name = details[1]
			var node_type = details[2]
			var node_parent = ""
			if details.size() >= 4: node_parent = details[3]
			
			while len(node_name) > 1 and node_name[0] != '"': node_name = node_name.substr(1)
			node_name = node_name.substr(1)
			while len(node_name) > 1 and node_name[len(node_name)-1] != '"': node_name = node_name.substr(0, len(node_name)-1)
			node_name = node_name.substr(0, len(node_name)-1)
			
			while len(node_type) > 1 and node_type[0] != '"': node_type = node_type.substr(1)
			node_type = node_type.substr(1)
			while len(node_type) > 1 and node_type[len(node_type)-1] != '"': node_type = node_type.substr(0, len(node_type)-1)
			node_type = node_type.substr(0, len(node_type)-1)
			
			while len(node_parent) > 1 and node_parent[0] != '"': node_parent = node_parent.substr(1)
			node_parent = node_parent.substr(1)
			while len(node_parent) > 1 and node_parent[len(node_parent)-1] != '"': node_parent = node_parent.substr(0, len(node_parent)-1)
			node_parent = node_parent.substr(0, len(node_parent)-1)
			
			# Create node
			var new_node = ClassDB.instantiate(node_type)
			if new_node is Node:
				new_node.name = StringName(node_name)
				if new_root == null: new_root = new_node
				else:
					if !new_root.has_node(node_parent):
						node_parent = new_root.find_child(node_parent)
						if node_parent != null: node_parent = new_root.get_path_to(node_parent)
					if node_parent != null and new_root.has_node(node_parent):
						new_root.get_node(node_parent).add_child(new_node)
						new_node.owner = new_root
						
						# Set node parameters
						for p in parameters:
							var pair := Array(p.split(" = "))
							if pair.size() == 2:
								if len(pair[1]) > 12 and pair[1].left(12) == "SubResource(":
									var target = Array(pair[1].split('"'))
									if target.size() == 3 and sub_resources.has(target[1]):
										new_node.set(pair[0], sub_resources[target[1]])
								elif len(pair[1]) > 12 and pair[1].left(12) == "ExtResource(":
									var target = Array(pair[1].split('"'))
									if target.size() == 3 and ext_resources.has(target[1]):
										new_node.set(pair[0], load(ext_resources[target[1]]))
								else:
									var value_type = type_string(typeof(pair[1]))
									if pair[1] is String:
										var value = pair[1]
										if value.left(1) == "(": value = value_type + value
										var result = str_to_var(value)
										new_node.set(pair[0], result)
									elif pair[1] is Dictionary:
										var node_prop = new_node.get(pair[0])
										for prop in pair[1]:
											node_prop[prop] = pair[1][prop]
										new_node.set(pair[0], node_prop)
									else:
										new_node.set(pair[0], pair[1])
					else: push_error("[Codebot] Error creating new node at " + str(node_parent))
		
	# Pack scene
	if new_root != null:
		var packed_scene := PackedScene.new()
		packed_scene.pack(new_root)
		if FileAccess.file_exists(path):
			ResourceSaver.save(packed_scene, path)
			print("[Codebot] Scene updated!")
			EditorInterface.reload_scene_from_path(path)
		else:
			ResourceSaver.save(packed_scene, path)
			print("[Codebot] I created a new scene for you: " + path)
			EditorInterface.open_scene_from_path(path)


## Copies a suggested function from chat
func _copy_function(function : String) -> void: DisplayServer.clipboard_set(function)


## Adds a suggested function from chat to the currently edited script
func _add_function(function : String) -> void:
	var edited_script := EditorInterface.get_script_editor().get_current_script()
	if edited_script != null:
		var edited_script_name := edited_script.resource_path
		var editor = EditorInterface.get_script_editor().get_current_editor().get_base_editor()
		print("[Codebot] I added a new function to " + edited_script_name + "!")
		edited_script.source_code += "\n\n" + function
		var folds = editor.get_folded_lines()
		var scroll = editor.scroll_vertical
		editor.text += "\n\n" + function
		EditorInterface.get_resource_filesystem().update_file(edited_script_name)
		for l in folds: editor.fold_line(l)
		editor.scroll_vertical = scroll


## Frees any inline prompts
func free_inline_prompt(event : InputEvent) -> void: if event is InputEventMouseButton and inline_prompt != null: inline_prompt.queue_free(); inline_prompt = null


## Handles a debugging request
func debug_requested(args) -> void:
	if inline_prompt != null: inline_prompt.queue_free()
	inline_prompt = load("res://addons/codebot/inline_prompt.tscn").instantiate()
	var editor : CodeEdit = EditorInterface.get_script_editor().get_current_editor().get_base_editor()
	editor.add_child(inline_prompt)
	inline_prompt.get_node("Title/Label").text = "Debug"
	inline_prompt.get_node("Prompt").placeholder_text = "What's wrong with this code?"
	inline_prompt.position = editor.get_caret_draw_pos()
	inline_prompt.get_node("Prompt").grab_focus()
	inline_prompt.get_node("Prompt").text_submitted.connect(debug_request_submitted.bind(editor.get_selected_text()))


## Handles a function creation request
func function_requested(args) -> void:
	if inline_prompt != null: inline_prompt.queue_free()
	inline_prompt = load("res://addons/codebot/inline_prompt.tscn").instantiate()
	var editor : CodeEdit = EditorInterface.get_script_editor().get_current_editor().get_base_editor()
	editor.add_child(inline_prompt)
	inline_prompt.get_node("Title/Label").text = "Create Function"
	inline_prompt.get_node("Prompt").placeholder_text = "What do you need?"
	inline_prompt.position = editor.get_caret_draw_pos()
	inline_prompt.get_node("Prompt").grab_focus()
	inline_prompt.get_node("Prompt").text_submitted.connect(function_request_submitted.bind([editor.get_caret_line(), editor.get_caret_column()]))


## Handles a code examination request
func examine_requested(args) -> void:
	var selection = EditorInterface.get_script_editor().get_current_editor().get_base_editor().get_selected_text()
	if selection != "":
		response_action = 3
		make_query("What do you think about the following code?\n\n" + selection, false)


## Handles implementing a debug request
func debug_request_submitted(request : String, selected_text : String) -> void:
	free_inline_prompt(InputEventMouseButton.new())
	response_action = 1
	make_query("I need help debugging the following code:\n\n'" + selected_text + "'\n\n" + request + " Please return code that I can directly replace the code I'm working with without changing anything else about the script.", false)
	
	var edited_script := EditorInterface.get_script_editor().get_current_script()
	var editor : CodeEdit = EditorInterface.get_script_editor().get_current_editor().get_base_editor()
	var edited_script_name := edited_script.resource_path
	var selection_start_line = editor.get_selection_origin_line()
	
	var suggestion = await code_receieved
	
	if edited_script != null and editor != null and selected_text != "" and editor.text.contains(selected_text):
		var lines_in_suggestion = suggestion.count("\n") # Number of lines in the AI's suggested code
		var folds = editor.get_folded_lines() # List of currently folded lines
		var scroll = editor.scroll_vertical # Current vertical scroll position
		
		editor.text = editor.text.replace(selected_text, suggestion)
		
		print("[Codebot] Script updated!")
		
		edited_script.source_code = editor.text 
		edited_script.reload()
		EditorInterface.get_resource_filesystem().update_file(edited_script_name)
		
		for l in folds:
			if l < selection_start_line:
				editor.fold_line(l)
			else:
				editor.fold_line(l + lines_in_suggestion)
		editor.scroll_vertical = scroll


## Handles implementing a new function request
func function_request_submitted(request : String, selected : Array) -> void:
	free_inline_prompt(InputEventMouseButton.new())
	response_action = 2
	make_query("I need a new GDScript function based on the following description: \"" + request + "\". Please provide only the function code, using existing indentation practices, ready to be inserted into the current script. Do not include any surrounding text or explanation.", false)
	var suggestion = await code_receieved # This will hold the function code from the AI.
	var edited_script := EditorInterface.get_script_editor().get_current_script()
	var editor : CodeEdit = EditorInterface.get_script_editor().get_current_editor().get_base_editor()
	
	if edited_script != null and editor != null:
		var edited_script_name := edited_script.resource_path
		var script_lines = suggestion.count("\n")
		var folds = editor.get_folded_lines()
		var scroll = editor.scroll_vertical
		
		editor.insert_text_at_caret(suggestion)
		print("[Codebot] Inserted new function!")
		edited_script.source_code = editor.text 
		edited_script.reload()
		EditorInterface.get_resource_filesystem().update_file(edited_script_name)
		
		for l in folds: if l < selected[0]:
			editor.fold_line(l)
		else:
			editor.fold_line(l + script_lines)
		editor.scroll_vertical = scroll


## Saves conversation history to disc
func save_convo() -> void:
	while conversation.size() > 50: conversation.remove_at(0)
	var file = FileAccess.open("res://addons/codebot/convo.dat", FileAccess.WRITE)
	file.store_string(JSON.stringify(conversation))
	file.close()
