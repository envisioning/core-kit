import CoreKit
import SwiftUI

/// A focused, read-only reader for a Doc's Markdown content — full-width,
/// scrollable, images rendered inline. This is a *reading* surface for one long
/// Markdown field, not an alternate record page: it never edits and doesn't
/// replace the always-live detail form. Presented as a sheet from the Doc's
/// detail toolbar.
struct DocMarkdownReader: View {
  let title: String
  let markdown: String

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if !title.isEmpty {
            Text(title)
              .font(.largeTitle)
              .fontWeight(.bold)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          MarkdownText(markdown: markdown)
            .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle(title.isEmpty ? "Doc" : title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}
