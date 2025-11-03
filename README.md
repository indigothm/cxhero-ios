# CXHero

Lightweight event tracking for Apple platforms with per-session and optional user-id scoping, persisted as JSON on disk.

## Features
- Singleton API: `EventRecorder.shared`
- Sessions with optional `userId` and session metadata
- Durable local storage using JSON Lines per session
- Primitive properties with type-safe encoding
- Async-safe writes via actors
- **Modern, Polished Survey UI** - Professional, brand-agnostic design with emoji rating buttons
- **Light/Dark Mode Support** - Automatically adapts to system appearance
- SwiftUI micro-survey trigger view driven by JSON config
- **Multi-Question Surveys** - Combined response type supports rating + optional text in one sheet
- Supports button-choice, free-text, or combined (rating + text) feedback surveys
- Smart emoji mapping for rating labels (Poor 😞, Fair 😐, Good 🙂, Great 😊, Excellent 🤩)
- **Explicit Submit Button** - Combined surveys require user to tap submit (no accidental taps)
- Once-per-user gating and cooldowns
- **Scheduled/Delayed Triggers** - Show surveys after a delay (e.g., 70 minutes after check-in)
- **Attempt Tracking** - Track how many times a survey was shown but not completed
- **Max Attempts** - Stop showing a survey after N failed attempts
- **Attempt-Specific Cooldowns** - Different cooldown periods for re-attempts vs initial shows
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

### Enable Local Notifications

To send notifications when surveys are ready:

```swift
SurveyTriggerView(
    config: config,
    notificationsEnabled: true  // Enable notification scheduling
) {
    AppContent()
}
```

**Requirements:**
- Add `notification` configuration to your survey rules
- Request notification permissions (handled automatically by CXHero)
- Notification appears when survey timer expires (even if app is closed)
- Tapping notification opens app and shows survey

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
| `maxAttempts`    | `Integer`                               | No       | —       | Maximum number of times to show this survey before giving up. Counts include dismissals without completion. Once reached, survey won't show again even if not completed. |
| `attemptCooldownSeconds` | `Number` (seconds)              | No       | —       | Cooldown period specifically for re-attempts after dismissals. If not specified, uses `cooldownSeconds`. Useful for having longer delays between re-attempts vs initial shows. |
| `notification`   | `NotificationConfig`                    | No       | —       | Local notification to send when survey is ready. Only works when `notificationsEnabled: true` is passed to `SurveyTriggerView`. |

#### NotificationConfig
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `title` | `String` | Yes | Notification title |
| `body` | `String` | Yes | Notification body text |
| `sound` | `Bool` | No (default: true) | Whether to play notification sound |

Notes
- At least one of `options` or `response` must be provided. If both appear, `response` wins.
- If both `oncePerUser` and `cooldownSeconds` are provided and the rule was already shown for the user, `oncePerUser` takes precedence and blocks future prompts permanently for that user.
- Session scoping uses `EventRecorder.startSession(userID:metadata:)` to set `userID`. If omitted, the user is recorded as `anon`.

### SurveyResponse
| Type (`response.type`) | Fields | Description |
|------------------------|--------|-------------|
| `"options"`           | `options: [String]` | Presents buttons for each option value. Selecting an option immediately submits. |
| `"text"`              | `placeholder?: String`, `submitLabel?: String`, `allowEmpty?: Bool (default false)`, `minLength?: Int`, `maxLength?: Int` | Renders a multiline text editor with validation. Text is trimmed before submission. |
| `"combined"`          | `options: [String]`, `optionsLabel?: String`, `textField?: TextFieldConfig`, `submitLabel?: String` | **Multi-question survey** with rating buttons and optional text field. Requires explicit submit button. Perfect for collecting both rating and detailed feedback. |

#### TextFieldConfig (for combined responses)
| Field | Type | Description |
|-------|------|-------------|
| `label` | `String?` | Label above the text field |
| `placeholder` | `String?` | Placeholder text |
| `required` | `Bool` | Whether text field must be filled (default: false) |
| `minLength` | `Int?` | Minimum characters after trimming |
| `maxLength` | `Int?` | Maximum characters after trimming |

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
| `scheduleAfterSeconds` | `Number` (seconds)            | No       | Delay in seconds before showing the survey after the event matches. If `nil` or `0`, shows immediately. **Scheduled surveys persist across app launches.** |

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
  - **Combined surveys**: `{ id, type: "text", text }` where text format is:
    - With text: `"SelectedOption||User's detailed feedback here"`
    - Without text: `"SelectedOption"`
    - Parse by splitting on `"||"` delimiter
- `survey_dismissed` with `{ id, responseType }` (recorded once per presentation; not duplicated on button presses)

**Parsing combined responses:**
```swift
let responseText = event.properties?["text"]?.asString ?? ""
let parts = responseText.split(separator: "||", maxSplits: 1).map(String.init)
let selectedOption = parts[0]  // e.g., "Excellent"
let detailedFeedback = parts.count > 1 ? parts[1] : nil  // e.g., "Great equipment"
```

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
- When an event matches a rule's trigger, either presents immediately or schedules for later.
- **Scheduled triggers persist across app launches** - if app is closed/relaunched, pending surveys will restore and trigger at the correct time.
- **Optional local notifications** - when `notificationsEnabled: true` and `notification` config provided, sends notification when survey is ready.
- On selection, records `survey_response` with `id` and `option` (choices).
- On text submission, records `survey_response` with `id` and trimmed `text`.
- On dismiss without completion, records `survey_dismissed` with `id` and increments attempt counter.
- On completion (user submits response), marks survey as completed and won't show again.
- `oncePerSession` prevents repeated prompts within a session (default true).
- `oncePerUser` prevents the same survey across sessions for that user.
- `cooldownSeconds` delays re-prompting for that rule and user.
- `maxAttempts` limits the number of times a survey can be shown before giving up.
- `attemptCooldownSeconds` controls re-attempt timing after dismissals (separate from completion cooldown).

## Advanced Example: Multi-Question Feedback Survey with Delayed Trigger

This example demonstrates a **combined response survey** with both rating and optional text feedback, shown after a delay with smart re-attempt logic.

### Combined Response (Rating + Text Field)

```json
{
  "$schema": "./survey.schema.json",
  "surveys": [
    {
      "id": "experience-feedback",
      "title": "How was your experience?",
      "message": "We'd love to hear your thoughts!",
      "response": {
        "type": "combined",
        "options": ["Poor", "Fair", "Good", "Great", "Excellent"],
        "optionsLabel": "How would you rate your experience?",
        "textField": {
          "label": "Tell us more about your experience (optional)...",
          "placeholder": "Share any additional feedback or suggestions",
          "required": false,
          "maxLength": 500
        },
        "submitLabel": "Submit Feedback"
      },
      "trigger": {
        "event": {
          "name": "visit_completed",
          "scheduleAfterSeconds": 3600
        }
      },
      "oncePerSession": true,
      "maxAttempts": 3,
      "attemptCooldownSeconds": 86400,
      "notification": {
        "title": "Quick Survey",
        "body": "Share your feedback and help us improve your experience!",
        "sound": true
      }
    }
  ]
}
```

**UI Behavior:**
1. User sees rating buttons (Poor 😞, Fair 😐, Good 🙂, Great 😊, Excellent 🤩)
2. User selects a rating (button highlights with accent color)
3. Optional text field appears below for additional comments
4. User optionally types feedback
5. User taps "Submit Feedback" button
6. Response format: `"Excellent||Really enjoyed the service"` or just `"Good"` if no text

**Benefits over simple options:**
- Collects structured rating (for metrics)
- Captures detailed feedback (for actionable insights)
- User must make explicit choice to submit
- Text field is truly optional

**Flow behavior:**
1. User completes visit → `visit_completed` event is recorded
2. Survey is scheduled to show 1 hour later (3600 seconds)
3. **If app is closed and reopened**, the scheduled survey persists and will still trigger at the correct time
4. If user dismisses without answering, attempt count increments to 1
5. Survey won't show again until next visit (24 hours later due to `attemptCooldownSeconds`)
6. On 2nd visit (if dismissed again), attempt count becomes 2
7. On 3rd visit (if dismissed again), attempt count becomes 3 → `maxAttempts` reached, survey stops showing
8. If user completes survey at any point, it's marked as completed and won't show again

**Alternative: Different trigger based on user properties**

```json
{
  "id": "fallback-notification",
  "title": "Quick Survey",
  "message": "We sent you a link to complete our survey. Thank you!",
  "response": {
    "type": "options",
    "options": ["OK"]
  },
  "trigger": {
    "event": {
      "name": "visit_completed",
      "properties": {
        "notifications_enabled": false
      },
      "scheduleAfterSeconds": 3600
    }
  },
  "oncePerSession": true,
  "maxAttempts": 1
}
```

## Survey UI Features

The survey UI is designed to be professional, brand-agnostic, and accessible in both light and dark modes.

### Emoji Rating System

Rating buttons automatically display appropriate emojis based on the option label:

| Label Keywords | Emoji | Visual |
|---------------|-------|--------|
| "Poor", "Bad", "1" | 😞 | Disappointed |
| "Fair", "Okay", "2" | 😐 | Neutral |
| "Good", "3" | 🙂 | Slightly smiling |
| "Great", "Very Good", "4" | 😊 | Smiling |
| "Excellent", "Amazing", "Outstanding", "5" | 🤩 | Star-struck |
| Numeric (1-10) | Maps to emojis based on value | |
| Other | ⭐ | Star |

### Visual Design

- **Clean, minimal interface** with proper spacing and hierarchy
- **Card-based rating buttons** with subtle shadows
- **Rounded corners** throughout for a modern feel
- **Responsive layout** that adapts to different screen sizes
- **Press animations** for interactive feedback
- **Light mode**: White cards on light gray background (#F7F7F7)
- **Dark mode**: Dark gray cards (#2E2E2E) on darker background (#1E1E1E)
- **Accessible colors** that work in all lighting conditions
- **Close button** in top-right corner for easy dismissal

### Text Input

- Clean text editor with rounded corners
- Character counter when `maxLength` is specified
- Placeholder text with reduced opacity
- Submit button that's disabled until validation passes
- Full-width button with accent color

## Debug Mode Testing

The package includes a **Debug Mode** that makes testing surveys fast and repeatable.

### Enabling Debug Mode

When `debugModeEnabled: true` is passed to `SurveyTriggerView`:
- **All gating rules are bypassed** - surveys show every time
- Ignores `completedOnce`, `attemptCount`, `oncePerSession`, `oncePerUser`, cooldowns
- Perfect for rapid UI/UX iteration

```swift
SurveyTriggerView(config: config, debugModeEnabled: true) {
    YourAppContent()
}
```

### Delay Override for DEBUG Builds

For faster testing during development, override `scheduleAfterSeconds` programmatically in DEBUG builds:

```swift
#if DEBUG
// Override all delays to 10 seconds for testing
let modifiedSurveys = config.surveys.map { survey in
    if case .event(let eventTrigger) = survey.trigger {
        let modifiedTrigger = EventTrigger(
            name: eventTrigger.name,
            properties: eventTrigger.properties,
            scheduleAfterSeconds: 10.0  // Override to 10 seconds
        )
        return SurveyRule(/* ... */, trigger: .event(modifiedTrigger), /* ... */)
    }
    return survey
}
config = SurveyConfig(surveys: modifiedSurveys)
#endif
```

This way your production JSON keeps the real delays (e.g., 3600 seconds = 1 hour), but debug builds use 10 seconds for rapid iteration.

### Debug Mode Benefits

**With `debugModeEnabled: true`:**
- ✅ Survey shows every time the trigger event fires
- ✅ No completion tracking - test the UI repeatedly
- ✅ No attempt limits - unlimited shows
- ✅ No cooldowns - immediate re-trigger
- ✅ Test flow without clearing app data
- ⚠️ Events still recorded for analytics testing

**For production-like testing**, set `debugModeEnabled: false` to enforce all rules.

## Local Notifications

The package supports sending local notifications when scheduled surveys are ready.

### Configuration

Add `notification` field to your survey rules:

```json
{
  "id": "survey-with-notification",
  "title": "How was your experience?",
  "message": "We'd love your feedback!",
  "notification": {
    "title": "Quick Survey",
    "body": "Share your feedback and help us improve!",
    "sound": true
  },
  "trigger": {
    "event": {
      "name": "visit_completed",
      "scheduleAfterSeconds": 3600
    }
  }
}
```

### Enabling Notifications

```swift
SurveyTriggerView(
    config: config,
    notificationsEnabled: true  // Enable notifications
) {
    AppContent()
}
```

### Behavior

**When survey is scheduled:**
1. Survey persisted to disk
2. Local notification scheduled for trigger time
3. In-app timer also set

**When trigger time expires:**
- **App open**: Survey sheet appears immediately, notification cancelled
- **App closed/background**: Notification appears to user
- **User taps notification**: App opens, survey sheet appears

**When survey completed or dismissed:**
- Pending notification is cancelled
- Survey state updated appropriately

### Notification Permissions

CXHero automatically requests notification permissions on initialization when `notificationsEnabled: true`.

To manually check permissions:
```swift
let scheduler = SurveyNotificationScheduler()
let authorized = await scheduler.checkPermissions()
```

### Debug Mode and Notifications

In debug mode with `debugModeEnabled: true`:
- Notifications still scheduled
- 10-second delay applies to notifications too
- Gating bypassed (survey shows even if already completed)

## Design Notes
- Events include `sessionId`, `userId`, `timestamp`, and optional typed `properties`.
- If you call `record(...)` without starting a session, an anonymous session is created automatically.
- JSON timestamps use ISO-8601 for portability.
- Text responses are trimmed before logging. Consider downstream storage/retention for free-form content and scrub PII as needed.
- **Scheduled surveys persist to disk** and survive app relaunch/termination.
- **UI is fully brand-agnostic** - uses system colors and can be customized via accent color.

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
- Minimum requirements: iOS 14, tvOS 14, macOS 12, watchOS 8.
