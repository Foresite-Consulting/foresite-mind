// Quick add: type a line, pick a section (Inbox by default), and it lands on the Actions list.

import UIKit

final class QuickAdd: UIViewController, UITextViewDelegate {
    private let sections: [(key: String, name: String)]
    private let submit: (String, String, @escaping (Result<String, Error>) -> Void) -> Void
    private let text = UITextView()
    private let placeholder = UILabel()
    private let sectionButton = UIButton(type: .system)
    private let status = UILabel()
    private var section = "triage"
    private lazy var addButton = UIBarButtonItem(title: "Add", style: .done, target: self, action: #selector(add))

    init(sections: [(key: String, name: String)], submit: @escaping (String, String, @escaping (Result<String, Error>) -> Void) -> Void) {
        self.sections = sections
        self.submit = submit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = serp
        title = "New action"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = addButton
        addButton.isEnabled = false
        let look = UINavigationBarAppearance()
        look.configureWithOpaqueBackground()
        look.backgroundColor = serp
        look.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationController?.navigationBar.standardAppearance = look
        navigationController?.navigationBar.scrollEdgeAppearance = look

        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.textColor = .white
        text.backgroundColor = ink
        text.layer.cornerRadius = 10
        text.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        text.delegate = self
        text.returnKeyType = .done
        placeholder.text = "What needs doing? Who asked, after a dash."
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.textColor = fog.withAlphaComponent(0.45)
        placeholder.numberOfLines = 0

        var cfg = UIButton.Configuration.tinted()
        cfg.baseForegroundColor = jade
        cfg.baseBackgroundColor = jade
        cfg.image = UIImage(systemName: "tray")
        cfg.imagePadding = 8
        sectionButton.configuration = cfg
        sectionButton.showsMenuAsPrimaryAction = true
        updateSection("triage")

        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = UIColor(red: 1, green: 0.4, blue: 0.31, alpha: 1)
        status.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [text, sectionButton, status])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        text.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            text.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            placeholder.topAnchor.constraint(equalTo: text.topAnchor, constant: 12),
            placeholder.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: 15),
            placeholder.widthAnchor.constraint(equalTo: text.widthAnchor, constant: -30),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        text.becomeFirstResponder()
    }

    private func updateSection(_ key: String) {
        section = key
        let name = sections.first { $0.key == key }?.name ?? "Inbox"
        sectionButton.configuration?.title = "Section: \(name)"
        sectionButton.menu = UIMenu(children: sections.map { s in
            UIAction(title: s.name, state: s.key == key ? .on : .off) { [weak self] _ in self?.updateSection(s.key) }
        })
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        addButton.isEnabled = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        status.text = nil
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText t: String) -> Bool {
        if t == "\n" { add(); return false }
        return true
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func add() {
        let line = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        addButton.isEnabled = false
        status.text = nil
        submit(line, section) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.dismiss(animated: true)
                case .failure(let error):
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.status.text = error.localizedDescription
                    self.addButton.isEnabled = true
                }
            }
        }
    }
}
