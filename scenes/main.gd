extends Control

const CAMPAIGN_DATA_PATH = "res://campaign_data/campaign.json"
const CAMPAIGN_DATA_WEB_URL = "campaign_data/campaign.json"  # Relative URL for web builds
const MARKER_SIZE = 32  # Base marker size in pixels

@onready var map_texture: TextureRect = $MapContainer/Map
@onready var markers_container: Control = $MapContainer/MarkersContainer
@onready var team_marker: TextureRect = $MapContainer/MarkersContainer/TeamMarker

var campaign_data: Dictionary = {}
var map_original_size: Vector2 = Vector2.ZERO
var http_request: HTTPRequest


func _ready() -> void:
	get_tree().root.size_changed.connect(_on_viewport_resized)
	_load_campaign_data()


func _load_campaign_data() -> void:
	# On web builds, fetch via HTTP to allow updates without rebuilding
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
		"team_position": {"x": 0.42, "y": 0.37}  # Normalized coordinates (0-1)
	}


func _on_viewport_resized() -> void:
	# Defer to ensure layout has updated
	call_deferred("_update_marker_positions")


func _update_marker_positions() -> void:
	if map_texture.texture == null:
		return

	map_original_size = map_texture.texture.get_size()
	var container_size = map_texture.size

	# Calculate the actual displayed map area (accounting for KEEP_ASPECT_CENTERED)
	var map_rect = _calculate_map_display_rect(container_size, map_original_size)

	# Update team marker position
	var team_pos = campaign_data.get("team_position", {"x": 0.5, "y": 0.5})
	var normalized_pos = Vector2(team_pos.get("x", 0.5), team_pos.get("y", 0.5))
	_position_marker(team_marker, normalized_pos, map_rect)


func _calculate_map_display_rect(container_size: Vector2, texture_size: Vector2) -> Rect2:
	# Calculate scale to fit while keeping aspect ratio
	var scale_x = container_size.x / texture_size.x
	var scale_y = container_size.y / texture_size.y
	var scale = min(scale_x, scale_y)

	var displayed_size = texture_size * scale
	var offset = (container_size - displayed_size) / 2.0

	return Rect2(offset, displayed_size)


func _position_marker(marker: Control, normalized_pos: Vector2, map_rect: Rect2) -> void:
	# Calculate marker size relative to map size (scales with map)
	var marker_scale = map_rect.size.x / map_original_size.x
	var scaled_marker_size = MARKER_SIZE * marker_scale

	# Position marker at normalized coordinates within the map rect
	var pixel_pos = map_rect.position + normalized_pos * map_rect.size

	# Center the marker on the position
	marker.position = pixel_pos - Vector2(scaled_marker_size, scaled_marker_size) / 2.0
	marker.size = Vector2(scaled_marker_size, scaled_marker_size)


# Utility function to convert pixel position to normalized coordinates
# Useful when setting up initial marker positions
static func pixel_to_normalized(pixel_pos: Vector2, map_size: Vector2) -> Vector2:
	return pixel_pos / map_size
