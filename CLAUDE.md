# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Godot 4.5 editor plugin** that integrates Godot with Claude AI via the Model Context Protocol (MCP). The plugin creates a WebSocket server that allows external tools to remotely control the Godot editor - manipulating scenes, nodes, scripts, and project settings.

## Running the Project

Open in Godot 4.5 editor. The MCP plugin auto-initializes and starts a WebSocket server on port 9080. A control panel in the editor UI allows starting/stopping the server.

## Architecture

### Three-Layer Design

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
- `addons/godot_mcp/plugin.cfg` - Plugin metadata (version 1.0.0)
- `addons/godot_mcp/utils/` - Shared utilities for node trees, resources, scripts
