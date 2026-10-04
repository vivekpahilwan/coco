import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let controller = PetController()
        self.controller = controller
        buildApplicationMenu()
        controller.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.show()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        controller?.makeMenu(includeQuit: false)
    }

    private func buildApplicationMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("Hide or Show Coco", action: #selector(toggleVisible), key: "h"))
        appMenu.addItem(menuItem("Follow My Activity", action: #selector(toggleFollow)))
        appMenu.addItem(menuItem("Make Coco Larger", action: #selector(makeLarger), key: "="))
        appMenu.addItem(menuItem("Make Coco Smaller", action: #selector(makeSmaller), key: "-"))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Quit Coco", action: #selector(quitCoco), key: "q"))

        let root = NSMenu()
        let appItem = NSMenuItem()
        appItem.title = "Coco"
        appItem.submenu = appMenu
        root.addItem(appItem)
        NSApp.mainMenu = root
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleVisible() { controller?.toggleVisible() }
    @objc private func toggleFollow() { controller?.toggleFollow() }
    @objc private func makeLarger() { controller?.makeLarger() }
    @objc private func makeSmaller() { controller?.makeSmaller() }
    @objc private func quitCoco() { NSApp.terminate(nil) }
}

@main
struct CocoDesktopPetApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.run()
    }
}
