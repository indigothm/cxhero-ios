# CXHero

Lightweight event tracking for Apple platforms with per-session and optional user-id scoping, persisted as JSON on disk.

## Features
- Singleton API: `EventRecorder.shared`
- Sessions with optional `userId` and session metadata
- Durable local storage using JSON Lines per session
- Primitive properties with type-safe encoding
- Async-safe writes via actors
- SwiftUI micro-survey trigger view driven by JSON config
- Supports button-choice or free-text feedback surveys
- Once-per-user gating and cooldowns
- Rich trigger operators (eq, ne, gt, gte, lt, lte, contains, notContains, exists)
- Remote config loading with auto-refresh

## Storage Layout
- Base directory: `Documents/CXHero` (override via `EventRecorder(directory:)`)
- Path: `users/<user-or-anon>/sessions/<session-id>/`
  - `session.json` — metadata (id, userId, startedAt, endedAt, metadata)
  - `events.jsonl` — one JSON event per line

## Installation (Swift Package Manager)
- In Xcode: File → Add Packages… → enter your repository URL `https://github.com/indigothm/cxhero-ios` → Add.
- Or in `Package.swift` dependencies:
```
dependencies: [
    .package(url: "https://github.com/indigothm/cxhero-ios", from: "0.1.0")
]
```

## Quick Start
- Add the package and import `CXHero`.

Code
```
import CXHero

// Start an event session (optional userId + metadata)
let session = await EventRecorder.shared.startSession(userID: "user-123", metadata: [
    "plan": .string("pro"),
    "ab": .string("variantA")
])

// Record events scoped to the current session
EventRecorder.shared.record("button_tap", properties: [
    "screen": .string("Home"),
    "count": .int(1),
    "success": .bool(true)
])

// Read events
let sessionEvents = await EventRecorder.shared.eventsInCurrentSession()
let allEvents = await EventRecorder.shared.allEvents()

// End session (optional)
await EventRecorder.shared.endSession()

// Clear all stored data
await EventRecorder.shared.clear()
```

## SwiftUI Micro Survey
- Define a JSON config that describes survey rules and triggers.

### Example config JSON (choices + text feedback)
```
{
  "$schema": "./survey.schema.json",
  "surveys": [
    {
      "id": "ask_rating",
      "title": "Quick question",
      "message": "How would you rate your experience?",
      "response": {
        "type": "options",
        "options": ["Great", "Okay", "Poor"]
      },
      "oncePerSession": true,
      "oncePerUser": false,
      "cooldownSeconds": 86400,
      "trigger": {
        "event": {
          "name": "checkout_success",
          "properties": {
            "amount": { "op": "gt", "value": 50 },
            "coupon": { "op": "exists" },
            "utm": { "op": "contains", "value": "spring" }
          }
        }
      }
    },
    {
      "id": "open_feedback",
      "title": "We'd love your feedback",
      "message": "Tell us what worked well or what could improve.",
      "response": {
        "type": "text",
        "placeholder": "Share your thoughts…",
        "submitLabel": "Send feedback",
        "minLength": 5,
        "maxLength": 500
      },
      "trigger": {
        "event": {
          "name": "checkout_success",
          "properties": {
            "amount": { "op": "gt", "value": 100 }
          }
        }
      }
    }
  ]
}
```

### Use in your app
```
import SwiftUI
import CXHero

struct RootView: View {
    let config: SurveyConfig

    var body: some View {
        SurveyTriggerView(config: config) {
            AppContent()
        }
    }
}
```

### Loading JSON config from your bundle
```
let url = Bundle.main.url(forResource: "survey", withExtension: "json")!
let config = try SurveyConfig.from(url: url)
```

### Remote config with live updates
```
let initial = try SurveyConfig.from(url: Bundle.main.url(forResource: "survey", withExtension: "json")!)
let manager = SurveyConfigManager(initial: initial)
manager.startAutoRefresh(url: URL(string: "https://example.com/survey.json")!, interval: 300)

var body: some View {
    SurveyTriggerView(manager: manager) {
        AppContent()
    }
}
```

## Survey Config Reference

### Top-level
| Field   | Type            | Required | Default | Description |
|--------|-----------------|----------|---------|-------------|
| `surveys` | `[SurveyRule]` | Yes      | —       | Ordered list of survey rules; the first matching rule is presented. |

### SurveyRule
| Field            | Type                                   | Required | Default | Description |
|------------------|----------------------------------------|----------|---------|-------------|
| `id`             | `String`                                | Yes      | —       | Stable identifier for the survey rule. Used by gating and analytics. |
| `title`          | `String`                                | Yes      | —       | Title shown in the survey sheet. |
| `message`        | `String`                                | Yes      | —       | Message/body shown in the survey sheet. |
| `options`        | `[String]`                              | No       | —       | Legacy list of button options. If present, automatically converted to `response.type = "options"`. |
| `response`       | `SurveyResponse`                        | No*      | —       | Response configuration (choices or text). Recommended for all new configs. |
| `trigger`        | `TriggerCondition`                      | Yes      | —       | When to show the survey (see TriggerCondition). |
| `oncePerSession` | `Bool`                                  | No       | `true`  | If `true`, the rule is shown at most once per current event session. |
| `oncePerUser`    | `Bool`                                  | No       | `false` | If `true`, the rule is never shown again for the same `userId` across sessions. Requires a `userID` when starting sessions; otherwise counts under `anon`. |
| `cooldownSeconds`| `Number` (seconds)                      | No       | —       | Minimum time between presentations for the same `userId`. Ignored if `oncePerUser` is `true` and the rule has already been shown. |

Notes
- At least one of `options` or `response` must be provided. If both appear, `response` wins.
- If both `oncePerUser` and `cooldownSeconds` are provided and the rule was already shown for the user, `oncePerUser` takes precedence and blocks future prompts permanently for that user.
- Session scoping uses `EventRecorder.startSession(userID:metadata:)` to set `userID`. If omitted, the user is recorded as `anon`.

### SurveyResponse
| Type (`response.type`) | Fields | Description |
|------------------------|--------|-------------|
| `"options"`           | `options: [String]` | Presents buttons for each option value. Selecting an option immediately submits. |
| `"text"`              | `placeholder?: String`, `submitLabel?: String`, `allowEmpty?: Bool (default false)`, `minLength?: Int`, `maxLength?: Int` | Renders a multiline text editor with validation. Text is trimmed before submission. |

Notes
- `minLength`/`maxLength` apply after trimming whitespace.
- `allowEmpty: true` permits submitting empty text (still trimmed). Consider the privacy implications of collecting free-form text.

### TriggerCondition
Currently supported: `event`.

`event` trigger matches a recorded event by name and optional property conditions.

`EventTrigger`
| Field        | Type                                   | Required | Description |
|--------------|----------------------------------------|----------|-------------|
| `name`       | `String`                                | Yes      | Event name to match (e.g. `checkout_success`). |
| `properties` | `{ String: PropertyMatcher }`           | No       | Per-property conditions (exact or operator-based). If omitted, only the name must match. |

### PropertyMatcher operators
All operators are case-sensitive. Numeric operators work with integer or double event values (integers are compared after conversion to double).

| Operator        | JSON form                                    | Value type      | Matches when |
|-----------------|-----------------------------------------------|-----------------|--------------|
| equals          | shorthand: `"key": 123` or `{ "op": "eq", "value": 123 }` | string/int/double/bool | Event property equals the value. |
| not equals      | `{ "op": "ne", "value": 123 }`          | string/int/double/bool | Event property does not equal the value. |
| greater than    | `{ "op": "gt", "value": 10 }`           | number          | Event numeric property is strictly greater. |
| greater or equal| `{ "op": "gte", "value": 10 }`          | number          | Event numeric property is greater or equal. |
| less than       | `{ "op": "lt", "value": 10 }`           | number          | Event numeric property is strictly less. |
| less or equal   | `{ "op": "lte", "value": 10 }`          | number          | Event numeric property is less or equal. |
| contains        | `{ "op": "contains", "value": "foo" }` | string          | Event string property contains the substring. |
| notContains     | `{ "op": "notContains", "value": "x" }`| string          | Event string property does not contain the substring. |
| exists          | `{ "op": "exists" }`                      | —               | Property key exists on the event (value can be any type). |
| notExists       | `{ "op": "notExists" }`                   | —               | Property key is absent on the event. |

Examples
- Exact match using shorthand equals:
```
"properties": { "plan": "pro", "count": 3 }
```

- Mixed operators:
```
"properties": {
  "amount": { "op": "gt", "value": 50 },
  "coupon": { "op": "exists" },
  "utm": { "op": "contains", "value": "spring" }
}
```

### Events emitted by the survey
- `survey_presented` with `{ id, responseType }`
- `survey_response`
  - Choice surveys: `{ id, type: "choice", option }`
  - Text surveys: `{ id, type: "text", text }` (trimmed)
- `survey_dismissed` with `{ id, responseType }` (recorded once per presentation; not duplicated on button presses)

### JSON Schema and Validation
- The repository includes `survey.schema.json` describing the full configuration.
- Add a `$schema` reference to your JSON file for editor IntelliSense:
```
{
  "$schema": "./survey.schema.json",
  "surveys": [
    { /* your rules */ }
  ]
}
```
- Validate via Node.js using Ajv CLI:
```
npx ajv-cli validate -s survey.schema.json -d survey.json
```
- Or validate in Swift:
  - Load to `SurveyConfig` with `try JSONDecoder().decode(SurveyConfig.self, from: data)` (runtime validation).

## Behavior
- Observes `EventRecorder.shared.eventsPublisher`.
- When an event matches a rule’s trigger, presents a dismissible sheet.
- On selection, records `survey_response` with `id` and `option` (choices).
- On text submission, records `survey_response` with `id` and trimmed `text`.
- On dismiss, records `survey_dismissed` with `id`.
- `oncePerSession` prevents repeated prompts within a session (default true).
- `oncePerUser` prevents the same survey across sessions for that user.
- `cooldownSeconds` delays re-prompting for that rule and user.

## Design Notes
- Events include `sessionId`, `userId`, `timestamp`, and optional typed `properties`.
- If you call `record(...)` without starting a session, an anonymous session is created automatically.
- JSON timestamps use ISO-8601 for portability.
- Text responses are trimmed before logging. Consider downstream storage/retention for free-form content and scrub PII as needed.

## Analytics Helpers
- List sessions and fetch per-session events for analysis.
```
let all = await EventRecorder.shared.listAllSessions()
let userSessions = await EventRecorder.shared.listSessions(forUserID: "user-123")
let events = await EventRecorder.shared.events(forSessionID: userSessions.first!.id)
```

## License
- Non‑Commercial License (NCL) v1.0. See `LICENSE` for details.
- Commercial licensing is available on a case‑by‑case basis. Open an issue to inquire.

## Contributing
- We use the Developer Certificate of Origin (DCO). Please sign your commits with `-s`.
- By contributing, you agree to the inbound=outbound terms (your contribution is licensed under the repo’s NCL) and grant the maintainers a non‑exclusive, royalty‑free license to relicense your contribution as part of CXHero’s commercial licenses.
- See `CONTRIBUTING.md` for details.
