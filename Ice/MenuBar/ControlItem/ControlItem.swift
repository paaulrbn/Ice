//
//  ControlItem.swift
//  Ice
//

import Cocoa
import Combine

/// A status item that controls a section in the menu bar.
@MainActor
final class ControlItem {
    /// Possible identifiers for control items.
    enum Identifier: String, CaseIterable {
        case iceIcon = "SItem"
        case hidden = "HItem"
        case alwaysHidden = "AHItem"
    }

    /// Possible hiding states for control items.
    enum HidingState {
        case hideItems, showItems
    }

    /// Possible lengths for control items.
    enum Lengths {
        static let standard: CGFloat = NSStatusItem.variableLength
        static let expanded: CGFloat = 10_000
    }

    /// The control item's hiding state (`@Published`).
    @Published var state = HidingState.hideItems

    /// A Boolean value that indicates whether the control item is visible (`@Published`).
    @Published var isVisible = true

    /// The frame of the control item's window (`@Published`).
    @Published private(set) var windowFrame: CGRect?

    /// The shared app state.
    private weak var appState: AppState?

    /// The control item's underlying status item.
    private let statusItem: NSStatusItem

    /// A horizontal constraint for the control item's content view.
    private let constraint: NSLayoutConstraint?

    /// The control item's identifier.
    private let identifier: Identifier

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The menu bar section associated with the control item.
    private weak var section: MenuBarSection? {
        appState?.menuBarManager.sections.first { $0.controlItem === self }
    }

    /// The control item's window.
    var window: NSWindow? {
        statusItem.button?.window
    }

    /// The floating window for the flying Ice icon.
    private var leftIconWindow: NSWindow?

    /// Tracks the last animation state to prevent duplicate/interrupted animations.
    private var lastTargetIsOpening: Bool?

    /// The identifier of the control item's window.
    var windowID: CGWindowID? {
        guard let window else {
            return nil
        }
        return CGWindowID(window.windowNumber)
    }

    /// A Boolean value that indicates whether the control item serves as
    /// a divider between sections.
    var isSectionDivider: Bool {
        identifier != .iceIcon
    }

    /// A Boolean value that indicates whether the control item is currently
    /// displayed in the menu bar.
    var isAddedToMenuBar: Bool {
        statusItem.isVisible
    }

    /// Creates a control item with the given identifier and app state.
    init(identifier: Identifier, appState: AppState) {
        let autosaveName = identifier.rawValue

        // If the status item doesn't have a preferred position, set it
        // according to the identifier.
        if StatusItemDefaults[.preferredPosition, autosaveName] == nil {
            switch identifier {
            case .iceIcon:
                StatusItemDefaults[.preferredPosition, autosaveName] = 0
            case .hidden:
                StatusItemDefaults[.preferredPosition, autosaveName] = 1
            case .alwaysHidden:
                break
            }
        }

        self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
        self.statusItem.autosaveName = autosaveName
        self.identifier = identifier
        self.appState = appState

        // This could break in a new macOS release, but we need this constraint in order to be
        // able to hide the control item when the `ShowSectionDividers` setting is disabled. A
        // previous implementation used the status item's `isVisible` property, which was more
        // robust, but would completely remove the control item. With the current set of
        // features, we need to be able to accurately retrieve the items for each section, so
        // we need the control item to always be present to act as a delimiter. The new solution
        // is to remove the constraint that prevents status items from having a length of zero,
        // then resize the content view. FIXME: Find a replacement for this.
        if
            let button = statusItem.button,
            let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal),
            let constraint = constraints.first(where: Predicates.controlItemConstraint(button: button))
        {
            assert(constraints.filter(Predicates.controlItemConstraint(button: button)).count == 1)
            self.constraint = constraint
        } else {
            self.constraint = nil
        }

        configureStatusItem()
    }

    /// Removes the status item without clearing its stored position.
    deinit {
        // Removing the status item has the unwanted side effect of deleting
        // the preferredPosition. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        NSStatusBar.system.removeStatusItem(statusItem)
        StatusItemDefaults[.preferredPosition, autosaveName] = cached
    }

    /// Configures the internal observers for the control item.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $state.removeDuplicates()
            .sink { [weak self] state in
                self?.updateStatusItem(with: state)
            }
            .store(in: &c)

        Publishers.CombineLatest($isVisible, $state.removeDuplicates())
            .sink { [weak self] (isVisible, state) in
                guard
                    let self,
                    let section
                else {
                    return
                }
                if isVisible {
                    statusItem.length = switch section.name {
                    case .visible: Lengths.standard
                    case .hidden, .alwaysHidden:
                        switch state {
                        case .hideItems: Lengths.expanded
                        case .showItems: Lengths.standard
                        }
                    }
                    constraint?.isActive = true
                } else {
                    statusItem.length = 0
                    constraint?.isActive = false
                    if let window {
                        var size = window.frame.size
                        size.width = 1
                        window.setContentSize(size)
                    }
                }
            }
            .store(in: &c)

        constraint?.publisher(for: \.isActive)
            .removeDuplicates()
            .sink { [weak self] isActive in
                self?.isVisible = isActive
            }
            .store(in: &c)

        statusItem.publisher(for: \.isVisible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard
                    let self,
                    let appState,
                    let section
                else {
                    return
                }

                let manager = appState.settingsManager.hotkeySettingsManager

                let hotkey: Hotkey? = switch section.name {
                case .visible: nil
                case .hidden: manager.hotkey(withAction: .toggleHiddenSection)
                case .alwaysHidden: manager.hotkey(withAction: .toggleAlwaysHiddenSection)
                }

                guard let hotkey else {
                    return
                }

                if isVisible {
                    hotkey.enable()
                } else {
                    hotkey.disable()
                }
            }
            .store(in: &c)

        window?.publisher(for: \.frame)
            .sink { [weak self] frame in
                guard
                    let self,
                    let screen = window?.screen,
                    screen.frame.intersects(frame)
                else {
                    return
                }
                windowFrame = frame
            }
            .store(in: &c)

        if let appState {
            appState.settingsManager.generalSettingsManager.$showIceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] showIceIcon in
                    guard
                        let self,
                        !isSectionDivider
                    else {
                        return
                    }
                    if showIceIcon {
                        addToMenuBar()
                    } else {
                        removeFromMenuBar()
                    }
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$iceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$customIceIconIsTemplate
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$useIceBar
                .receive(on: DispatchQueue.main)
                .sink { [weak self] useIceBar in
                    guard
                        let self,
                        let button = statusItem.button
                    else {
                        return
                    }
                    if useIceBar {
                        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
                    } else {
                        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                    }
                }
                .store(in: &c)

            appState.settingsManager.advancedSettingsManager.$showSectionDividers
                .receive(on: DispatchQueue.main)
                .sink { [weak self] shouldShow in
                    guard
                        let self,
                        isSectionDivider,
                        state == .showItems
                    else {
                        return
                    }
                    isVisible = shouldShow
                }
                .store(in: &c)

            appState.settingsManager.advancedSettingsManager.$enableAlwaysHiddenSection
                .receive(on: DispatchQueue.main)
                .sink { [weak self] enable in
                    guard
                        let self,
                        identifier == .alwaysHidden
                    else {
                        return
                    }
                    if enable {
                        addToMenuBar()
                    } else {
                        removeFromMenuBar()
                    }
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Sets the initial configuration for the status item.
    private func configureStatusItem() {
        defer {
            configureCancellables()
            updateStatusItem(with: state)
        }
        guard let button = statusItem.button else {
            return
        }
        button.target = self
        button.action = #selector(performAction)
    }

    private func setupLeftIconWindowIfNeeded() {
        if leftIconWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .mainMenu + 2
            window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]

            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyDown

            // Allow clicks to pass through if we want it to close?
            // Actually, clicking the left icon should close the menu.
            let click = NSClickGestureRecognizer(target: self, action: #selector(performAction))
            imageView.addGestureRecognizer(click)

            window.contentView = imageView
            leftIconWindow = window
        }
    }

    /// Updates the appearance of the status item using the given hiding state.
    func updateStatusItem(with state: HidingState) {
        guard
            let appState,
            let section,
            let button = statusItem.button
        else {
            return
        }

        switch section.name {
        case .visible:
            isVisible = true
            // Enable the cell, as it may have been previously disabled.
            button.cell?.isEnabled = true
        case .hidden, .alwaysHidden:
            switch state {
            case .hideItems:
                isVisible = true
                button.cell?.isEnabled = false
                button.isHighlighted = false
            case .showItems:
                isVisible = appState.settingsManager.advancedSettingsManager.showSectionDividers
                button.cell?.isEnabled = true
            }
        }

        // Démarrage immédiat de l'animation pour répondre à la demande
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Déterminer la nouvelle image
            let newImage: NSImage?
            switch section.name {
            case .visible:
                let icon = appState.settingsManager.generalSettingsManager.iceIcon
                newImage = switch state {
                case .hideItems: icon.hidden.nsImage(for: appState)
                case .showItems: icon.visible.nsImage(for: appState)
                }
                if case .custom = icon.name, let originalImage = newImage {
                    let ratio = max(originalImage.size.width / 25, originalImage.size.height / 17)
                    _ = originalImage.resized(to: CGSize(width: originalImage.size.width / ratio, height: originalImage.size.height / ratio))
                    // On gère le redimensionnement
                }
            case .hidden, .alwaysHidden:
                switch state {
                case .hideItems:
                    newImage = nil
                case .showItems:
                    switch section.name {
                    case .hidden:
                        newImage = NSImage(size: CGSize(width: 1, height: 1)) // Invisible au lieu de chevronLarge
                    case .alwaysHidden:
                        newImage = NSImage(size: CGSize(width: 1, height: 1)) // Invisible au lieu de chevronSmall
                    case .visible: newImage = nil
                    }
                }
            }

            // Gérer le cas du redimensionnement d'icône custom
            let finalNewImage = newImage

            if section.name != .visible {
                // Astuce pour éviter le bug de décalage de NSButton : utiliser une NSImageView temporaire
                let overlay1 = NSImageView(frame: button.bounds.offsetBy(dx: 0, dy: 0.5))
                overlay1.image = button.image // Image de départ
                overlay1.imageScaling = .scaleProportionallyDown
                button.addSubview(overlay1)

                let overlay2 = NSImageView(frame: button.bounds.offsetBy(dx: 0, dy: 0.5))
                overlay2.image = finalNewImage // Image d'arrivée
                overlay2.imageScaling = .scaleProportionallyDown
                overlay2.alphaValue = 0.0
                button.addSubview(overlay2)

                if let currentImageSize = button.image?.size {
                    button.image = NSImage(size: currentImageSize)
                } else {
                    button.image = nil // Cacher l'image native
                }

                for ov in [overlay1, overlay2] {
                    ov.wantsLayer = true
                    ov.layerUsesCoreImageFilters = true
                    if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                        blurFilter.setDefaults()
                        blurFilter.name = "blur"
                        blurFilter.setValue(0, forKey: kCIInputRadiusKey)
                        ov.layer?.filters = [blurFilter]

                        let blurAnimation = CAKeyframeAnimation(keyPath: "filters.blur.inputRadius")
                        blurAnimation.values = [0.0, 0.0, 4.0, 0.0, 0.0]
                        blurAnimation.keyTimes = [0.0, 0.2, 0.5, 0.9, 1.0]
                        blurAnimation.duration = 0.25
                        blurAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
                        ov.layer?.add(blurAnimation, forKey: "blurAnim")
                    }
                }

                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    overlay1.animator().alphaValue = 0.0
                }, completionHandler: {
                    overlay1.removeFromSuperview()
                    overlay2.removeFromSuperview()
                    button.image = finalNewImage
                })

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.15
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        overlay2.animator().alphaValue = 1.0
                    })
                }
            } else {
                // Pour SItem (.visible), on fait l'animation de translation ET de morphing
                self.setupLeftIconWindowIfNeeded()
                guard let fWindow = self.leftIconWindow, let buttonWindow = button.window else {
                    button.image = finalNewImage
                    return
                }

                let isOpening = (state == .showItems)

                let useIceBar = appState.settingsManager.generalSettingsManager.useIceBar

                // On cherche la vraie bordure gauche des icônes visibles (on ignore celles fermées par l'OS pour ne pas surcompenser)
                var visibleMinX = button.window?.frame.minX ?? 0
                let visibleItems = appState.itemManager.itemCache.managedItems(for: .visible)
                for item in visibleItems {
                    if let frame = Bridging.getWindowFrame(for: item.windowID), frame.minX > 0, frame.minX < visibleMinX {
                        visibleMinX = frame.minX
                    }
                }

                var farLeftX: CGFloat = 0

                // Détermine si la section Always Hidden est ouverte
                let condition1 = (appState.menuBarManager.iceBarPanel.currentSection == .alwaysHidden)
                let condition2 = NSEvent.modifierFlags.contains(.option)
                let condition3 = appState.menuBarManager.section(withName: .alwaysHidden)?.controlItem.state == .showItems
                let isAlwaysHidden = condition1 || condition2 || condition3

                var itemsToMeasure = appState.itemManager.itemCache.managedItems(for: .hidden)
                if isAlwaysHidden {
                    itemsToMeasure += appState.itemManager.itemCache.managedItems(for: .alwaysHidden)
                }

                if useIceBar {
                    let iceBarFrame = appState.menuBarManager.iceBarPanel.frame
                    if iceBarFrame.width > 0 {
                        farLeftX = iceBarFrame.minX - button.frame.width - 2
                    } else {
                        // On additionne uniquement les largeurs des icônes actives
                        let totalWidth = itemsToMeasure.reduce(0) { sum, item in
                            guard let frame = Bridging.getWindowFrame(for: item.windowID) else { return sum }
                            return sum + frame.width
                        }
                        let padding: CGFloat = 14
                        farLeftX = visibleMinX - totalWidth - padding - button.frame.width
                    }
                } else {
                    let totalWidth = itemsToMeasure.reduce(0) { sum, item in
                        guard let frame = Bridging.getWindowFrame(for: item.windowID) else { return sum }
                        return sum + frame.width
                    }
                    farLeftX = visibleMinX - totalWidth - button.frame.width
                }

                if let screen = buttonWindow.screen, screen.hasNotch, let rightArea = screen.auxiliaryTopRightArea {
                    farLeftX = max(farLeftX, rightArea.minX)
                }

                let buttonRectInWindow = button.convert(button.bounds, to: nil)
                let rightFrame = buttonWindow.convertToScreen(buttonRectInWindow)
                let leftFrame = CGRect(x: farLeftX, y: rightFrame.minY, width: rightFrame.width, height: rightFrame.height)

                let startFrame = isOpening ? rightFrame : leftFrame
                let endFrame = isOpening ? leftFrame : rightFrame

                if self.lastTargetIsOpening == isOpening {
                    // Si une animation vers la même destination est déjà en cours,
                    // on se contente de mettre à jour le frame cible pour éviter un téléport ou un arrêt.
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.25
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        fWindow.animator().setFrame(endFrame, display: true)
                    }
                    if !isOpening {
                        button.image = finalNewImage
                    }
                    return
                }
                self.lastTargetIsOpening = isOpening

                let icon = appState.settingsManager.generalSettingsManager.iceIcon
                let startImage = (isOpening ? icon.hidden.nsImage(for: appState) : icon.visible.nsImage(for: appState))?.copy() as? NSImage
                let endImage = (isOpening ? icon.visible.nsImage(for: appState) : icon.hidden.nsImage(for: appState))?.copy() as? NSImage

                startImage?.isTemplate = true
                endImage?.isTemplate = true

                var tintColor: NSColor
                if let renderedColor = self.getRenderedIconColor(from: button) {
                    tintColor = renderedColor
                } else if let averageColor = appState.menuBarManager.averageColorInfo?.color {
                    tintColor = (averageColor.brightness ?? 0) > 0.67 ? .black : .white
                } else {
                    tintColor = .white
                }

                let containerView = NSView(frame: button.bounds)
                containerView.wantsLayer = true

                let click = NSClickGestureRecognizer(target: self, action: #selector(performAction))
                containerView.addGestureRecognizer(click)

                let overlay1 = NSImageView(frame: button.bounds.offsetBy(dx: 0, dy: 0.5))
                overlay1.image = startImage
                overlay1.imageScaling = .scaleProportionallyDown
                overlay1.contentTintColor = tintColor

                let overlay2 = NSImageView(frame: button.bounds.offsetBy(dx: 0, dy: 0.5))
                overlay2.image = endImage
                overlay2.imageScaling = .scaleProportionallyDown
                overlay2.contentTintColor = tintColor
                overlay2.alphaValue = 0.0

                containerView.addSubview(overlay1)
                containerView.addSubview(overlay2)
                fWindow.contentView = containerView

                for ov in [overlay1, overlay2] {
                    ov.wantsLayer = true
                    ov.layerUsesCoreImageFilters = true
                    if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                        blurFilter.setDefaults()
                        blurFilter.name = "blur"
                        blurFilter.setValue(0, forKey: kCIInputRadiusKey)
                        ov.layer?.filters = [blurFilter]

                        let blurAnimation = CAKeyframeAnimation(keyPath: "filters.blur.inputRadius")
                        blurAnimation.values = [0.0, 0.0, 4.0, 0.0, 0.0]
                        blurAnimation.keyTimes = [0.0, 0.2, 0.5, 0.9, 1.0]
                        blurAnimation.duration = 0.25
                        blurAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
                        ov.layer?.add(blurAnimation, forKey: "blurAnim")
                    }
                }

                fWindow.setFrame(startFrame, display: true)
                fWindow.orderFrontRegardless()
                fWindow.alphaValue = 1.0

                // SItem affiche une image transparente pour garder sa taille, ou nil
                let emptyImage = NSImage(size: button.image?.size ?? CGSize(width: 25, height: 25))
                button.image = isOpening ? emptyImage : nil

                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    fWindow.animator().setFrame(endFrame, display: true)
                    overlay1.animator().alphaValue = 0.0
                }, completionHandler: {
                    if !isOpening {
                        fWindow.orderOut(nil)
                        button.image = finalNewImage
                    }
                })

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.15
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        overlay2.animator().alphaValue = 1.0
                    })
                }
            }
        }
    }

    /// Performs the control item's action.
    @objc private func performAction() {
        guard
            let appState,
            let event = NSApp.currentEvent
        else {
            return
        }
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            if NSEvent.modifierFlags == .control {
                statusItem.showMenu(createMenu(with: appState))
            } else if
                NSEvent.modifierFlags == .option,
                appState.settingsManager.advancedSettingsManager.canToggleAlwaysHiddenSection
            {
                if let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden) {
                    alwaysHiddenSection.toggle()
                }
            } else {
                section?.toggle()
            }
        case .rightMouseUp:
            statusItem.showMenu(createMenu(with: appState))
        default:
            break
        }
    }

    /// Creates a menu to show under the control item.
    private func createMenu(with appState: AppState) -> NSMenu {
        func hotkey(withAction action: HotkeyAction) -> Hotkey? {
            let hotkeySettingsManager = appState.settingsManager.hotkeySettingsManager
            return hotkeySettingsManager.hotkey(withAction: action)
        }

        let menu = NSMenu(title: "Ice")

        let settingsItem = NSMenuItem(
            title: "Ice Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let searchItem = NSMenuItem(
            title: "Search Menu Bar Items",
            action: #selector(showSearchPanel),
            keyEquivalent: ""
        )
        searchItem.target = self
        if
            let hotkey = hotkey(withAction: .searchMenuBarItems),
            let keyCombination = hotkey.keyCombination
        {
            searchItem.keyEquivalent = keyCombination.key.keyEquivalent
            searchItem.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
        }
        menu.addItem(searchItem)

        menu.addItem(.separator())

        // Add menu items to toggle the hidden and always-hidden sections.
        let sectionNames: [MenuBarSection.Name] = [.hidden, .alwaysHidden]
        for name in sectionNames {
            guard
                let section = appState.menuBarManager.section(withName: name),
                section.controlItem.isAddedToMenuBar
            else {
                // Section doesn't exist, or is disabled.
                continue
            }
            let item = NSMenuItem(
                title: "\(section.isHidden ? "Show" : "Hide") the \(name.displayString) Section",
                action: #selector(toggleMenuBarSection),
                keyEquivalent: ""
            )
            item.target = self
            Self.sectionStorage.weakSet(section, for: item)
            switch name {
            case .visible:
                break
            case .hidden:
                if
                    let hotkey = hotkey(withAction: .toggleHiddenSection),
                    let keyCombination = hotkey.keyCombination
                {
                    item.keyEquivalent = keyCombination.key.keyEquivalent
                    item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
                }
            case .alwaysHidden:
                if
                    let hotkey = hotkey(withAction: .toggleAlwaysHiddenSection),
                    let keyCombination = hotkey.keyCombination
                {
                    item.keyEquivalent = keyCombination.key.keyEquivalent
                    item.keyEquivalentModifierMask = keyCombination.modifiers.nsEventFlags
                }
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Ice",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        return menu
    }

    /// Toggles the menu bar section associated with the given menu item.
    @objc private func toggleMenuBarSection(for menuItem: NSMenuItem) {
        Self.sectionStorage.value(for: menuItem)?.toggle()
    }

    /// Opens the menu bar search panel.
    @objc private func showSearchPanel() {
        guard
            let appState,
            let screen = MenuBarSearchPanel.defaultScreen
        else {
            return
        }
        Task {
            await appState.menuBarManager.searchPanel.show(on: screen)
        }
    }

    /// Opens the settings window and checks for app updates.
    @objc private func checkForUpdates() {
        guard let appState else {
            return
        }
        appState.updatesManager.checkForUpdates()
    }

    /// Adds the control item to the menu bar.
    func addToMenuBar() {
        guard !isAddedToMenuBar else {
            return
        }
        statusItem.isVisible = true
    }

    /// Removes the control item from the menu bar.
    func removeFromMenuBar() {
        guard isAddedToMenuBar else {
            return
        }
        // Setting `statusItem.isVisible` to `false` has the unwanted side
        // effect of deleting the preferredPosition. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        statusItem.isVisible = false
        StatusItemDefaults[.preferredPosition, autosaveName] = cached
    }

    private func getRenderedIconColor(from button: NSStatusBarButton) -> NSColor? {
        guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return nil }
        button.cacheDisplay(in: button.bounds, to: bitmap)
        for x in 0..<Int(bitmap.pixelsWide) {
            for y in 0..<Int(bitmap.pixelsHigh) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent > 0.5 {
                    if let rgb = color.usingColorSpace(.deviceRGB) {
                        return NSColor(deviceRed: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: 1.0)
                    }
                }
            }
        }
        return nil
    }
}

private extension ControlItem {
    /// Storage for menu items that toggle a menu bar section.
    ///
    /// When one of these menu items is created, its section is stored here.
    /// When its action is invoked, the section is retrieved from storage.
    static let sectionStorage = ObjectStorage<MenuBarSection>()
}

// MARK: - Logger
private extension Logger {
    /// The logger to use for control items.
    static let controlItem = Logger(category: "ControlItem")
}
