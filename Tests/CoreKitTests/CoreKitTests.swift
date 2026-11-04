import Foundation
import Testing

@testable import CoreKit

struct CoreKitTests {
  private func registryFixtureData() throws -> Data {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "Fixtures/registry-v1.json")
    return try Data(contentsOf: sourceURL)
  }

  @Test func decodesEntityContractMetadata() throws {
    let json = #"""
      {
        "space":"crm",
        "schemaVersion":1,
        "entities":[{
          "id":"organizations",
          "singularLabel":"Organization",
          "pluralLabel":"Organizations",
          "icon":"building.2",
          "primaryField":"name",
          "secondaryFields":["country"],
          "capabilities":{"list":true,"read":true,"create":true,"update":true,"delete":true},
          "fields":[{"name":"name","label":"Organization Name","kind":"text","required":true}]
        }]
      }
      """#.data(using: .utf8)!

    let metadata = try JSONDecoder().decode(CRMEntityContractData.self, from: json)
    #expect(metadata.schemaVersion == 1)
    #expect(metadata.entities.first?.id == "organizations")
    #expect(metadata.entities.first?.fields.first?.required == true)
  }

  @Test func decodesRegistryAccessSeparatelyFromCapabilities() throws {
    let json = #"""
      {
        "space":"crm",
        "schemaVersion":4,
        "grantedScopes":[],
        "entities":[{
          "id":"licenses",
          "singularLabel":"License",
          "pluralLabel":"Licenses",
          "icon":"receipt",
          "primaryField":"product",
          "secondaryFields":[],
          "capabilities":{"list":true,"read":true,"create":true,"update":true,"delete":true,"search":true},
          "access":{"canRead":false,"canWrite":false,"missingScopes":["licenses:read","licenses:write"]},
          "fields":[]
        }]
      }
      """#.data(using: .utf8)!

    let metadata = try JSONDecoder().decode(CRMEntityContractData.self, from: json)
    let license = try #require(metadata.entities.first)
    #expect(license.capabilities.create)
    #expect(!license.hasReadAccess)
    #expect(!license.canCreate)
    #expect(license.access?.missingScopes == ["licenses:read", "licenses:write"])
  }

  @Test func decodesDynamicCRMRecord() throws {
    let data = #"{"id":"record-1","name":"Acme","is_partner":true}"#.data(using: .utf8)!
    let record = try JSONDecoder().decode(CRMRecord.self, from: data)

    #expect(record.id == "record-1")
    #expect(record["name"]?.stringValue == "Acme")
    #expect(record["is_partner"]?.boolValue == true)
  }

  @Test func formatsContactBirthdayWithOptionalYear() throws {
    let yearless = CRMRecord(fields: [
      "birthday_month": .number(3),
      "birthday_day": .number(14),
      "birthday_year": .null,
    ])
    let complete = CRMRecord(fields: [
      "birthday_month": .number(3),
      "birthday_day": .number(14),
      "birthday_year": .number(1987),
    ])

    #expect(CRMContactBirthday(record: yearless)?.formatted(locale: Locale(identifier: "en_GB")) == "14 March")
    #expect(CRMContactBirthday(record: complete)?.formatted(locale: Locale(identifier: "en_GB")) == "14 March 1987")
  }

  @Test func decodesGeneratedCoreRegistryFixture() throws {
    let registry = try JSONDecoder().decode(
      CRMRegistryData.self,
      from: registryFixtureData()
    )

    #expect(registry.registryVersion == 1)
    #expect(registry.metadataSchemaVersion == 5)
    #expect(registry.entities.count == 16)
    #expect(registry.operations.count == 100)
    #expect(registry.relations.isEmpty == false)
    #expect(
      registry.operations.first { $0.id == "offers.get" }?.http.path
        == "/api/agent/entities/offers/:id"
    )
    #expect(
      registry.operations.first { $0.id == "organizations.get" }?.http.path
        == "/api/agent/organizations/:id"
    )
    #expect(registry.operations.contains { $0.id == "offers.create" } == false)

    let contact = try #require(registry.entities.first { $0.id == "contacts" })
    let birthdayMonth = try #require(
      contact.fields.first { $0.name == "birthday_month" }
    )
    #expect(birthdayMonth.kind == "number")
    #expect(birthdayMonth.min == 1)
    #expect(birthdayMonth.max == 12)
    #expect(contact.fields.contains { $0.name == "birthday_year" })
  }

  @Test func registryVersionInvalidatesOnlyMetadataCache() async throws {
    let accountKey = "registry-test-\(UUID().uuidString)"
    let cache = CRMCacheStore.shared
    defer { Task { try? await cache.purge(accountKey: accountKey) } }

    let fixture = try registryFixtureData()
    let registryV1 = try JSONDecoder().decode(CRMRegistryData.self, from: fixture)
    let registryV2Data = try #require(
      String(data: fixture, encoding: .utf8)?
        .replacingOccurrences(
          of: #""registryVersion": 1"#,
          with: #""registryVersion": 2"#
        )
        .data(using: .utf8)
    )
    let registryV2 = try JSONDecoder().decode(CRMRegistryData.self, from: registryV2Data)

    try await cache.saveRegistry(registryV1, accountKey: accountKey)
    try await cache.saveContracts(registryV1.entityContractData, accountKey: accountKey)
    try await cache.replaceRecords(
      [CRMRecord(fields: ["id": .string("org-1"), "name": .string("Acme")])],
      accountKey: accountKey,
      entity: "organizations",
      primaryField: "name"
    )
    try await cache.saveRegistry(registryV2, accountKey: accountKey)

    #expect(try await cache.registry(accountKey: accountKey)?.registryVersion == 2)
    #expect(try await cache.contracts(accountKey: accountKey) == nil)
    #expect(try await cache.records(accountKey: accountKey, entity: "organizations").records.count == 1)
  }

  @Test func cacheSeparatesRecordsByEntityID() async throws {
    let accountKey = "test-\(UUID().uuidString)"
    let cache = CRMCacheStore.shared
    defer { Task { try? await cache.purge(accountKey: accountKey) } }

    try await cache.replaceRecords(
      [CRMRecord(fields: ["id": .string("org-1"), "name": .string("Acme")])],
      accountKey: accountKey,
      entity: "organizations",
      primaryField: "name"
    )
    try await cache.replaceRecords(
      [CRMRecord(fields: ["id": .string("contact-1"), "name": .string("Ada")])],
      accountKey: accountKey,
      entity: "contacts",
      primaryField: "name"
    )

    let organizations = try await cache.records(
      accountKey: accountKey,
      entity: "organizations"
    )
    let contacts = try await cache.records(accountKey: accountKey, entity: "contacts")

    #expect(organizations.records.map(\.id) == ["org-1"])
    #expect(contacts.records.map(\.id) == ["contact-1"])
  }
}
