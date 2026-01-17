extends Node2D

const CAMPAIGN_DATA_PATH = "res://campaign_data/campaign.json"
const CAMPAIGN_DATA_WEB_URL = "campaign_data/campaign.json"
const MARKER_SIZE = 64  # Marker size in world pixels

# Zoom settings
const MIN_ZOOM = 0.1  # Zoomed out (see more map)
const MAX_ZOOM = 2.0  # Zoomed in (see detail)
const ZOOM_SPEED = 0.1
const PAN_SPEED = 1.0

@onready var map_sprite: Sprite2D = $Map
@onready var team_marker: Sprite2D = $TeamMarker
@onready var camera: Camera2D = $Camera2D

var campaign_data: Dictionary = {}
var map_size: Vector2 = Vector2.ZERO
var http_request: HTTPRequest

# Touch gesture tracking
var touch_points: Dictionary = {}
var last_pinch_distance: float = 0.0
var is_panning: bool = false
var pan_start_pos: Vector2 = Vector2.ZERO


func _ready() -> void:
	_setup_camera()
	_load_campaign_data()


func _setup_camera() -> void:
	if map_sprite.texture == null:
		return

	map_size = map_sprite.texture.get_size()

	# Calculate initial zoom to fit map in viewport
	var viewport_size = get_viewport().get_visible_rect().size
	var zoom_to_fit_x = viewport_size.x / map_size.x
	var zoom_to_fit_y = viewport_size.y / map_size.y
	var initial_zoom = min(zoom_to_fit_x, zoom_to_fit_y)

	# Clamp to our zoom limits
	initial_zoom = clamp(initial_zoom, MIN_ZOOM, MAX_ZOOM)

	camera.zoom = Vector2(initial_zoom, initial_zoom)

	# Center camera on map
	camera.position = map_size / 2.0
	camera.make_current()


func _input(event: InputEvent) -> void:
	# Mouse wheel zoom
	if event is InputEventMouseButton:
		var mouse_event = event as InputEventMouseButton
		if mouse_event.pressed:
			if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom_at_point(get_global_mouse_position(), ZOOM_SPEED)
			elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_at_point(get_global_mouse_position(), -ZOOM_SPEED)
			elif mouse_event.button_index == MOUSE_BUTTON_LEFT:
				is_panning = true
				pan_start_pos = get_global_mouse_position()
		else:
			if mouse_event.button_index == MOUSE_BUTTON_LEFT:
				is_panning = false

	# Mouse drag pan
	if event is InputEventMouseMotion and is_panning:
		var current_pos = get_global_mouse_position()
		var delta = pan_start_pos - current_pos
		camera.position += delta
		_clamp_camera_position()

	# Touch events for mobile
	if event is InputEventScreenTouch:
		var touch_event = event as InputEventScreenTouch
		if touch_event.pressed:
			touch_points[touch_event.index] = touch_event.position
			if touch_points.size() == 2:
				last_pinch_distance = _get_pinch_distance()
		else:
			touch_points.erase(touch_event.index)
			last_pinch_distance = 0.0

	if event is InputEventScreenDrag:
		var drag_event = event as InputEventScreenDrag
		touch_points[drag_event.index] = drag_event.position

		if touch_points.size() == 1:
			# Single finger pan
			var delta = drag_event.relative / camera.zoom.x
			camera.position -= delta
			_clamp_camera_position()
		elif touch_points.size() == 2:
			# Pinch zoom
			var current_distance = _get_pinch_distance()
			if last_pinch_distance > 0:
				var zoom_delta = (current_distance - last_pinch_distance) * 0.005
				var pinch_center = _get_pinch_center()
				var world_pinch_center = _screen_to_world(pinch_center)
				_zoom_at_point(world_pinch_center, zoom_delta)
			last_pinch_distance = current_distance


func _get_pinch_distance() -> float:
	if touch_points.size() < 2:
		return 0.0
	var points = touch_points.values()
	return points[0].distance_to(points[1])


func _get_pinch_center() -> Vector2:
	if touch_points.size() < 2:
		return Vector2.ZERO
	var points = touch_points.values()
	return (points[0] + points[1]) / 2.0


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	var viewport = get_viewport()
	var viewport_size = viewport.get_visible_rect().size
	var camera_center = camera.position
	var offset_from_center = (screen_pos - viewport_size / 2.0) / camera.zoom.x
	return camera_center + offset_from_center


func _zoom_at_point(world_point: Vector2, zoom_delta: float) -> void:
	var old_zoom = camera.zoom.x
	var new_zoom = clamp(old_zoom + zoom_delta, MIN_ZOOM, MAX_ZOOM)

	if new_zoom == old_zoom:
		return

	# Calculate the position offset needed to zoom toward the point
	var zoom_ratio = new_zoom / old_zoom
	var offset = world_point - camera.position
	camera.position = world_point - offset * zoom_ratio
	camera.zoom = Vector2(new_zoom, new_zoom)

	_clamp_camera_position()


func _clamp_camera_position() -> void:
	if map_size == Vector2.ZERO:
		return

	var viewport_size = get_viewport().get_visible_rect().size
	var visible_area = viewport_size / camera.zoom.x

	# Allow some margin beyond map edges
	var margin = visible_area * 0.1

	var min_pos = -margin
	var max_pos = map_size + margin

	# If visible area is larger than map, center it
	if visible_area.x >= map_size.x:
		camera.position.x = map_size.x / 2.0
	else:
		camera.position.x = clamp(camera.position.x, visible_area.x / 2.0 + min_pos.x, max_pos.x - visible_area.x / 2.0)

	if visible_area.y >= map_size.y:
		camera.position.y = map_size.y / 2.0
	else:
		camera.position.y = clamp(camera.position.y, visible_area.y / 2.0 + min_pos.y, max_pos.y - visible_area.y / 2.0)


func _load_campaign_data() -> void:
	if OS.has_feature("web"):
		_load_campaign_data_web()
	else:
		_load_campaign_data_local()
		_update_marker_positions()


func _load_campaign_data_web() -> void:
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_web_request_completed)

	var error = http_request.request(CAMPAIGN_DATA_WEB_URL)
	if error != OK:
		push_error("Failed to start HTTP request: " + str(error))
		_use_default_data()
		_update_marker_positions()


func _on_web_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	http_request.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("Failed to fetch campaign data (result: %d, code: %d), using defaults" % [result, response_code])
		_use_default_data()
		_update_marker_positions()
		return

	var json_string = body.get_string_from_utf8()
	var json = JSON.new()
	var error = json.parse(json_string)
	if error != OK:
		push_error("Failed to parse campaign data: " + json.get_error_message())
		_use_default_data()
		_update_marker_positions()
		return

	campaign_data = json.data
	_update_marker_positions()


func _load_campaign_data_local() -> void:
	if not FileAccess.file_exists(CAMPAIGN_DATA_PATH):
		push_warning("Campaign data file not found at: " + CAMPAIGN_DATA_PATH)
		_use_default_data()
		return

	var file = FileAccess.open(CAMPAIGN_DATA_PATH, FileAccess.READ)
	var json_string = file.get_as_text()
	file.close()

	var json = JSON.new()
	var error = json.parse(json_string)
	if error != OK:
		push_error("Failed to parse campaign data: " + json.get_error_message())
		_use_default_data()
		return

	campaign_data = json.data


func _use_default_data() -> void:
	campaign_data = {
		"team_position": {"x": 0.42, "y": 0.37}
	}


func _update_marker_positions() -> void:
	if map_sprite.texture == null:
		return

	map_size = map_sprite.texture.get_size()

	var team_pos = campaign_data.get("team_position", {"x": 0.5, "y": 0.5})
	var normalized_pos = Vector2(team_pos.get("x", 0.5), team_pos.get("y", 0.5))

	# Position marker in world coordinates
	team_marker.position = normalized_pos * map_size

	# Scale marker to fixed world size
	if team_marker.texture:
		var marker_texture_size = team_marker.texture.get_size()
		team_marker.scale = Vector2(MARKER_SIZE, MARKER_SIZE) / marker_texture_size


# Utility function to convert pixel position to normalized coordinates
static func pixel_to_normalized(pixel_pos: Vector2, map_size_param: Vector2) -> Vector2:
	return pixel_pos / map_size_param
