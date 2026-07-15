import Foundation

/// Frozen JSON Schemas and descriptions for **all** tools, every phase (§4). The
/// schemas are transcribed verbatim from `docs/PROTOCOL.md`; the descriptions are
/// independently authored (clean-room). Order matches the §4 tool table, which is
/// also the order `tools/list` uses.
public enum ToolSchemas {
    /// A tool's static contract: name, human description, and input JSON Schema.
    public struct Spec: Sendable {
        public let name: String
        public let description: String
        public let schema: JSONValue

        public init(name: String, description: String, schema: JSONValue) {
            self.name = name
            self.description = description
            self.schema = schema
        }
    }

    /// Every defined tool, in §4 table order.
    public static let all: [Spec] = [
        // MARK: Phase 1 — enabled
        Spec(
            name: "doctor",
            description: "Report the macOS Accessibility and Screen Recording permission status of the helper binary. Read-only; it does not trigger a permission prompt unless requestOnboarding is true.",
            schema: objectSchema(
                required: [],
                properties: [
                    "requestOnboarding": ["type": "boolean", "default": false],
                ]
            )
        ),
        Spec(
            name: "list_apps",
            description: "List running and installed applications with a count of capturable windows. Does not scan recent-use history.",
            schema: objectSchema(required: [], properties: [:])
        ),
        Spec(
            name: "launch_app",
            description: "Explicitly launch an application or recover a hidden/minimized one, optionally activate it, and wait a bounded time for a capturable window. Ordinary app resolution never launches or recovers; only this tool does. Policy-gated before dispatch. Does not build an accessibility tree or attach SnapshotOptions.",
            schema: objectSchema(
                required: ["app"],
                properties: [
                    "app": ["type": "string"],
                    "activate": ["type": "boolean", "default": true],
                    "waitForWindowMs": [
                        "type": "integer",
                        "minimum": 0,
                        "default": 3000,
                        "description": "Milliseconds to wait for a capturable window after launch or recovery. Default 3000.",
                    ],
                ]
            )
        ),
        Spec(
            name: "get_app_state",
            description: "Resolve an application and its target window, build a compact accessibility tree, and optionally capture a screenshot. Omit windowId or pass 0 on the first call to auto-select the best window. A positive windowId must be a WindowServer id returned as window.id by an earlier get_app_state response; list_apps.windows is only a count, never an id or index. Creates an app session if needed. Omit scopeElementId except to re-read a subtree using an element id from this session's immediately preceding snapshot.",
            schema: objectSchema(
                required: ["app"],
                properties: [
                    "app": ["type": "string"],
                    "windowId": [
                        "type": "integer",
                        "minimum": 0,
                        "description": "Optional WindowServer id from an earlier get_app_state window.id. Omit or pass 0 to auto-select. Never use list_apps.windows or a zero-based window index.",
                    ],
                    "forceFullTree": ["type": "boolean", "default": false],
                    "disableDiff": ["type": "boolean", "default": false],
                    "includeScreenshot": ["enum": ["auto", "always", "never"], "default": "auto"],
                    // v1.5 (§18.2): scoped/bounded snapshots. `scopeElementId` roots the walk
                    // at a current-snapshot element; `maxNodes` overrides the §7.5 node budget.
                    "scopeElementId": [
                        "type": "string",
                        "pattern": "^e[0-9]+$",
                        "description": "Optional: re-walk the tree rooted at this element (e.g. a web area) instead of the window. Only meaningful with an element id copied from THIS session's CURRENT snapshot. An id that cannot be honored is ignored: the server returns a full unscoped snapshot with a scope_ignored warning — copy fresh ids from that tree, then scope. An honored scoped snapshot retires all other element ids.",
                    ],
                    "maxNodes": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 2000,
                        "description": "Optional: raise this snapshot's emitted-node budget (default 600, hard max 2000) when a large tree truncates. Prefer scopeElementId for deep pages.",
                    ],
                ]
            )
        ),
        Spec(
            name: "read_text",
            description: "Read the full live AXValue string of one revision-checked element without advancing the revision or rebuilding the accessibility tree. Use when a tree field is truncated at the 256-byte cap and you need the complete value. limit is a positive UTF-8 byte budget (default 4096) or the exact string \"max\". Rejects secure text fields. Truncation never splits an extended grapheme cluster.",
            schema: objectSchema(
                required: elementTargetRequired,
                properties: merged(elementTargetProperties, [
                    "limit": .object([
                        "default": .int(4096),
                        "description": "Positive UTF-8 byte budget, or the exact string \"max\" for the full value. Default 4096.",
                        "oneOf": .array([
                            .object([
                                "type": "integer",
                                "minimum": .int(1),
                            ]),
                            .object([
                                "type": "string",
                                "enum": .array([.string("max")]),
                            ]),
                        ]),
                    ]),
                ])
            )
        ),
        // MARK: v1.5 — read-only capture-only tool (§18.9)
        Spec(
            name: "screenshot",
            description: "Capture the target window as a JPEG image without building an accessibility tree. Much cheaper than get_app_state and does not advance the revision — existing element ids stay valid. Use when you only need to SEE the window; use get_app_state when you need elements to act on. Requires Screen Recording.",
            schema: objectSchema(
                required: ["app"],
                properties: [
                    "app": ["type": "string"],
                    "windowId": [
                        "type": "integer",
                        "minimum": 0,
                        "description": "Optional WindowServer id from an earlier get_app_state window.id. Omit or pass 0 to auto-select. Never use list_apps.windows or a zero-based window index.",
                    ],
                ]
            )
        ),
        Spec(
            name: "end_app_session",
            description: "Release an app session together with its accessibility observers and caches. Ending an unknown session is not an error.",
            schema: objectSchema(
                required: ["sessionId"],
                properties: [
                    "sessionId": sessionIdSchema,
                ]
            )
        ),

        // MARK: Phase 2 — semantic actions (element path); click/scroll also carry the
        // Phase 4 coordinate fallback path (§16), dispatched on the presence of `at`.
        Spec(
            name: "click",
            description: "Click the target. Preferred (semantic) form: pass an element (sessionId/revision/elementId) to invoke its primary AXPress (left button; clickCount 1…3 repeats AXPress). Right/middle element clicks deliver through the element's verified current frame under the interference policy. Fallback (coordinate) form: pass a point \"at\" (window points by default, or screenshot pixels) to synthesize a pointer click with optional button (left|right|middle) and clickCount (1…3). Optional observation fields cascade into a post-action state refresh.",
            schema: objectSchema(
                required: ["app", "sessionId"],
                properties: merged(merged(elementTargetProperties, coordinateActionProperties), snapshotOptionProperties)
            )
        ),
        Spec(
            name: "perform_action",
            description: "Invoke a named accessibility action exposed by the target element. Optional observation fields cascade into a post-action state refresh.",
            schema: objectSchema(
                required: elementTargetRequired + ["action"],
                properties: merged(merged(elementTargetProperties, [
                    "action": ["type": "string"],
                ]), snapshotOptionProperties)
            )
        ),
        Spec(
            name: "set_value",
            description: "Set the value (AXValue) of a settable element. With commit:true the server also focuses the element and runs its AXConfirm action when advertised (e.g. to submit/navigate a URL or search field); committed:false in the result means the value was written but not committed. Optional observation fields cascade into a post-action state refresh.",
            schema: objectSchema(
                required: elementTargetRequired + ["value"],
                properties: merged(merged(elementTargetProperties, [
                    "value": ["type": ["string", "number", "boolean"]],
                    // v1.5 (§18.5): run the semantic commit path after the write.
                    "commit": ["type": "boolean", "default": false],
                ]), snapshotOptionProperties)
            )
        ),
        Spec(
            name: "select_text",
            description: "Select a text range in the target element, or place the caret at start when length is zero. Optional observation fields cascade into a post-action state refresh.",
            schema: objectSchema(
                required: elementTargetRequired + ["start", "length"],
                properties: merged(merged(elementTargetProperties, [
                    "start": ["type": "integer", "minimum": 0],
                    "length": ["type": "integer", "minimum": 0],
                ]), snapshotOptionProperties)
            )
        ),
        Spec(
            name: "scroll",
            description: "Scroll the target. Preferred (semantic) form: pass an element to scroll it by lines or pages (count is a positive number; fractional page amounts are exact on settable scrollbar values and approximated for discrete AX page actions). Fallback (coordinate) form: pass a point \"at\" to synthesize a scroll-wheel gesture there, subject to the interference policy. Optional observation fields cascade into a post-action state refresh.",
            schema: objectSchema(
                required: ["app", "sessionId", "direction"],
                properties: merged(merged(merged(elementTargetProperties, [
                    "direction": ["enum": ["up", "down", "left", "right"]],
                    "by": ["enum": ["line", "page"], "default": "line"],
                    // Positive magnitude; integers remain valid (type number accepts int).
                    // exclusive lower bound is enforced by the handler (> 0) because the
                    // schema validator only supports inclusive minimum.
                    "count": ["type": "number", "minimum": 0, "default": 1],
                ]), [
                    "at": pointSchema,
                    "space": spaceSchema,
                    "interference": interferenceSchema,
                ]), snapshotOptionProperties)
            )
        ),

        // MARK: Phase 4 — native fallback input (§16)
        Spec(
            name: "press_key",
            description: "Send a keyboard shortcut or key sequence to the target. combo is space-separated chords of modifiers (cmd|ctrl|opt|shift|fn) plus a key token. Subject to the interference policy (default background-only requires the target to be frontmost). Optionally pass revision+elementId together to set accessibility focus on that element before the keys (e.g. \"enter\" in a URL field); the result then reports elementFocused. Optional observation fields cascade into a post-action state refresh.",
            schema: objectSchema(
                required: ["app", "sessionId", "combo"],
                properties: merged([
                    "app": ["type": "string"],
                    "sessionId": sessionIdSchema,
                    "combo": ["type": "string"],
                    "interference": interferenceSchema,
                    // v1.5 (§18.6): optional element-focus pair, valid only together.
                    "revision": ["type": "integer", "minimum": 1],
                    "elementId": elementIdSchema,
                ], snapshotOptionProperties)
            )
        ),
        Spec(
            name: "type_text",
            description: "Type literal Unicode text into the target. Subject to the interference policy (default background-only requires the target to be frontmost). Optionally pass revision+elementId together to set accessibility focus on that element before typing; the result then reports elementFocused. Optional observation fields cascade into a post-action state refresh.",
            schema: objectSchema(
                required: ["app", "sessionId", "text"],
                properties: merged([
                    "app": ["type": "string"],
                    "sessionId": sessionIdSchema,
                    "text": ["type": "string"],
                    "interference": interferenceSchema,
                    // v1.5 (§18.6): optional element-focus pair, valid only together.
                    "revision": ["type": "integer", "minimum": 1],
                    "elementId": elementIdSchema,
                ], snapshotOptionProperties)
            )
        ),
        Spec(
            name: "drag",
            description: "Drag from one point to another in the target window's coordinate space (default) or screenshot pixels. Subject to the interference policy. Optional observation fields cascade into a post-action state refresh.",
            schema: objectSchema(
                required: ["app", "sessionId", "from", "to"],
                properties: merged([
                    "app": ["type": "string"],
                    "sessionId": sessionIdSchema,
                    "from": pointSchema,
                    "to": pointSchema,
                    "space": spaceSchema,
                    "button": buttonSchema,
                    "modifiers": modifiersSchema,
                    "interference": interferenceSchema,
                ], snapshotOptionProperties)
            )
        ),

        // MARK: v1.5 — read-only outcome verification (§18.7)
        Spec(
            name: "wait_for",
            description: "Poll observable window state until a set of conditions holds or a deadline expires (mode all|any, default all; timeoutMs 100–30000, default 5000). Read-only: never advances the revision, mints element ids, or synthesizes input. An expired deadline is a normal satisfied:false result, not an error. Use it to confirm a UI transition (navigation, new tab, dialog, submit) after an action reports completed. Condition kinds: title_changed{from}, title_contains{value}, url_changed{from}, url_contains{value}, element_exists / element_gone {role?, titleContains?, valueContains?}.",
            schema: .object([
                "type": "object",
                "additionalProperties": false,
                "required": .array(["app", "sessionId", "conditions"].map { .string($0) }),
                "properties": .object([
                    "app": ["type": "string"],
                    "sessionId": sessionIdSchema,
                    "conditions": [
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 4,
                        "items": ["$ref": "#/definitions/Condition"],
                    ],
                    "mode": ["enum": ["all", "any"], "default": "all"],
                    "timeoutMs": ["type": "integer", "minimum": 100, "maximum": 30000, "default": 5000],
                ]),
                "definitions": .object([
                    "Condition": conditionSchema,
                ]),
            ])
        ),
    ]

    /// The schema for a named tool, if defined.
    public static func schema(for name: String) -> JSONValue? {
        all.first { $0.name == name }?.schema
    }

    /// The `wait_for` condition object (§18.7). A discriminated union keyed by `kind`; the
    /// per-kind field requirements are enforced in the handler (an unknown `kind`, or a missing
    /// required field, is a `-32602`), so this describes the superset of fields and constrains
    /// `kind` to the six defined discriminants.
    private static let conditionSchema: JSONValue = [
        "type": "object",
        "required": .array([.string("kind")]),
        "properties": .object([
            "kind": ["enum": ["title_changed", "title_contains", "url_changed", "url_contains", "element_exists", "element_gone"]],
            "from": ["type": "string"],
            "value": ["type": "string"],
            "role": ["type": "string"],
            "titleContains": ["type": "string"],
            "valueContains": ["type": "string"],
        ]),
    ]

    // MARK: - Shared schema fragments

    private static let sessionIdSchema: JSONValue = ["type": "string", "pattern": "^s[0-9]+$"]
    private static let elementIdSchema: JSONValue = ["type": "string", "pattern": "^e[0-9]+$"]

    /// `{ x: number, y: number }` with no extra properties (coordinate points, §9).
    private static let pointSchema: JSONValue = objectSchema(
        required: ["x", "y"],
        properties: [
            "x": ["type": "number"],
            "y": ["type": "number"],
        ]
    )

    /// The per-call interference policy for a fallback action (§16). Default is the
    /// background-only mode; the agent MUST NOT silently escalate.
    private static let interferenceSchema: JSONValue = [
        "enum": ["background-only", "allow-brief-focus", "foreground-takeover"],
        "default": "background-only",
    ]

    /// The coordinate space a coordinate action's points are expressed in (§9).
    private static let spaceSchema: JSONValue = ["enum": ["window", "screenshot"], "default": "window"]

    /// The pointer button for a coordinate click / drag.
    private static let buttonSchema: JSONValue = ["enum": ["left", "middle", "right"], "default": "left"]

    /// Multi-click count for `click` (1 = single, 2 = double, 3 = triple). Default 1.
    private static let clickCountSchema: JSONValue = [
        "type": "integer",
        "minimum": 1,
        "maximum": 3,
        "default": 1,
    ]

    /// Held modifiers for a coordinate click / drag.
    private static let modifiersSchema: JSONValue = [
        "type": "array",
        "items": ["enum": ["cmd", "ctrl", "opt", "shift", "fn"]],
    ]

    /// The Phase 4 coordinate-fallback fields shared by `click` (§16): a target point,
    /// its space, the pointer button, multi-click count, held modifiers, and the
    /// interference policy. `button`/`clickCount` also apply to the element form.
    private static let coordinateActionProperties: [String: JSONValue] = [
        "at": pointSchema,
        "space": spaceSchema,
        "button": buttonSchema,
        "clickCount": clickCountSchema,
        "modifiers": modifiersSchema,
        "interference": interferenceSchema,
    ]

    /// The shared `ElementTarget` field schemas (§4).
    private static let elementTargetProperties: [String: JSONValue] = [
        "app": ["type": "string"],
        "sessionId": sessionIdSchema,
        "revision": ["type": "integer", "minimum": 1],
        "elementId": elementIdSchema,
    ]

    /// Shared observation options accepted by every mutating tool and by `get_app_state`.
    /// Cascaded into post-action refresh; defaults match `get_app_state`.
    private static let snapshotOptionProperties: [String: JSONValue] = [
        "windowId": [
            "type": "integer",
            "minimum": 0,
            "description": "Optional WindowServer id from an earlier get_app_state window.id. Omit or pass 0 to auto-select. Never use list_apps.windows or a zero-based window index.",
        ],
        "forceFullTree": ["type": "boolean", "default": false],
        "disableDiff": ["type": "boolean", "default": false],
        "includeScreenshot": ["enum": ["auto", "always", "never"], "default": "auto"],
        "scopeElementId": [
            "type": "string",
            "pattern": "^e[0-9]+$",
            "description": "Optional: re-walk the tree rooted at this element (e.g. a web area) instead of the window. Only meaningful with an element id copied from THIS session's CURRENT snapshot. An id that cannot be honored is ignored: the server returns a full unscoped snapshot with a scope_ignored warning — copy fresh ids from that tree, then scope. An honored scoped snapshot retires all other element ids.",
        ],
        "maxNodes": [
            "type": "integer",
            "minimum": 1,
            "maximum": 2000,
            "description": "Optional: raise this snapshot's emitted-node budget (default 600, hard max 2000) when a large tree truncates. Prefer scopeElementId for deep pages.",
        ],
    ]

    /// `ElementTarget` required keys, in a stable order.
    private static let elementTargetRequired = ["app", "sessionId", "revision", "elementId"]

    // MARK: - Builders

    /// Build an object schema with `additionalProperties: false`, sorted-stable
    /// `properties`, and an optional `required` array.
    private static func objectSchema(required: [String], properties: [String: JSONValue]) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": "object",
            "additionalProperties": false,
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map { .string($0) })
        }
        return .object(object)
    }

    /// Merge two property maps (right wins on key collision).
    private static func merged(_ base: [String: JSONValue], _ extra: [String: JSONValue]) -> [String: JSONValue] {
        var result = base
        for (key, value) in extra { result[key] = value }
        return result
    }
}
