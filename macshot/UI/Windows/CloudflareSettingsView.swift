#if !OFFLINE
import Cocoa

/// State and actions behind Settings ▸ Cloudflare. The token is only ever
/// written through `CloudflareAccount` (Keychain) and is never read back into
/// the UI: the token field stays empty, and leaving it empty on Save keeps the
/// stored token.
@MainActor
final class CloudflareSettingsModel {
    enum Status: Equatable {
        case notSetUp
        /// Account ID or token is missing.
        case incomplete
        case saved
    }

    enum TestOutcome: Equatable {
        case running
        /// `summary` is `CloudflareAccount.TestResult.summary`; `usable` is false
        /// when the token lacks a permission.
        case finished(summary: String, usable: Bool)
        case failed(String)
    }

    private let account: CloudflareAccount
    private(set) var testOutcome: TestOutcome?
    var onChange: (() -> Void)?

    init(account: CloudflareAccount = .shared) {
        self.account = account
    }

    /// The saved account ID, for the field.
    var accountID: String { account.accountID ?? "" }
    var hasToken: Bool { account.apiToken != nil }
    var isConfigured: Bool { account.isConfigured }

    var status: Status {
        if account.isConfigured { return .saved }
        return account.accountID != nil || account.apiToken != nil ? .incomplete : .notSetUp
    }

    /// Saves what was typed. An empty token field keeps the token already
    /// stored (the field never shows it); an empty account ID removes it.
    func save(accountID: String, tokenInput: String) {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        account.save(accountID: accountID, apiToken: token.isEmpty ? (account.apiToken ?? "") : token)
        testOutcome = nil
        onChange?()
    }

    func clear() {
        account.clear()
        testOutcome = nil
        onChange?()
    }

    /// Saves the fields, then checks the token and the Stream/Images access.
    func testConnection(accountID: String, tokenInput: String) async {
        save(accountID: accountID, tokenInput: tokenInput)
        guard account.isConfigured else {
            testOutcome = .failed(CloudflareError.notConfigured.localizedDescription)
            onChange?()
            return
        }
        testOutcome = .running
        onChange?()
        do {
            let result = try await account.testConnection()
            testOutcome = .finished(summary: result.summary, usable: result.isUsable)
        } catch {
            testOutcome = .failed(CloudflareError.wrap(error).localizedDescription)
        }
        onChange?()
    }
}

/// Settings ▸ Cloudflare: account ID, API token, Save / Clear / Test connection.
@MainActor
final class CloudflareSettingsView: NSView {
    let model: CloudflareSettingsModel

    private let accountField = NSTextField()
    private let tokenField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let saveButton = NSButton()
    private let clearButton = NSButton()
    private let testButton = NSButton()

    init(model: CloudflareSettingsModel) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        accountField.stringValue = model.accountID
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Reflect the saved account whenever the tab is shown (not mid-edit).
        if window != nil, accountField.currentEditor() == nil {
            accountField.stringValue = model.accountID
            refresh()
        }
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])

        let header = NSTextField(labelWithString: L("Cloudflare Account").uppercased())
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = .secondaryLabelColor
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(10, after: header)

        accountField.placeholderString = L("Account ID")
        accountField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        accountField.setAccessibilityLabel(L("Account ID:"))
        stack.addArrangedSubview(row(L("Account ID:"), accountField))

        tokenField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tokenField.setAccessibilityLabel(L("API Token:"))
        stack.addArrangedSubview(row(L("API Token:"), tokenField))

        let note = NSTextField(wrappingLabelWithString:
            L("Create an API token with Stream: Edit and Images: Edit permissions for this account. The token is stored in the Keychain, never in exported settings."))
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(note))

        saveButton.title = L("Save")
        clearButton.title = L("Clear")
        testButton.title = L("Test connection")
        for (button, action) in [(saveButton, #selector(save)), (clearButton, #selector(clear)), (testButton, #selector(test))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        saveButton.keyEquivalent = "\r"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [saveButton, clearButton, testButton, spinner])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.addArrangedSubview(indented(buttons))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        statusLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(indented(statusLabel))
        resultLabel.font = .systemFont(ofSize: 11)
        resultLabel.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(indented(resultLabel))
    }

    private static let labelWidth: CGFloat = 130

    private func row(_ title: String, _ field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        return row
    }

    private func indented(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Self.labelWidth + 8).isActive = true
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .top
        return row
    }

    private func refresh() {
        tokenField.placeholderString = model.hasToken ? L("Saved in Keychain — type to replace") : L("API Token")
        switch model.status {
        case .notSetUp:
            statusLabel.stringValue = L("Not set up")
            statusLabel.textColor = .secondaryLabelColor
        case .incomplete:
            statusLabel.stringValue = L("Add both an account ID and an API token.")
            statusLabel.textColor = .systemOrange
        case .saved:
            statusLabel.stringValue = L("Saved")
            statusLabel.textColor = .secondaryLabelColor
        }
        clearButton.isEnabled = model.status != .notSetUp
        switch model.testOutcome {
        case nil:
            resultLabel.stringValue = ""
            spinner.stopAnimation(nil)
            testButton.isEnabled = true
        case .running:
            resultLabel.stringValue = L("Testing…")
            resultLabel.textColor = .secondaryLabelColor
            spinner.startAnimation(nil)
            testButton.isEnabled = false
        case let .finished(summary, usable):
            resultLabel.stringValue = summary
            resultLabel.textColor = usable ? .systemGreen : .systemOrange
            spinner.stopAnimation(nil)
            testButton.isEnabled = true
        case .failed(let message):
            resultLabel.stringValue = message
            resultLabel.textColor = .systemRed
            spinner.stopAnimation(nil)
            testButton.isEnabled = true
        }
        resultLabel.isHidden = resultLabel.stringValue.isEmpty
    }

    @objc private func save() {
        model.save(accountID: accountField.stringValue, tokenInput: tokenField.stringValue)
        tokenField.stringValue = ""
        NotificationCenter.default.post(name: .exportPresetsChanged, object: nil)
    }

    @objc private func clear() {
        model.clear()
        accountField.stringValue = ""
        tokenField.stringValue = ""
        NotificationCenter.default.post(name: .exportPresetsChanged, object: nil)
    }

    @objc private func test() {
        let id = accountField.stringValue
        let token = tokenField.stringValue
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.testConnection(accountID: id, tokenInput: token)
            self.tokenField.stringValue = ""
        }
    }

    // MARK: Test access

    var fields: (account: NSTextField, token: NSSecureTextField) { (accountField, tokenField) }
    var buttons: (save: NSButton, clear: NSButton, test: NSButton) { (saveButton, clearButton, testButton) }
    var resultText: String { resultLabel.stringValue }
}
#endif
