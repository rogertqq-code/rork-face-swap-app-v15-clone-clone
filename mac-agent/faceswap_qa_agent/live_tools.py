from __future__ import annotations

from copy import deepcopy
from typing import Any

from .config import AgentConfig

SCHEMA_URI = "https://json-schema.org/draft/2020-12/schema"


def _object(
    properties: dict[str, Any], required: list[str] | None = None
) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": properties,
        "required": required or [],
        "additionalProperties": False,
    }


def _session_fields() -> dict[str, Any]:
    return {
        "session_id": {"type": "string", "format": "uuid"},
        "lease_token": {"type": "string", "minLength": 32, "maxLength": 256},
        "trace_id": {"type": "string", "format": "uuid"},
    }


def _tool(
    name: str,
    description: str,
    parameters: dict[str, Any],
    *,
    read_only: bool,
) -> dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "inputSchema": {"$schema": SCHEMA_URI, **parameters},
        "annotations": {
            "readOnlyHint": read_only,
            "destructiveHint": False,
            "idempotentHint": read_only,
            "openWorldHint": False,
        },
    }


def _live_action_tool(
    name: str,
    description: str,
    kind: str,
    action_properties: dict[str, Any],
    required: list[str] | None = None,
) -> dict[str, Any]:
    properties = _session_fields()
    properties.update(action_properties)
    schema = _object(properties, ["session_id", "lease_token", *(required or [])])
    tool = _tool(name, description, schema, read_only=False)
    tool["x-action-kind"] = kind
    return tool


def tool_catalog(config: AgentConfig) -> dict[str, Any]:
    session_fields = _session_fields()
    element_id = {"type": "string", "minLength": 1, "maxLength": 512}
    coordinate = {"type": "number", "minimum": 0, "maximum": 100000}
    bundle_id = {"type": "string", "const": config.live.bundle_id}

    tools = [
        _tool(
            "ios_live_session_create",
            "Create an exclusive Appium and WebDriverAgent live-control session for a simulator or cable iPhone.",
            _object(
                {
                    "target": _object(
                        {
                            "kind": {"type": "string", "enum": ["simulator", "cable"]},
                            "udid": {"type": ["string", "null"], "maxLength": 128},
                            "name": {"type": ["string", "null"], "maxLength": 128},
                            "os": {"type": "string", "maxLength": 64, "default": "latest"},
                        },
                        ["kind"],
                    ),
                    "lease_seconds": {
                        "type": "integer",
                        "minimum": 30,
                        "maximum": config.live.maximum_lease_seconds,
                        "default": config.live.default_lease_seconds,
                    },
                    "no_reset": {"type": "boolean", "default": True},
                    "auto_launch": {"type": "boolean", "default": True},
                    "language": {"type": ["string", "null"], "maxLength": 32},
                    "locale": {"type": ["string", "null"], "maxLength": 32},
                },
                ["target"],
            ),
            read_only=False,
        ),
        _tool(
            "ios_live_session_heartbeat",
            "Renew an active live-session lease.",
            _object(
                {
                    **session_fields,
                    "lease_seconds": {
                        "type": "integer",
                        "minimum": 30,
                        "maximum": config.live.maximum_lease_seconds,
                    },
                },
                ["session_id", "lease_token", "lease_seconds"],
            ),
            read_only=False,
        ),
        _tool(
            "ios_live_session_close",
            "Close the live session, stop its WebDriver session, and release exclusive device ownership.",
            _object(session_fields, ["session_id", "lease_token"]),
            read_only=False,
        ),
        _tool(
            "ios_observe",
            "Capture a screenshot, source tree, contexts, orientation, window rectangle, device information, battery information, or combined live observation.",
            _object(
                {
                    **session_fields,
                    "kind": {
                        "type": "string",
                        "enum": [
                            "screenshot",
                            "source_xml",
                            "source_json",
                            "contexts",
                            "orientation",
                            "window_rect",
                            "device_info",
                            "battery_info",
                            "combined",
                        ],
                        "default": "combined",
                    },
                    "persist": {"type": "boolean", "default": True},
                },
                ["session_id", "lease_token"],
            ),
            read_only=True,
        ),
        _live_action_tool(
            "ios_find",
            "Find one or more native iOS elements using an allowlisted locator strategy.",
            "find",
            {
                "using": {
                    "type": "string",
                    "enum": [
                        "accessibility id",
                        "id",
                        "class name",
                        "xpath",
                        "-ios predicate string",
                        "-ios class chain",
                    ],
                },
                "value": {"type": "string", "minLength": 1, "maxLength": 4096},
                "multiple": {"type": "boolean", "default": False},
            },
            ["using", "value"],
        ),
        _live_action_tool(
            "ios_tap_element",
            "Tap a native iOS element by WebDriver element identifier.",
            "tap",
            {"element_id": element_id},
            ["element_id"],
        ),
        _live_action_tool(
            "ios_tap_coordinate",
            "Tap an absolute device-screen coordinate.",
            "tap",
            {"x": coordinate, "y": coordinate},
            ["x", "y"],
        ),
        _live_action_tool(
            "ios_double_tap",
            "Double-tap an element or coordinate.",
            "double_tap",
            {
                "element_id": element_id,
                "x": coordinate,
                "y": coordinate,
            },
        ),
        _live_action_tool(
            "ios_touch_and_hold",
            "Touch and hold an element or coordinate for a bounded duration.",
            "touch_and_hold",
            {
                "element_id": element_id,
                "x": coordinate,
                "y": coordinate,
                "duration": {"type": "number", "minimum": 0.5, "maximum": 60},
            },
            ["duration"],
        ),
        _live_action_tool(
            "ios_swipe",
            "Swipe in a cardinal direction, optionally inside an element.",
            "swipe",
            {
                "element_id": element_id,
                "direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
                "velocity": {"type": "number", "minimum": 1, "maximum": 100000},
            },
            ["direction"],
        ),
        _live_action_tool(
            "ios_drag",
            "Drag between two absolute coordinates over a bounded duration.",
            "drag",
            {
                "from_x": coordinate,
                "from_y": coordinate,
                "to_x": coordinate,
                "to_y": coordinate,
                "duration": {"type": "number", "minimum": 0, "maximum": 60},
            },
            ["from_x", "from_y", "to_x", "to_y"],
        ),
        _live_action_tool(
            "ios_type_text",
            "Type text into an element or the active keyboard target.",
            "type_text",
            {
                "element_id": element_id,
                "text": {
                    "type": "string",
                    "maxLength": config.live.maximum_action_text_length,
                },
            },
            ["text"],
        ),
        _live_action_tool(
            "ios_clear_text",
            "Clear the text value of an element.",
            "clear_text",
            {"element_id": element_id},
            ["element_id"],
        ),
        _live_action_tool(
            "ios_press_key",
            "Press an allowlisted physical iOS key.",
            "press_key",
            {"key": {"type": "string", "enum": ["home", "volumeUp", "volumeDown"]}},
            ["key"],
        ),
        _live_action_tool(
            "ios_get_attribute",
            "Read one attribute from a native element.",
            "get_attribute",
            {
                "element_id": element_id,
                "name": {"type": "string", "minLength": 1, "maxLength": 128},
            },
            ["element_id", "name"],
        ),
        _live_action_tool(
            "ios_set_context",
            "Switch between native and available web-view contexts.",
            "set_context",
            {"name": {"type": "string", "minLength": 1, "maxLength": 256}},
            ["name"],
        ),
        _live_action_tool(
            "ios_alert",
            "Accept, dismiss, inspect buttons, or read text from the current alert.",
            "alert",
            {
                "action": {
                    "type": "string",
                    "enum": ["accept", "dismiss", "get_buttons", "get_text"],
                },
                "button_label": {"type": "string", "minLength": 1, "maxLength": 256},
            },
            ["action"],
        ),
        *[
            _live_action_tool(
                f"ios_{kind}",
                f"Execute the {kind.replace('_', ' ')} lifecycle operation for the configured QA app.",
                kind,
                {"bundle_id": bundle_id},
            )
            for kind in ("launch_app", "activate_app", "terminate_app", "query_app_state")
        ],
        _live_action_tool(
            "ios_background_app",
            "Place the active app in the background for a bounded duration.",
            "background_app",
            {"seconds": {"type": "number", "minimum": 0, "maximum": 3600}},
            ["seconds"],
        ),
        _live_action_tool(
            "ios_qa_command",
            "Execute a typed command through the QA-only in-app command router using its accessibility control surface.",
            "qa_command",
            {"command": {"type": "object", "maxProperties": 64}},
            ["command"],
        ),
        _live_action_tool(
            "ios_settings",
            "Update allowlisted XCUITest or WDA live settings.",
            "settings",
            {
                "mjpegServerFramerate": {"type": "number", "minimum": 1, "maximum": 60},
                "mjpegScalingFactor": {"type": "number", "minimum": 1, "maximum": 100},
                "mjpegServerScreenshotQuality": {"type": "number", "minimum": 1, "maximum": 100},
                "screenshotQuality": {"type": "number", "minimum": 0, "maximum": 3},
                "waitForIdleTimeout": {"type": "number", "minimum": 0, "maximum": 600},
                "animationCoolOffTimeout": {"type": "number", "minimum": 0, "maximum": 600},
            },
        ),
        _live_action_tool(
            "ios_start_network_monitor",
            "Start the iOS 18+ real-device DVT network monitor; samples stream through BiDi event appium:xcuitest.networkMonitor and require RemoteXPC.",
            "start_network_monitor",
            {},
        ),
        _live_action_tool(
            "ios_stop_network_monitor",
            "Stop the active DVT network monitor and its RemoteXPC connection.",
            "stop_network_monitor",
            {},
        ),
    ]

    return {
        "version": "1.0.0",
        "transport": {
            "http": "/api/v1/live",
            "events": "server-sent-events",
            "bidi_module": "faceswap:live",
            "bidi_events": [
                "faceswap:live.actionCompleted",
                "faceswap:live.observationCaptured",
                "appium:xcuitest.contextUpdated",
                "appium:xcuitest.networkMonitor",
                "log.entryAdded",
            ],
        },
        "bundle_id": config.live.bundle_id,
        "tools": deepcopy(tools),
    }
