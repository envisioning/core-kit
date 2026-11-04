import SwiftUI

/// One thing a typeahead can choose: a stable id and the line the user reads.
struct TypeaheadOption: Identifiable, Hashable {
  let id: String
  let title: String
}

/// Typeahead, not a sheet. A labeled row, what is chosen, and a field
/// underneath; nothing is listed until you type, and the matches open inline
/// below the field. Used for every country and relation pick in the CRM
/// editor so all of them find things the same way.
struct TypeaheadPicker: View {
  let label: String
  let prompt: String
  let options: [TypeaheadOption]
  let multiple: Bool
  @Binding var selection: [String]

  @State private var query = ""

  private static let maxMatches = 8

  private var selected: [TypeaheadOption] {
    selection.map { id in
      options.first { $0.id == id } ?? TypeaheadOption(id: id, title: id)
    }
  }

  private var matches: [TypeaheadOption] {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    let taken = Set(selection)
    let hits = options.filter {
      !taken.contains($0.id) && $0.title.localizedCaseInsensitiveContains(text)
    }
    // Prefix matches first, then the rest, each already in option order.
    let prefix = hits.filter { $0.title.range(of: text, options: [.caseInsensitive, .anchored]) != nil }
    let rest = hits.filter { hit in !prefix.contains(hit) }
    return Array((prefix + rest).prefix(Self.maxMatches))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label).foregroundStyle(.primary)
        Spacer()
        if !multiple, let only = selected.first {
          chosen(only)
        } else if selected.isEmpty {
          Text("None").foregroundStyle(crmSecondaryText.opacity(0.6))
        }
      }
      if multiple {
        ForEach(selected) { option in
          HStack {
            Text(option.title).lineLimit(1)
            Spacer()
            removeButton(option)
          }
        }
      }
      TextField(prompt, text: $query)
        .coreField()
        .onSubmit { if let first = matches.first { pick(first) } }
      if !query.trimmingCharacters(in: .whitespaces).isEmpty {
        if matches.isEmpty {
          Text("No matches").font(.callout).foregroundStyle(crmSecondaryText)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(matches) { option in
              Button { pick(option) } label: {
                Text(option.title)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.vertical, 6)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
  }

  private func chosen(_ option: TypeaheadOption) -> some View {
    HStack(spacing: 6) {
      Text(option.title).foregroundStyle(crmSecondaryText).lineLimit(1)
      removeButton(option)
    }
  }

  private func removeButton(_ option: TypeaheadOption) -> some View {
    Button {
      selection.removeAll { $0 == option.id }
    } label: {
      Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Remove \(option.title)")
  }

  private func pick(_ option: TypeaheadOption) {
    if multiple { selection.append(option.id) } else { selection = [option.id] }
    query = ""
  }
}
