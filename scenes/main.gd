extends Node2D

const CAMPAIGN_DATA_PATH = "res://campaign_data/campaign.json"
const CAMPAIGN_DATA_WEB_URL = "campaign_data/campaign.json"
const MARKER_SIZE = 64  # Marker size in world pixels

# Zoom settings
const MIN_ZOOM = 0.1  # Zoomed out (see more map)
const MAX_ZOOM = 5.0  # Zoomed in (see detail)
const ZOOM_SPEED = 0.1

# Mobile touch settings
const PAN_DEAD_ZONE = 3.0  # Pixels before pan starts

# Base zoom for slider calculation (set during camera setup)
var base_zoom: float = 1.0  # The "100%" zoom level

@onready var map_sprite: Sprite2D = $Map
@onready var team_marker: Sprite2D = $TeamMarker
@onready var camera: Camera2D = $Camera2D
@onready var zoom_slider_container: PanelContainer = $UILayer/ZoomSliderContainer
@onready var zoom_slider: VSlider = $UILayer/ZoomSliderContainer/MarginContainer/VBoxContainer/ZoomSlider

# Hex grid reference points
@onready var hex_point_a: Marker2D = $HexPointA
@onready var hex_point_b: Marker2D = $HexPointB
@onready var hex_point_c: Marker2D = $HexPointC
@onready var hex_origin: Marker2D = $HexOrigin

var campaign_data: Dictionary = {}
var map_size: Vector2 = Vector2.ZERO
var http_request: HTTPRequest

# Mouse drag tracking
var is_mouse_panning: bool = false
var mouse_pan_start_pos: Vector2 = Vector2.ZERO

# Touch gesture tracking (pan only on mobile)
var touch_points: Dictionary = {}

# Gesture state machine (simplified - no pinch zoom on mobile)
enum GestureState { NONE, PENDING, PANNING }
var gesture_state: GestureState = GestureState.NONE
var gesture_start_pos: Vector2 = Vector2.ZERO
var accumulated_pan: Vector2 = Vector2.ZERO

# Camera state
var target_camera_pos: Vector2 = Vector2.ZERO
var current_zoom: float = 1.0
var camera_initialized: bool = false
var last_viewport_size: Vector2 = Vector2.ZERO

# Platform detection
var is_mobile: bool = false


func _ready() -> void:
	# Detect if we're on mobile/touch device
	is_mobile = _detect_mobile_device()

	# Configure zoom slider visibility based on platform
	_setup_zoom_slider()

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


func _detect_mobile_device() -> bool:
	# Check for mobile platforms
	if OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios"):
		return true
	# On web, use JavaScript to detect mobile browser
	if OS.has_feature("web"):
		# Use numeric return (1/0) to avoid bool conversion issues with JavaScriptBridge
		var js_result = JavaScriptBridge.eval("window.isMobileDevice ? 1 : 0")
		return js_result == 1
	return false


func _setup_zoom_slider() -> void:
	if is_mobile:
		# Show slider on mobile
		zoom_slider_container.visible = true
		# Connect slider signal
		zoom_slider.value_changed.connect(_on_zoom_slider_changed)
	else:
		# Hide slider on desktop
		zoom_slider_container.visible = false


func _on_zoom_slider_changed(value: float) -> void:
	# Slider value is 100-200, representing percentage
	# 100 = base zoom (100%), 200 = 2x base zoom (200%)
	var zoom_multiplier = value / 100.0
	var new_zoom = clamp(base_zoom * zoom_multiplier, MIN_ZOOM, MAX_ZOOM)

	if abs(new_zoom - current_zoom) > 0.0001:
		# Zoom centered on screen
		var viewport_size = get_viewport().get_visible_rect().size
		var screen_center = viewport_size / 2.0
		var world_center = camera.position

		# Apply new zoom
		current_zoom = new_zoom
		camera.zoom = Vector2(current_zoom, current_zoom)
		target_camera_pos = camera.position
		_clamp_camera_position()


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

	# Store base zoom for slider calculations (100% = initial fit)
	base_zoom = initial_zoom
	current_zoom = initial_zoom
	camera.zoom = Vector2(current_zoom, current_zoom)

	# Center camera on map
	camera.position = map_size / 2.0
	target_camera_pos = camera.position
	camera.make_current()
	camera_initialized = true

	# Reset slider to 100%
	if is_mobile and zoom_slider:
		zoom_slider.set_value_no_signal(100.0)


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
	pass  # No per-frame processing needed


func _input(event: InputEvent) -> void:
	if not camera_initialized:
		return

	# Mouse wheel zoom (desktop only - not on mobile)
	if not is_mobile and event is InputEventMouseButton:
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
	if not is_mobile and event is InputEventMouseMotion and is_mouse_panning:
		var current_pos = get_global_mouse_position()
		var delta = mouse_pan_start_pos - current_pos
		camera.position += delta
		target_camera_pos = camera.position
		_clamp_camera_position()

	# Touch events for mobile
	if is_mobile:
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
	# Note: Multi-touch is ignored - zoom is handled by slider on mobile


func _on_touch_released(touch_event: InputEventScreenTouch) -> void:
	touch_points.erase(touch_event.index)

	if touch_points.size() == 0:
		# All fingers released
		gesture_state = GestureState.NONE
		target_camera_pos = camera.position
		_clamp_camera_position()
	elif touch_points.size() == 1:
		# Went from multi-touch to single touch - restart pan gesture
		gesture_state = GestureState.PENDING
		var remaining_pos = touch_points.values()[0]
		gesture_start_pos = remaining_pos
		accumulated_pan = Vector2.ZERO
		target_camera_pos = camera.position


func _on_touch_drag(drag_event: InputEventScreenDrag) -> void:
	touch_points[drag_event.index] = drag_event.position

	# Only handle single-touch pan - zoom is controlled by slider on mobile
	if touch_points.size() == 1:
		_handle_single_touch_drag(drag_event)


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

	# Add cache-busting query parameter
	var url = CAMPAIGN_DATA_WEB_URL + "?t=" + str(Time.get_unix_time_from_system())
	var error = http_request.request(url)
	if error != OK:
		push_error("Failed to start HTTP request: " + str(error))
		_use_default_data()
		_update_marker_positions()


func _on_web_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	http_request.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("Failed to fetch campaign data (result: %d, code: %d), trying bundled data" % [result, response_code])
		_load_campaign_data_bundled()
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
	# Try to find file relative to executable/project first (allows external editing)
	var external_path = OS.get_executable_path().get_base_dir().path_join("campaign_data/campaign.json")

	# If running in editor, OS.get_executable_path() is the editor executable
	# But in editor, res:// works fine for source editing.
	# This check is primarily for exported builds.
	if FileAccess.file_exists(external_path):
		_load_campaign_data_from_file(external_path)
	else:
		_load_campaign_data_bundled()


func _load_campaign_data_bundled() -> void:
	if FileAccess.file_exists(CAMPAIGN_DATA_PATH):
		_load_campaign_data_from_file(CAMPAIGN_DATA_PATH)
	else:
		push_warning("Bundled campaign data not found")
		_use_default_data()
		_update_marker_positions()


func _load_campaign_data_from_file(path: String) -> void:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Failed to open campaign data file: " + path)
		_use_default_data()
		_update_marker_positions()
		return

	var json_string = file.get_as_text()
	file.close()

	var json = JSON.new()
	var error = json.parse(json_string)
	if error != OK:
		push_error("Failed to parse campaign data: " + json.get_error_message())
		_use_default_data()
		_update_marker_positions()
		return

	campaign_data = json.data
	_update_marker_positions()


func _use_default_data() -> void:
	campaign_data = {
		"team_coordinates": {"x": 0, "y": 0}
	}


func _update_marker_positions() -> void:
	if map_sprite.texture == null:
		return

	map_size = map_sprite.texture.get_size()

	# Calculate position using hex coordinates: O + X * AB + Y * AC
	var team_coords = campaign_data.get("team_coordinates", {"x": 0, "y": 0})
	var hex_x: int = int(team_coords.get("x", 0))
	var hex_y: int = int(team_coords.get("y", 0))

	var vec_ab: Vector2 = hex_point_b.position - hex_point_a.position
	var vec_ac: Vector2 = hex_point_c.position - hex_point_a.position

	team_marker.position = hex_origin.position + hex_x * vec_ab + hex_y * vec_ac

	# Scale marker to fixed world size
	if team_marker.texture:
		var marker_texture_size = team_marker.texture.get_size()
		team_marker.scale = Vector2(MARKER_SIZE, MARKER_SIZE) / marker_texture_size


# Utility function to convert pixel position to normalized coordinates
static func pixel_to_normalized(pixel_pos: Vector2, map_size_param: Vector2) -> Vector2:
	return pixel_pos / map_size_param
