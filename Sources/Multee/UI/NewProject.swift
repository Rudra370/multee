import AppKit

/// "New Project" — pick a location + name (with an optional "Initialize a Git repository" checkbox),
/// create the folder, optionally `git init` it, then open it as a session. Shared by the File menu, the
/// empty-state button, and the SESSIONS header's create icon.
enum NewProject {
    static func present(model: AppModel) {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.message = "Choose where to create the new project folder."
        panel.prompt = "Create"
        panel.nameFieldLabel = "Project name:"
        panel.nameFieldStringValue = "New Project"
        panel.canCreateDirectories = true

        // "Initialize a Git repository" checkbox in the panel's accessory view (unchecked by default).
        let gitCheck = NSButton(checkboxWithTitle: "Initialize a Git repository", target: nil, action: nil)
        gitCheck.state = .off
        gitCheck.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView()
        accessory.addSubview(gitCheck)
        NSLayoutConstraint.activate([
            accessory.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            gitCheck.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 10),
            gitCheck.bottomAnchor.constraint(equalTo: accessory.bottomAnchor, constant: -10),
            gitCheck.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 20),
            gitCheck.trailingAnchor.constraint(lessThanOrEqualTo: accessory.trailingAnchor, constant: -20),
        ])
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        create(at: url.path, initGit: gitCheck.state == .on, model: model)
    }

    /// Create the folder (if it doesn't exist), optionally `git init`, then open it. Split out of `present`
    /// so it's reachable without the HID-only save panel (the debug harness drives this directly).
    static func create(at path: String, initGit: Bool, model: AppModel) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            // The name already exists — open it if it's a folder; never overwrite.
            if isDir.boolValue { model.openRepo(path) }
            else { error("Couldn’t create the project", "A file already exists at “\((path as NSString).lastPathComponent)”.") }
            return
        }
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            if initGit, let gitErr = Git.initRepo(path) {
                error("Created the folder, but Git init failed", gitErr)   // still open it below
            }
            model.openRepo(path)
        } catch let e {
            error("Couldn’t create the project", e.localizedDescription)
        }
    }

    private static func error(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.alertStyle = .warning
        a.runModal()
    }
}
