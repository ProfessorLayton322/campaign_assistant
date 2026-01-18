extends Node2D

const CAMPAIGN_DATA_PATH = "res://campaign_data/campaign.json"
const CAMPAIGN_DATA_WEB_URL = "campaign_data/campaign.json"
const MARKER_SIZE = 64  # Marker size in world pixels

# Zoom settings
const MIN_ZOOM = 0.1  # Zoomed out (see more map)
const MAX_ZOOM = 5.0  # Zoomed in (see detail)
const ZOOM_SPEED = 0.1

# Mobile touch settings
const PINCH_ZOOM_SENSITIVITY = 0.005
const PAN_DEAD_ZONE = 3.0  # Pixels before pan starts
const PINCH_DEAD_ZONE = 5.0  # Pixels before pinch zoom activates

@onready var map_sprite: Sprite2D = $Map
@onready var team_marker: Sprite2D = $TeamMarker
@onready var camera: Camera2D = $Camera2D

var campaign_data: Dictionary = {}
var map_size: Vector2 = Vector2.ZERO
var http_request: HTTPRequest

# Mouse drag tracking
var is_mouse_panning: bool = false
var mouse_pan_start_pos: Vector2 = Vector2.ZERO

# Touch gesture tracking
var touch_points: Dictionary = {}
var initial_pinch_distance: float = 0.0
var last_pinch_distance: float = 0.0
var pinch_zoom_at_start: float = 1.0  # Store zoom level when pinch started

# Gesture state machine
enum GestureState { NONE, PENDING, PANNING, ZOOMING }
var gesture_state: GestureState = GestureState.NONE
var gesture_start_pos: Vector2 = Vector2.ZERO
var accumulated_pan: Vector2 = Vector2.ZERO
var zoom_locked: bool = false  # Prevents zoom changes during gesture transitions
var pinch_needs_processing: bool = false  # Defer pinch to once per frame

# Camera state
var target_camera_pos: Vector2 = Vector2.ZERO
var current_zoom: float = 1.0
var camera_initialized: bool = false
var last_viewport_size: Vector2 = Vector2.ZERO


func _ready() -> void:
	# On web, defer camera setup to ensure viewport is properly sized
	if OS.has_feature("web"):
		# Wait multiple frames for mobile browsers to settle
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame
	_setup_camera()
	_load_campaign_data()

	# Connect to viewport size changes for handling orientation changes
	get_viewport().size_changed.connect(_on_viewport_size_changed)


func _setup_camera() -> void:
	if map_sprite.texture == null:
		return

	map_size = map_sprite.texture.get_size()

	var viewport_size = get_viewport().get_visible_rect().size
	last_viewport_size = viewport_size

	# Calculate zoom to fit map in viewport (cover mode - fill the screen)
	var zoom_to_fit_x = viewport_size.x / map_size.x
	var zoom_to_fit_y = viewport_size.y / map_size.y
	# Use max to cover the screen (no black bars), min to contain (may have bars)
	var initial_zoom = max(zoom_to_fit_x, zoom_to_fit_y)

	# Clamp to our zoom limits
	initial_zoom = clamp(initial_zoom, MIN_ZOOM, MAX_ZOOM)

	current_zoom = initial_zoom
	camera.zoom = Vector2(current_zoom, current_zoom)

	# Center camera on map
	camera.position = map_size / 2.0
	target_camera_pos = camera.position
	camera.make_current()
	camera_initialized = true


func _on_viewport_size_changed() -> void:
	if not camera_initialized or map_size == Vector2.ZERO:
		return

	var new_viewport_size = get_viewport().get_visible_rect().size
	if new_viewport_size == last_viewport_size:
		return

	last_viewport_size = new_viewport_size

	# Keep current zoom but re-clamp camera position
	_clamp_camera_position()


func _process(_delta: float) -> void:
	# Process pinch zoom once per frame (after all touch events have updated positions)
	if pinch_needs_processing and touch_points.size() == 2:
		_handle_pinch_gesture()
		pinch_needs_processing = false


func _input(event: InputEvent) -> void:
	if not camera_initialized:
		return

	# Mouse wheel zoom (desktop)
	if event is InputEventMouseButton:
		var mouse_event = event as InputEventMouseButton
		if mouse_event.pressed:
			if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom_at_point(get_global_mouse_position(), ZOOM_SPEED)
			elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_at_point(get_global_mouse_position(), -ZOOM_SPEED)
			elif mouse_event.button_index == MOUSE_BUTTON_LEFT:
				is_mouse_panning = true
				mouse_pan_start_pos = get_global_mouse_position()
		else:
			if mouse_event.button_index == MOUSE_BUTTON_LEFT:
				is_mouse_panning = false

	# Mouse drag pan (desktop)
	if event is InputEventMouseMotion and is_mouse_panning:
		var current_pos = get_global_mouse_position()
		var delta = mouse_pan_start_pos - current_pos
		camera.position += delta
		target_camera_pos = camera.position
		_clamp_camera_position()

	# Touch events for mobile
	_handle_touch_event(event)


func _handle_touch_event(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch_event = event as InputEventScreenTouch
		if touch_event.pressed:
			_on_touch_pressed(touch_event)
		else:
			_on_touch_released(touch_event)

	elif event is InputEventScreenDrag:
		_on_touch_drag(event as InputEventScreenDrag)


func _on_touch_pressed(touch_event: InputEventScreenTouch) -> void:
	touch_points[touch_event.index] = touch_event.position

	if touch_points.size() == 1:
		# First finger down - prepare for potential pan
		gesture_state = GestureState.PENDING
		gesture_start_pos = touch_event.position
		accumulated_pan = Vector2.ZERO
	elif touch_points.size() == 2:
		# Second finger down - start pinch zoom
		gesture_state = GestureState.PENDING
		initial_pinch_distance = _get_pinch_distance()
		last_pinch_distance = initial_pinch_distance
		pinch_zoom_at_start = current_zoom  # Save zoom when pinch starts
		accumulated_pan = Vector2.ZERO


func _on_touch_released(touch_event: InputEventScreenTouch) -> void:
	touch_points.erase(touch_event.index)

	# Always persist the current zoom state when any finger is released
	var persisted_zoom = camera.zoom.x

	if touch_points.size() == 0:
		# All fingers released - persist the zoom and lock it
		gesture_state = GestureState.NONE
		current_zoom = persisted_zoom
		camera.zoom = Vector2(current_zoom, current_zoom)  # Explicitly reapply zoom
		target_camera_pos = camera.position
		zoom_locked = false  # Unlock after all fingers released
		pinch_needs_processing = false
		_clamp_camera_position()
	elif touch_points.size() == 1:
		# Went from 2 fingers to 1 - lock zoom to prevent any changes during transition
		zoom_locked = true
		current_zoom = persisted_zoom
		camera.zoom = Vector2(current_zoom, current_zoom)  # Explicitly reapply zoom
		gesture_state = GestureState.PENDING
		var remaining_pos = touch_points.values()[0]
		gesture_start_pos = remaining_pos
		accumulated_pan = Vector2.ZERO
		target_camera_pos = camera.position
		pinch_needs_processing = false
		# Use a deferred call to unlock zoom after the current frame
		_unlock_zoom_deferred.call_deferred()

	# Reset pinch tracking
	initial_pinch_distance = 0.0
	last_pinch_distance = 0.0
	pinch_zoom_at_start = current_zoom  # Update baseline for next pinch


func _unlock_zoom_deferred() -> void:
	zoom_locked = false


func _on_touch_drag(drag_event: InputEventScreenDrag) -> void:
	touch_points[drag_event.index] = drag_event.position

	if touch_points.size() == 1:
		_handle_single_touch_drag(drag_event)
	elif touch_points.size() == 2:
		# Mark pinch for deferred processing (once per frame, after all finger positions updated)
		pinch_needs_processing = true


func _handle_single_touch_drag(drag_event: InputEventScreenDrag) -> void:
	accumulated_pan += drag_event.relative

	# Check if we've moved enough to start panning
	if gesture_state == GestureState.PENDING:
		if accumulated_pan.length() > PAN_DEAD_ZONE:
			gesture_state = GestureState.PANNING

	if gesture_state == GestureState.PANNING:
		# Apply pan - divide by zoom since camera.zoom affects world scale
		var delta = drag_event.relative / current_zoom
		camera.position -= delta
		target_camera_pos = camera.position
		_clamp_camera_position()


func _handle_pinch_gesture() -> void:
	# Don't process pinch zoom if zoom is locked during gesture transition
	if zoom_locked:
		return

	var pinch_distance = _get_pinch_distance()
	var pinch_center = _get_pinch_center()

	if pinch_distance <= 0 or initial_pinch_distance <= 0:
		return

	# Check if we should start zooming
	if gesture_state == GestureState.PENDING:
		var distance_change = abs(pinch_distance - initial_pinch_distance)
		if distance_change > PINCH_DEAD_ZONE:
			gesture_state = GestureState.ZOOMING
			last_pinch_distance = pinch_distance
			pinch_zoom_at_start = current_zoom

	if gesture_state == GestureState.ZOOMING:
		# Calculate new zoom based on pinch ratio from start
		var zoom_ratio = pinch_distance / initial_pinch_distance
		var new_zoom = clamp(pinch_zoom_at_start * zoom_ratio, MIN_ZOOM, MAX_ZOOM)

		if abs(new_zoom - current_zoom) > 0.001:
			# Get world position at pinch center before zoom
			var world_pinch_center = _screen_to_world(pinch_center)

			# Calculate position offset to zoom toward pinch center
			var zoom_change = new_zoom / current_zoom
			var offset = world_pinch_center - camera.position
			camera.position = world_pinch_center - offset * zoom_change

			# Apply new zoom
			current_zoom = new_zoom
			camera.zoom = Vector2(current_zoom, current_zoom)
			target_camera_pos = camera.position

			_clamp_camera_position()

		last_pinch_distance = pinch_distance


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
	var offset_from_center = (screen_pos - viewport_size / 2.0) / current_zoom
	return camera_center + offset_from_center


func _zoom_at_point(world_point: Vector2, zoom_delta: float) -> void:
	var new_zoom = clamp(current_zoom + zoom_delta, MIN_ZOOM, MAX_ZOOM)

	if abs(new_zoom - current_zoom) < 0.0001:
		return

	# Calculate the position offset needed to zoom toward the point
	var zoom_ratio = new_zoom / current_zoom
	var offset = world_point - camera.position
	camera.position = world_point - offset * zoom_ratio

	current_zoom = new_zoom
	camera.zoom = Vector2(current_zoom, current_zoom)
	target_camera_pos = camera.position

	_clamp_camera_position()


func _clamp_camera_position() -> void:
	if map_size == Vector2.ZERO or current_zoom <= 0:
		return

	var viewport_size = get_viewport().get_visible_rect().size
	var visible_area = viewport_size / current_zoom

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

	target_camera_pos = camera.position


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
