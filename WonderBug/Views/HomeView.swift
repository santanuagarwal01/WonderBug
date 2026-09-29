import SwiftUI

/// The "ask a question" screen: question field, four tap-to-insert starters (a long press edits
/// one) and the Ask button. Setting `answerData` swaps the screen over to `AnswerView`.
struct HomeView: View {

    @ObservedObject var viewModel: HomeViewModel
    @Binding var answerData: AnswerData?
    @FocusState private var isQuestionFocused: Bool

    /// The starters, one per line, so a child's own edits (a long press on a chip) survive relaunches.
    /// Each is inserted followed by a space and shown followed by "...".
    @AppStorage("questionStarters") private var storedStarters = HomeView.defaultStarters.joined(separator: "\n")
    @State private var editingStarter: Int?
    @State private var starterDraft = ""

    private static let defaultStarters = ["Why do", "How can", "What do", "Who does"]

    private var starters: [String] {
        let saved = storedStarters.components(separatedBy: "\n")
        return saved.count == Self.defaultStarters.count ? saved : Self.defaultStarters
    }

    private let chipColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            Image("wordmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)

            Text("What are you\nwondering today?")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(Color.wbTitle)
                .multilineTextAlignment(.center)
                .fixedSize()
                .padding(.top, 14)

            ZStack(alignment: .topLeading) {
                if viewModel.question.isEmpty {
                    Text("Type your question here...")
                        .font(.body)
                        .foregroundColor(Color.wbBorder)
                        .padding(20)
                }

                TextField(
                    "",
                    text: $viewModel.question,
                    axis: .vertical
                )
                .lineLimit(7)
                .padding(20)
                .frame(minHeight: isQuestionFocused ? 160 : 260, alignment: .topLeading)
                .focused($isQuestionFocused)
            }
            .background(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.wbBorder, lineWidth: 4)
            )
            .overlay(alignment: .bottomTrailing) {
                if isQuestionFocused {
                    Button {
                        isQuestionFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.wbBorder)
                            .clipShape(Circle())
                    }
                    .padding(14)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .padding(.top, 10)
            .animation(.easeOut(duration: 0.25), value: isQuestionFocused)

            LazyVGrid(columns: chipColumns, spacing: 14) {
                ForEach(starters.indices, id: \.self) { index in
                    // Not a Button: a Button would also fire its tap when a long press ends.
                    Text(starters[index] + "...")
                        .font(.headline)
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.wbChip)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                        .onTapGesture {
                            viewModel.question = starters[index] + " "
                        }
                        .onLongPressGesture {
                            editStarter(index)
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: "Edit") {
                            editStarter(index)
                        }
                }
            }
            .sensoryFeedback(.impact, trigger: editingStarter) { _, index in index != nil }
            .alert("Change this starter", isPresented: isEditingStarter, presenting: editingStarter) { index in
                TextField(Self.defaultStarters[index], text: $starterDraft)
                Button("Save") {
                    saveStarter(index, as: starterDraft)
                }
                Button("Reset") {
                    saveStarter(index, as: Self.defaultStarters[index])
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Tapping it starts a question with these words.")
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                isQuestionFocused = false
                Task {
                    await viewModel.submit()
                    answerData = viewModel.shownAnswer ?? answerData
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    if viewModel.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Ask")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(.white)
                        Image("send")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundColor(.white)
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 18)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(Color.wbBorder)
                .clipShape(Capsule())
            }
            .disabled(viewModel.isLoading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(Color.wbBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            isQuestionFocused = false
        }
    }

    private var isEditingStarter: Binding<Bool> {
        Binding(get: { editingStarter != nil }, set: { if !$0 { editingStarter = nil } })
    }

    private func editStarter(_ index: Int) {
        starterDraft = starters[index]
        editingStarter = index
    }

    /// Saves the chip's new words, dropping any "..." the child typed since the chip adds its own.
    /// Clearing the field puts the original starter back.
    private func saveStarter(_ index: Int, as words: String) {
        let cleaned = words.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".…")))
        var edited = starters
        edited[index] = cleaned.isEmpty ? Self.defaultStarters[index] : cleaned
        storedStarters = edited.joined(separator: "\n")
    }
}
