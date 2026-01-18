# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A **TTRPG Campaign Assistant** built with Godot 4.5 that displays an interactive campaign map with team markers. The web app allows campaign managers to track party position on a custom map, with positions stored in JSON for easy updates without rebuilding.

The project also includes a **Godot MCP plugin** that integrates with Claude AI via the Model Context Protocol, allowing remote editor control through a WebSocket server.

## Requirements

**IMPORTANT: Use only Godot 4.5 installed from Steam.** Do not use other Godot versions or installation sources.

## Running the Project

1. Open the project in Godot 4.5 (Steam version)
2. The MCP plugin auto-initializes and starts a WebSocket server on port 9080
3. Run the main scene to view the campaign map with markers
4. For web builds, export to `web_build/` directory

## Architecture

### Campaign Assistant

- `scenes/main.tscn` - Main scene with map display and marker overlay
- `scenes/main.gd` - Handles map loading, campaign data fetching (local/web), and marker positioning
- `campaign_data/campaign.json` - Team position and campaign metadata (editable without rebuild)
- `assets/map.png` - Campaign map image
- `export_templates/web_shell.html` - Custom web shell with zoom support

### MCP Plugin (Three-Layer Design)

1. **WebSocket Server** (`addons/godot_mcp/mcp_server.gd`) - Handles TCP/WebSocket connections, parses JSON, supports both JSON-RPC 2.0 and legacy formats
2. **Command Handler** (`addons/godot_mcp/command_handler.gd`) - Routes commands to specialized processors
3. **Command Processors** (`addons/godot_mcp/commands/`) - Six specialized modules:
   - `node_commands.gd` - create/delete/update nodes
   - `scene_commands.gd` - save/open/create scenes
   - `script_commands.gd` - create/edit GDScript files
   - `project_commands.gd` - project info and file listing
   - `editor_commands.gd` - editor state queries
   - `editor_script_commands.gd` - execute arbitrary GDScript in editor

### Signal Flow

WebSocket receives JSON → emits `command_received` → handler routes to processor → processor calls `_send_success`/`_send_error` → response sent via `websocket_server.send_response()`

## Code Conventions

- All plugin scripts use `@tool` directive (runs in editor)
- Class naming: `MCP*` prefix for plugin classes
- Command processors extend `MCPBaseCommandProcessor`
- Node paths: absolute (`/root/ChildName`) or relative (converted to absolute)
- Plugin instance stored in `Engine.get_meta("GodotMCPPlugin")`

## Response Format

```gdscript
{
  "status": "success" | "error",
  "result": {...},     # success only
  "message": "...",    # error only
  "commandId": "..."   # optional
}
```

## Key Files

- `project.godot` - GL Compatibility renderer, main scene at `scenes/main.tscn`
- `scenes/main.gd` - Main game logic with map and marker positioning
- `campaign_data/campaign.json` - Campaign state (team position as normalized 0-1 coordinates)
- `export_templates/web_shell.html` - Custom HTML template for web exports
- `addons/godot_mcp/plugin.cfg` - Plugin metadata (version 1.0.0)
- `addons/godot_mcp/utils/` - Shared utilities for node trees, resources, scripts
- `web_build/` - Exported web build (not tracked in git)

## Hex Coordinate System

The team marker position is calculated using a hex grid coordinate system defined by four Marker2D nodes in `scenes/main.tscn`:

- **HexOrigin** - The pixel position corresponding to hex coordinate (0, 0)
- **HexPointA, HexPointB, HexPointC** - Define the basis vectors for the coordinate system

### Position Formula

```
marker_position = HexOrigin.position + X * vec_AB + Y * vec_AC
```

Where:
- `vec_AB = HexPointB.position - HexPointA.position` (displacement for +1 in X direction)
- `vec_AC = HexPointC.position - HexPointA.position` (displacement for +1 in Y direction)

### Important Notes

- HexPointA, B, C define the **scale and direction** of hex movement, not where (0,0) is
- HexOrigin defines **where (0,0) is** on the pixel map
- If you change the map image, you may need to recalibrate all four reference markers

## Web Build

The web export uses a custom shell template with:
- Zoom support (Ctrl+scroll on desktop, pinch on mobile)
- Clean loading screen
- Automatic campaign.json fetching for live updates

### Web Campaign Data Loading

The web version loads campaign data with this priority:
1. **External fetch** from `campaign_data/campaign.json` on the web server (allows live updates without rebuilding)
2. **Bundled fallback** from the PCK file if fetch fails

**IMPORTANT:** Godot's `HTTPRequest` does not work reliably with relative URLs in web exports. The code uses `JavaScriptBridge` to get the browser's current URL and construct an absolute URL for the fetch. If you see the marker at the wrong position on the web build but correct locally, this is likely the cause.

### Deployment Workflow

The GitHub Actions workflow (`.github/workflows/deploy-pages.yml`) deploys to GitHub Pages:
1. Copies `web_build/*` to deploy folder
2. Copies `campaign_data/` to deploy folder (for live updates)
3. The external `campaign_data/campaign.json` takes priority over bundled PCK data
