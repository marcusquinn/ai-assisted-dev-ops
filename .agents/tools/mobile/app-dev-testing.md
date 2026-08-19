---
description: Mobile app testing - simulator, emulator, device, E2E, accessibility, QA workflows
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mobile App Testing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Levels**: Unit → Integration → E2E → Visual → Accessibility → Performance
- **Routine-development default**: real app on the simulator/device → platform/app logs and crash output → existing configured checks. The levels below are a selection guide, not a mandate to create suites or mocks.
- **Tool decision**:

```text
AI-driven exploratory?     -> agent-device (CLI, both platforms)
Repeatable E2E flows?      -> maestro (YAML, flakiness tolerance)
Build/test/deploy iOS?     -> xcodebuild-mcp (Xcode, LLDB)
iOS simulator interaction? -> ios-simulator-mcp (tap/swipe/type/screenshot)
Simulator browser preview? -> serve-sim (Apple Simulator stream + control)
Mobile web layout?         -> playwright-emulation (device presets, touch)
```

<!-- AI-CONTEXT-END -->

## Testing Strategy

Use only layers already configured or explicitly requested. For ordinary feature/fix work, exercise the affected flow in the running app first and inspect Metro/Xcode/device logs. Do not install a runner, create a mock server, or add Maestro/E2E infrastructure without user approval.

**Unit (when an existing suite applies)**: Expo → Jest + React Native Testing Library. Swift → XCTest (`xcodebuild-mcp test_sim`). Focus on business logic, data transforms, or state management only when a test is the lowest-cost evidence.

**Integration (when already configured or explicitly requested)**: API clients, navigation flows, state persistence, notification handling. Prefer the real development backend; mock servers are new test infrastructure and require approval.

**E2E (existing Maestro flows or explicit setup request)**:

```yaml
appId: com.example.myapp
---
- launchApp: { clearState: true }
- assertVisible: "Welcome"
- tapOn: "Get Started"
- assertVisible: "You're all set"
- tapOn: "Start Using App"
- assertVisible: "Home"
```

**AI-Driven (agent-device)**:

```bash
agent-device open "My App" --platform ios   # Open app
agent-device snapshot                        # Accessibility tree
agent-device click @e3                       # Interact via refs
agent-device screenshot ./evidence.png       # Capture state
```

**Shared simulator preview (serve-sim)**:

```bash
serve-sim --detach -q                 # JSON with browser preview URL
serve-sim type "demo@example.com"      # Type into focused field
serve-sim button home                  # Hardware button control
serve-sim --kill                       # Cleanup helper(s)
```

**Visual**: Screenshots at affected states via `ios-simulator-mcp` or `agent-device`; use `serve-sim` when the user or agent needs a live browser-visible Apple Simulator stream. Use one representative device by default; broaden to the full device/theme matrix for responsive changes or submission readiness.

**Accessibility**: `agent-device snapshot` — inspect tree. Verify labels, VoiceOver/TalkBack, colour contrast, Dynamic Type. See `tools/accessibility/accessibility-audit.md`.

**Performance**: Launch < 2s, animations 60fps. Monitor memory and network payload. Test on older devices.

## Device Matrix

| Device | Screen | Purpose |
|--------|--------|---------|
| iPhone SE (3rd) | 4.7" | Smallest |
| iPhone 16 | 6.1" | Standard |
| iPhone 16 Pro Max | 6.9" | Largest |
| iPad (10th) | 10.9" | Tablet |
| Pixel 7 / Galaxy S24 | 6.2-6.3" | Android |

Use `playwright-emulation` device presets for web-based testing.

## Distribution Testing

**iOS (TestFlight)**: `eas build --platform ios --profile preview` or Xcode archive → App Store Connect. Internal: 100 testers, no review. External: 10k testers, review required.

**Android**: `eas build --platform android --profile preview` or `./gradlew assembleRelease` → Google Play Console internal track. Distribute via email/Google Group.

## Pre-Submission Checklist

- [ ] E2E flows pass on latest OS versions
- [ ] No crashes in crash reporting
- [ ] Accessibility audit passes
- [ ] Light/dark modes work
- [ ] Localisation complete (or English-only intentional)
- [ ] Offline behaviour graceful
- [ ] Deep links, push notifications work
- [ ] In-app purchases complete (sandbox)
- [ ] App icon, splash screen correct
- [ ] No placeholder/test data visible

## Related

- `tools/mobile/agent-device.md` — AI-driven device automation
- `tools/mobile/xcodebuild-mcp.md` — Xcode build/test
- `tools/mobile/maestro.md` — E2E test flows
- `tools/mobile/ios-simulator-mcp.md` — simulator interaction
- `tools/mobile/serve-sim.md` — Apple Simulator browser stream/control
- `tools/browser/playwright-emulation.md` — mobile web testing
- `tools/accessibility/accessibility-audit.md` — accessibility
