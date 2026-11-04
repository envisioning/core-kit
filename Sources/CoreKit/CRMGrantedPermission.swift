import Foundation

/// One entity's read/write access, collapsed from raw `entity:action` scopes.
public struct CRMGrantedPermission: Identifiable, Sendable {
  public let id: String
  public let label: String
  public let canRead: Bool
  public let canWrite: Bool

  public static func grouped(_ scopes: [String]) -> [CRMGrantedPermission] {
    var reads: Set<String> = []
    var writes: Set<String> = []
    for scope in scopes {
      let parts = scope.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      if parts[1] == "write" { writes.insert(parts[0]) } else { reads.insert(parts[0]) }
    }
    return reads.union(writes)
      .map { entity in
        CRMGrantedPermission(
          id: entity,
          label: entity.replacingOccurrences(of: "_", with: " ").capitalized,
          canRead: reads.contains(entity),
          canWrite: writes.contains(entity)
        )
      }
      .sorted { $0.label < $1.label }
  }
}
