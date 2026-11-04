// swift-tools-version: 5.9
import PackageDescription

// Core's registry-driven CRM, as a package. `CoreKit` is the data layer (wire
// contracts, agent client, cache, token store, repository); `CoreCRMUI` is the
// SwiftUI that renders whatever the registry publishes. Both apps — Core and
// Meet — consume it by URL, the way they consume EnvisioningUI.
//
// `DocsKit` / `DocsUI` are the same split for docs.envisioning.com: the client
// and wire contract, then the Documents pane and editor that sit on a CRM
// subject page. See meet/docs/DOCS.md.
//
// `KeepKit` / `KeepUI` are the same split for keep.envisioning.com, with one
// difference that matters: `KeepKit` carries the crypto. Every secret is
// sealed on the device, and `KeepKitTests` holds this implementation to the
// bytes the TypeScript one produces. See envisioning/keep README.md.
//
// The floor is Meet's (iOS 17 / macOS 14), not Core's (iOS 26 / macOS 15).
// Anything that needs a newer API is guarded with `#available`, so the package
// stays linkable from the lower of the two.
let package = Package(
  name: "CoreKit",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "CoreKit", targets: ["CoreKit"]),
    .library(name: "CoreCRMUI", targets: ["CoreCRMUI"]),
    .library(name: "DocsKit", targets: ["DocsKit"]),
    .library(name: "DocsUI", targets: ["DocsUI"]),
    .library(name: "KeepKit", targets: ["KeepKit"]),
    .library(name: "KeepUI", targets: ["KeepUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/envisioning/envisioning-ui.git", branch: "main")
  ],
  targets: [
    .target(name: "CoreKit"),
    .target(
      name: "CoreCRMUI",
      dependencies: [
        "CoreKit",
        .product(name: "EnvisioningUI", package: "envisioning-ui"),
      ]
    ),
    .target(name: "DocsKit"),
    .target(
      name: "DocsUI",
      dependencies: [
        "DocsKit",
        "CoreCRMUI",
        .product(name: "EnvisioningUI", package: "envisioning-ui"),
      ]
    ),
    .testTarget(
      name: "CoreKitTests",
      dependencies: ["CoreKit"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(name: "DocsKitTests", dependencies: ["DocsKit"]),
    .target(name: "KeepKit"),
    .target(
      name: "KeepUI",
      dependencies: [
        "KeepKit",
        "CoreCRMUI",
        .product(name: "EnvisioningUI", package: "envisioning-ui"),
      ]
    ),
    .testTarget(
      name: "KeepKitTests",
      dependencies: ["KeepKit"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
