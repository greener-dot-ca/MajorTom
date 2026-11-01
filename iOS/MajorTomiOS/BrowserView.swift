import SwiftUI
import WebKit

struct BrowserView: View {
    @StateObject private var browser = MobileBrowser()
    @FocusState private var addressIsFocused: Bool
    @State private var inputText = ""

    var body: some View {
        WebView(browser.page)
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom) { toolbar }
            .task { browser.open(browser.preferences.homepage) }
            .alert(
                browser.inputPrompt?.message ?? "",
                isPresented: Binding(get: { browser.inputPrompt != nil }, set: { if !$0 { browser.inputPrompt = nil } }),
                presenting: browser.inputPrompt
            ) { prompt in
                if prompt.isSensitive {
                    SecureField("Input", text: $inputText)
                } else {
                    TextField("Input", text: $inputText)
                }
                Button("Send") {
                    browser.submitInput(inputText, for: prompt)
                    inputText = ""
                }
                Button("Cancel", role: .cancel) { inputText = "" }
            }
            .alert(
                "Trust \(browser.trustPrompt?.host ?? "Capsule")?",
                isPresented: Binding(get: { browser.trustPrompt != nil }, set: { _ in }),
                presenting: browser.trustPrompt
            ) { _ in
                Button("Trust", role: .destructive) { browser.answerTrust(true) }
                Button("Cancel", role: .cancel) { browser.answerTrust(false) }
            } message: { prompt in
                Text(prompt.message)
            }
    }

    private var toolbar: some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                if !addressIsFocused {
                    HStack(spacing: 4) {
                        Button("Back", systemImage: "chevron.backward", action: browser.goBack)
                            .disabled(browser.backStack.isEmpty)
                        Button("Forward", systemImage: "chevron.forward", action: browser.goForward)
                            .disabled(browser.forwardStack.isEmpty)
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }

                TextField("Search or enter address", text: $browser.locationText)
                    .focused($addressIsFocused)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { browser.open(browser.locationText) }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .glassEffect(.regular.interactive(), in: .capsule)

                Group {
                    if browser.isLoading {
                        Button("Stop", systemImage: "xmark", action: browser.stop)
                    } else {
                        Button("Reload", systemImage: "arrow.clockwise", action: browser.reload)
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: .circle)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .animation(.default, value: addressIsFocused)
    }
}
