# Changelog

## [0.2.0] - 2026-09-29

### Added
- **Liquid Glass survey sheet on iOS 26**: partial-height sheet on the system glass background, interactive glass rating tiles in a `GlassEffectContainer`, glass close button, tinted glass submit button in a bottom safe-area bar. Earlier systems keep the opaque card look.
- **`recurring`** on `SurveyRule`: gated only by `cooldownSeconds` since last shown; completion and `maxAttempts` never retire it (e.g. at most once a month).
- **`optionStyle`** on combined responses: `"emoji"` (default) or `"numbers"` to draw a 1-5 scale as numbers.
- `SurveyPresenter` / `\.surveyPresenter` to open a survey on demand from inside `SurveyTriggerView`.

### Changed
- Text on the accent colour is black or white by luminance, so a light brand accent stays legible.

## [Unreleased] - Support for Scheduled Triggers, Attempt Tracking, and Modern UI

### Added

#### Scheduled/Delayed Triggers
- **`scheduleAfterSeconds`** field on `EventTrigger` to delay survey presentation after event matches
- **Persistent scheduling** - scheduled surveys survive app relaunch/termination
- `ScheduledSurveyStore` actor to manage persistent survey scheduling
- Automatic restoration of pending scheduled surveys on app launch
- Cleanup of old scheduled surveys (24 hours by default)
- **Debug mode override** - automatically use 10-second delays in DEBUG builds for rapid testing

#### Attempt Tracking
- **`maxAttempts`** field on `SurveyRule` to limit number of presentation attempts
- **`attemptCooldownSeconds`** field on `SurveyRule` for re-attempt specific cooldowns
- Attempt counter tracking in `SurveyGatingStore`
- **`completedOnce`** flag to distinguish between dismissals and completions
- Surveys stop showing once `maxAttempts` is reached, even if not completed
- Surveys marked as completed won't show again, even if under `maxAttempts`

#### Multi-Question Combined Surveys
- **New `combined` response type** - show rating buttons + optional text field in one survey
- **SelectableRatingButton** component with selected state highlighting
- **Explicit submit button** - prevents accidental submissions
- **Optional text fields** - text input can be required or optional
- **TextFieldConfig** for configuring text field behavior (label, placeholder, validation)
- **Combined response parsing** - format: `"Option||DetailedText"` with delimiter
- **Smart validation** - rating required, text optional (or required if configured)

#### Modern Survey UI
- **Professional, brand-agnostic design** with clean typography and spacing
- **Full light/dark mode support** - adapts automatically to system appearance
- **Emoji rating system** - smart emoji mapping based on option labels:
  - Poor/Bad/1 → 😞
  - Fair/Okay/2 → 😐
  - Good/3 → 🙂
  - Great/Very Good/4 → 😊
  - Excellent/Amazing/5 → 🤩
  - Numeric 1-10 ratings map intelligently
- **Card-based rating buttons** with:
  - Subtle shadows and rounded corners
  - Press animations for tactile feedback
  - Selection highlighting with accent color
  - Responsive layout that adapts to screen size
- **Improved text input** with:
  - Clean rounded corners
  - Character counter
  - Better placeholder styling
  - Full-width submit button
- **Close button** in top-right corner
- **ScrollView support** for long content
- **Accessible colors** optimized for both light and dark modes
- **iOS 14+ compatibility** with iOS 16+ optimizations

#### New Behaviors
- Survey dismissal without completion increments attempt counter
- Survey completion marks survey as done and cancels any pending scheduled instances
- Scheduled surveys are cancelled when starting a new session
- Triggered surveys that missed their window (app was closed) show immediately on app relaunch

### Changed
- **Complete UI redesign** - `SurveySheet` completely rewritten with modern, professional design
- Added `RatingButton` component for emoji-enabled rating buttons
- Added `RatingButtonStyle` for press animations
- Added `TextEditorBackgroundModifier` for iOS version compatibility
- `SurveyGatingStore.canShow()` now accepts `maxAttempts` and `attemptCooldownSeconds` parameters
- `SurveyGatingStore.Record` now includes `attemptCount` and `completedOnce` fields
- `SurveyGatingStore.markShown()` now increments attempt counter
- Added `SurveyGatingStore.markCompleted()` to mark survey as successfully completed
- `SurveyTriggerViewModel` now manages scheduled tasks with persistent storage
- Session changes now restore pending scheduled surveys

### Updated
- JSON schema to include new fields: `scheduleAfterSeconds`, `maxAttempts`, `attemptCooldownSeconds`, combined response type
- README with comprehensive examples for delayed feedback surveys and multi-question forms
- Documentation for all new configuration options