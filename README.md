# CoreKit

Core's registry-driven CRM, as a package — shared by
[Core](https://github.com/envisioning/CORE-Helper-App) and
[Meet](https://github.com/envisioning/meet). The backend at
`core.envisioning.com` publishes an entity registry; this package reads it and
renders whatever it lists, under whatever `capabilities` / `access` the server
grants. Almost nothing about the CRM schema is hardcoded here.

```swift
.package(url: "https://github.com/envisioning/core-kit.git", branch: "main")
```

Six products, three pairs. Depend on a data product alone when you only need data.

| Product | What is in it |
|---|---|
| `CoreKit` | Wire contracts (`JSONValue`, `CRMRecord`, entity / field / operation contracts), `CoreAgentClient`, `CRMCacheStore`, `CRMRepository` (the one seam the UI talks to), `TokenManager`, `ServerConfig`, the typed task models, `AgentSpace`, the Plausible and Signals data layers |
| `CoreCRMUI` | `EntityListView`, `EntityDetailView`, `CRMGlobalSearchView`, related sections, tables, avatars, status pills, markdown — the SwiftUI that renders the registry, compiled for iOS and macOS from one source |
| `DocsKit` | The docs.envisioning.com wire contract (`DocsSubject`, `DocsDocumentDetail`, `DocsCategory`, `DocsFolder`, `DocsSummary`, `DocsGrant`, …), `DocsClient` (subject / folder / category lists, tree, summary, the workspace's categories (`categories`, `createCategory`, `updateCategory`, `orderCategories`, `deleteCategory`: categories are data, not a closed list), read, create, autosave-shaped update with `if_content_hash`, subjects, move, search, grants, signature requests, annotations), `DocsDraftStore` (unsaved text on disk, per document), `DocsLinkSave` / `DocsSaveLink` / `DocsLinks` (link saves, meet#345: a native document with `source_kind = link`; `linkImage`; saving and Read again go through Meet's Worker, the one page reader; `DocsListRead.links`), `DocsImage` + `DocsImagePrep` (attached images: `uploadImage`, `imageData`, `deleteImage`; HEIC/TIFF to JPEG and the long edge to 2560 px before upload, since Docs has no image service) |
| `DocsUI` | `DocumentList` (the one row renderer: category, subject chips, lock on mirrored bodies), `DocumentsPane` (every document about a CRM subject, plus New with a category), `DocumentEditor` (reads first: a bar with Share, Edit / Done (⌘E, Esc) and ⋯ for signature and the browser; title and one meta line with the category; the markdown at reading width while editing; autosave; a two-column conflict view; a read-only banner for mirrored bodies), `ShareSheet` (the www switch: `visibility` link/internal and the `www.envisioning.com/private/docs/<id>` link; grants: create, copy link, revoke), `CommentsPane` (Docs annotations under the rendered body: threads, reply, resolve / reopen, a new document-level comment; passage anchors come from the web, since SwiftUI `Text` exposes no selection range), `CategoryPicker`, `SubjectChips`, `NewDocumentSheet`, `LinkGrid` / `LinkCard` / `LinkCoverImage` (the Links view: saves as cards, the cover from Docs' copy, never the site) and `LinkHeader` (the editor's top on a save: site, description, Open, and Read again when the host passes `DocumentEditor(linkRefetch:)`), `DocumentImagesStrip` (screenshots under a save's header: Add, Paste, drop a file, open large, Remove), `DocsRemoteImage` (any image Docs holds, cached for the session by key). Hosted by Meet; see `meet/docs/DOCS.md` |
| `KeepKit` | keep.envisioning.com, the zero-knowledge vault. **This product carries the crypto** (`KeepCrypto`, CryptoKit: P-256 keypairs, ECIES wraps, AES-GCM items, PBKDF2 and PRF wrapping keys), held to the TypeScript implementation by `Tests/KeepKitTests/Fixtures/vectors.json`; the wire models (`KeepModels`); `KeepClient` (device-token bearer, closure-provided like `DocsClient`); `KeepSession` (`@MainActor`: the unlocked private key in memory, idle lock, vault-key cache, every operation a screen needs — enrol, unlock, add a wrap, create/grant/revoke-by-rotation, open/create/update items, project vaults); `KeepRelease` (an agent's attended release, keep#5: `sealRelease` to the agent's session key, the release calls, `KeepSession.resolveRelease` / `release` / `endRelease`); `KeepPasskey` (ASAuthorization with PRF); `KeepTOTP` (RFC 6238); `KeepPasswordGenerator` (+ presets); `KeepPassphrase` |
| `KeepUI` | `KeepRootView` (the gates: connect → enrol → unlock → vaults, with a `KeepLanding` to open straight on a project's vault), `KeepStandaloneView` (Mac host), `KeepUnlockGate` (the same gates around a host's own content, for one act that needs the key), `KeepSplitView` (three columns, macOS), `KeepVaultsView` / `KeepVaultView` / `KeepItemView` / `KeepItemEditor` (iOS pushes; shared sheets), `KeepMembersSheet` (name, icon, members, rotation, delete), `KeepActivitySheet`, `KeepSettingsView` + `KeepUnlockMethodsSections` (host-embeddable), `KeepQRScan` (camera on iOS, picture or clipboard on the Mac), `KeepSecretField`, `KeepIconPicker`. Hosted by Meet; see `meet/docs/KEEP.md`; the service is `envisioning/keep` (`docs/ARCHITECTURE.md`) |

## Rules that travel with the code

- **The registry is the contract.** `CRMEntityContracts.swift` is the
  cross-app boundary; the same registry serves this package and the web app.
  Match the server, don't invent fields. Fail closed when a capability or
  scope is absent.
- **`Tests/CoreKitTests/Fixtures/registry-v1.json` is generated** from the web
  backend (`core-web/fixtures/crm/registry-v1.json`). Refresh it with
  `scripts/sync-registry.sh`; never edit it by hand. The decode test is the compatibility gate.
- **One page per record, always-live fields, deferred commit.** `EntityDetailView`
  is that page; `EntityFieldRow` is the one renderer for view, edit and create.
  Don't reintroduce a read-only detail or a view→edit mode switch.
- **Floor is iOS 17 / macOS 14** (Meet's), not the Core app's. Newer APIs go
  behind `#available` in `PlatformCompat.swift` — see `crmGlassButtonStyle`,
  `listCountSubtitle`, `crmSectionIndexLabel` for the pattern.
- **`DocsClient` never holds the token.** It takes a closure, like
  `CoreAgentClient`; the app's credential store owns the secret. The client
  targets the served `workers.dev` origin — a redirected POST loses its body.
- **The editor never overwrites silently.** Every save carries the hash that
  was read; `hash_mismatch` opens `ConflictView` with both bodies and the person
  chooses. Drafts hit disk on every edit and clear only on server acknowledgement.
- **KeepKit never logs or throws a plaintext.** `KeepCrypto` answers "wrong
  key or tampered data" for both cases. The Worker never links KeepKit; the
  crypto runs on the device only. A revealed value lives in the showing
  view's `@State` and clears on disappear; the private key is memory only.
- **KeepUI owns no `NavigationStack` on iOS.** It is pushed inside Work's
  stack; a stack inside a pushed screen pops the host. Rows are
  destination links, not value links — a `navigationDestination(for:)`
  declared inside a screen reached through `navigationDestination(isPresented:)`
  is not always registered, and a value link with no destination does not
  tap. The Mac wraps the root in `KeepStandaloneView`.
- **Nothing in KeepUI defaults to the system.** `EnvisioningForm`, the
  ladder's rows and surfaces, `EnvisioningFilledButtonStyle`,
  `EnvisioningSemantics.danger`, `EnvisioningPlaceholderRows` while lists
  wait. Grep for `Form {`, `.formStyle`, `.borderedProminent`,
  `.roundedBorder`, `.red` before handing a screen over.
- Framework types are `public` and `Sendable`; concurrency is actor-based.
  2-space indentation. SwiftUI + first-party frameworks + EnvisioningUI only.

## Build

```bash
swift build                      # macOS
swift test                       # registry fixture, cache, Plausible, DocsClient against a stub, Keep vectors + TOTP
xcodebuild -scheme CoreCRMUI -destination 'generic/platform=iOS' build
xcodebuild -scheme DocsUI -destination 'generic/platform=iOS' build
xcodebuild -scheme KeepUI -destination 'generic/platform=iOS' build
```

`scripts/verify.sh` is the gate: it runs all of the above (macOS build and
tests, the three generic iOS builds) and checks the registry fixture against
`../core-web`. There is no CI, so the gate is the only check: turn on the
pre-push hook once per clone.

```bash
git config core.hooksPath .githooks   # runs scripts/verify.sh before every push
scripts/verify.sh                     # or run it by hand
scripts/sync-registry.sh              # refresh the registry fixture from ../core-web
scripts/sync-registry.sh --check      # fail when the fixture differs (verify.sh runs this)
```

In a worktree there is no sibling `core-web`: set `CORE_WEB_DIR` to a checkout.

Consumers pin `branch: main`. A change here has to be pushed before either app
sees it, and a stale SPM checkout can outlive a correct `Package.resolved` —
resolve packages again before concluding the package is behind.

## Where it came from

Extracted from `CORE-Helper-App/COREShared` in September 2026 so Meet could
fold Core's registry surface in under its own Work tab. The plan and the
backlog live in `meet/docs/CORE_REGISTRY.md`.
