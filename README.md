# CXHero

Lightweight event tracking for Apple platforms with per-session and optional user-id scoping, persisted as JSON on disk.

## Features
- Singleton API: `EventRecorder.shared`
- Sessions with optional `userId` and session metadata
- Durable local storage using JSON Lines per session
- Primitive properties with type-safe encoding
- Async-safe writes via actors
- SwiftUI micro-survey trigger view driven by JSON config
 - Once-per-user gating and cooldowns
 - Richer trigger operators (eq, ne, gt, gte, lt, lte, contains, notContains, exists)
 - Remote config loading with auto-refresh

## Storage Layout
- Base directory: `Documents/CXHero` (override via `EventRecorder(directory:)`)
- Path: `users/<user-or-anon>/sessions/<session-id>/`
  - `session.json` — metadata (id, userId, startedAt, endedAt, metadata)
  - `events.jsonl` — one JSON event per line

## Installation (Swift Package Manager)
- In Xcode: File → Add Packages… → enter your repository URL (e.g., https://github.com/<your-org>/CXHero) → Add.
- Or in `Package.swift` dependencies:
```
dependencies: [
    .package(url: "https://github.com/<your-org>/CXHero", from: "0.1.0")
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

### Example config JSON
```
{
  "surveys": [
    {
      "id": "ask_rating",
      "title": "Quick question",
      "message": "How would you rate your experience?",
      "options": ["Great", "Okay", "Poor"],
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

## Behavior
- Observes `EventRecorder.shared.eventsPublisher`.
- When an event matches a rule’s trigger, presents a dismissible sheet.
- On selection, records `survey_response` with `id` and `option`.
- On dismiss, records `survey_dismissed` with `id`.
- `oncePerSession` prevents repeated prompts within a session (default true).
- `oncePerUser` prevents the same survey across sessions for that user.
- `cooldownSeconds` delays re-prompting for that rule and user.

## Design Notes
- Events include `sessionId`, `userId`, `timestamp`, and optional typed `properties`.
- If you call `record(...)` without starting a session, an anonymous session is created automatically.
- JSON timestamps use ISO-8601 for portability.

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
