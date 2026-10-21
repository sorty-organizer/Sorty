import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

@MainActor
final class HelpMenuHoverHapticsController: NSObject, NSMenuDelegate {
    private let center: NotificationCenter
    private let targetItemTitle = "Thank you for using Sorty"
    private var didFireForCurrentMenuOpen = false

    init(center: NotificationCenter = .default) {
        self.center = center
        super.init()

        installDelegateOnHelpMenuIfNeeded()

        center.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleMenuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
    }

    @objc private func handleDidBecomeActive() {
        installDelegateOnHelpMenuIfNeeded()
    }

    @objc private func handleMenuDidBeginTracking(_ notification: Notification) {
        guard
            let menu = notification.object as? NSMenu,
            menu.item(withTitle: targetItemTitle) != nil
        else { return }

        installDelegate(on: menu)
        didFireForCurrentMenuOpen = false
    }

    func menuWillOpen(_ menu: NSMenu) {
        didFireForCurrentMenuOpen = false
    }

    func menuDidClose(_ menu: NSMenu) {
        didFireForCurrentMenuOpen = false
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard item?.title == targetItemTitle else { return }
        guard didFireForCurrentMenuOpen == false else { return }

        didFireForCurrentMenuOpen = true
        HapticFeedbackManager.shared.selection()
    }

    private func installDelegateOnHelpMenuIfNeeded() {
        let mainMenu = NSApplication.shared.mainMenu
        guard let mainMenu else { return }

        for menu in allMenus(in: mainMenu) where menu.item(withTitle: targetItemTitle) != nil {
            installDelegate(on: menu)
        }
    }

    private func installDelegate(on menu: NSMenu) {
        if menu.delegate == nil || (menu.delegate as AnyObject?) === self {
            menu.delegate = self
        }
    }

    private func allMenus(in rootMenu: NSMenu) -> [NSMenu] {
        var menus: [NSMenu] = [rootMenu]
        for item in rootMenu.items {
            if let submenu = item.submenu {
                menus.append(contentsOf: allMenus(in: submenu))
            }
        }
        return menus
    }
}
