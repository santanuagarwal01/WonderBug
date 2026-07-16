import SwiftUI

struct HomeView: View {

    @ObservedObject var viewModel: HomeViewModel
    @Binding var answerData: AnswerData?
    @FocusState private var isQuestionFocused: Bool

    private let suggestions: [(display: String, insert: String)] = [
        ("Why do...", "Why do"),
        ("How can...", "How can"),
        ("What do...", "What do"),
        ("Who does...", "Who does")
    ]

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
                .frame(minHeight: 260, alignment: .topLeading)
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

            LazyVGrid(columns: chipColumns, spacing: 14) {
                ForEach(suggestions, id: \.display) { suggestion in
                    Button {
                        viewModel.question = suggestion.insert + " "
                    } label: {
                        Text(suggestion.display)
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.wbChip)
                            .clipShape(Capsule())
                    }
                }
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

                    if !viewModel.answer.isEmpty {
                        answerData = AnswerData(
                            question: viewModel.question,
                            answer: viewModel.answer,
                            isBlocked: viewModel.isAnswerBlocked
                        )
                    }
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
}
