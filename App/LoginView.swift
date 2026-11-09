import SwiftUI

struct AppLogo: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x4F8DF7), Color(hex: 0x0B57D0)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "cloud.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct LoginView: View {
    @Environment(DriveModel.self) private var model
    @State private var server = UserDefaults.standard.string(forKey: "lastServer") ?? ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                AppLogo(size: 64)
                VStack(spacing: 6) {
                    Text("Sign in to OpenCloud")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your files, in a familiar drive — on the web and in Finder.")
                        .foregroundStyle(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server address").font(.callout).foregroundStyle(Theme.textSecondary)
                    TextField("cloud.example.com", text: $server)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.chipBorder, lineWidth: 1))
                        .onSubmit { submit() }
                        .disabled(model.isSigningIn)
                }
                .frame(width: 360)

                if let err = model.signInError {
                    Text(err).foregroundStyle(Theme.danger).font(.callout).multilineTextAlignment(.center)
                        .frame(width: 360)
                }

                if model.isSigningIn {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Continue in your browser to sign in…").foregroundStyle(Theme.textSecondary)
                        Button("Cancel") { model.cancelSignIn() }.buttonStyle(.link)
                    }
                } else {
                    Button(action: submit) {
                        Text("Sign in with browser")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .frame(height: 40)
                            .background(Capsule().fill(Color(hex: 0x0B57D0)))
                    }
                    .buttonStyle(.plain)
                    .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(48)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.surface))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        guard !server.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.signIn(server: server)
    }
}
