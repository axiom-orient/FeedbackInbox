# FeedbackInbox

Think/work in English; answer the user in Korean. Actual source/tests/runtime are truth.
This is an independent iOS/macOS Swift package: one library, one main target, one test target.
No host-app, TCA, NativeAgent, app database or design-system dependencies.
Own deterministic InboxFlow, reusable SwiftUI/localization, HTTPS client and atomic Keychain storage.
Preserve HTTP/pending/credential formats and app-derived Keychain namespace. Never repeat unknown writes with fresh IDs.
Keep Swift 6 Sendable/I/O boundaries, explicit task cancellation and known commits despite read/cleanup failure.
Do not forward enrollment credentials through HTTP redirects. Use the supplied HTTPS origin.
README.md contains only the approved usage notice and Axient Inc. copyright. Keep local evidence and machine-specific deployment data outside source.
No GitHub Actions, CI/CD, release automation or .github/workflows unless explicitly requested.
Run focused checks for changed contracts; preserve unrelated working-tree edits and lockfiles.
