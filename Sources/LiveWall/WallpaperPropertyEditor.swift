import AppKit

final class WallpaperPropertyEditor: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    private let project: WallpaperProject
    private var values: [String: WallpaperPropertyValue]
    private let onChange: ([String: WallpaperPropertyValue]) -> Void

    private var panel: NSPanel?
    private var definitionsByName: [String: WallpaperPropertyDefinition] = [:]
    private var controlNames: [ObjectIdentifier: String] = [:]
    private var sliderValueLabels: [String: NSTextField] = [:]
    private var fileFields: [String: NSTextField] = [:]

    init(
        project: WallpaperProject,
        values: [String: WallpaperPropertyValue],
        onChange: @escaping ([String: WallpaperPropertyValue]) -> Void
    ) {
        self.project = project
        self.values = values
        self.onChange = onChange
        super.init()
        definitionsByName = Dictionary(
            uniqueKeysWithValues: project.propertyDefinitions.map {
                ($0.name, $0)
            }
        )
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(project.title) — Wallpaper Properties"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        panel.minSize = NSSize(width: 560, height: 500)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(wrappingLabelWithString: """
        Changes are applied live and saved for this wallpaper. Property \
        conditions from Wallpaper Engine are shown as a flat list.
        """)
        intro.textColor = .secondaryLabelColor
        root.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let propertyStack = NSStackView()
        propertyStack.orientation = .vertical
        propertyStack.alignment = .leading
        propertyStack.spacing = 8
        propertyStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        propertyStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = propertyStack

        NSLayoutConstraint.activate([
            propertyStack.leadingAnchor.constraint(
                equalTo: scrollView.contentView.leadingAnchor
            ),
            propertyStack.trailingAnchor.constraint(
                equalTo: scrollView.contentView.trailingAnchor
            ),
            propertyStack.topAnchor.constraint(
                equalTo: scrollView.contentView.topAnchor
            ),
            propertyStack.widthAnchor.constraint(
                equalTo: scrollView.contentView.widthAnchor
            )
        ])

        for definition in project.propertyDefinitions {
            addControl(for: definition, to: propertyStack)
        }

        root.addArrangedSubview(scrollView)

        let resetButton = NSButton(
            title: "Reset to Packaged Defaults",
            target: self,
            action: #selector(resetDefaults)
        )
        let closeButton = NSButton(
            title: "Done",
            target: self,
            action: #selector(closeEditor)
        )
        closeButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [resetButton, closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        root.addArrangedSubview(buttons)

        guard let contentView = panel.contentView else { return }
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }

    private func addControl(
        for definition: WallpaperPropertyDefinition,
        to stack: NSStackView
    ) {
        if definition.kind == .group {
            let heading = NSTextField(
                labelWithString: definition.displayLabel
            )
            heading.font = .boldSystemFont(ofSize: 13)
            heading.textColor = .labelColor
            if stack.arrangedSubviews.count > 1 {
                stack.addArrangedSubview(NSBox())
            }
            stack.addArrangedSubview(heading)
            heading.widthAnchor.constraint(
                equalTo: stack.widthAnchor,
                constant: -24
            ).isActive = true
            return
        }

        let label = NSTextField(labelWithString: definition.displayLabel)
        label.toolTip = definition.name
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(equalToConstant: 235).isActive = true

        let control: NSView
        switch definition.kind {
        case .bool:
            let checkbox = NSButton(
                checkboxWithTitle: "",
                target: self,
                action: #selector(controlChanged(_:))
            )
            checkbox.state = boolValue(for: definition) ? .on : .off
            register(checkbox, name: definition.name)
            control = checkbox

        case .slider:
            let minimum = definition.minimum ?? 0
            let maximum = definition.maximum ?? 100
            let slider = NSSlider(
                value: numberValue(for: definition),
                minValue: minimum,
                maxValue: maximum,
                target: self,
                action: #selector(controlChanged(_:))
            )
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 260).isActive = true
            register(slider, name: definition.name)

            let valueLabel = NSTextField(
                labelWithString: values[definition.name]?.displayValue
                    ?? definition.defaultValue?.displayValue
                    ?? ""
            )
            valueLabel.alignment = .right
            valueLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
            sliderValueLabels[definition.name] = valueLabel
            let sliderRow = NSStackView(views: [slider, valueLabel])
            sliderRow.orientation = .horizontal
            sliderRow.spacing = 8
            control = sliderRow

        case .combo:
            let popup = NSPopUpButton()
            popup.target = self
            popup.action = #selector(controlChanged(_:))
            for option in definition.options {
                let title = option.label.hasPrefix("ui_")
                    ? option.value.displayValue
                    : option.label
                popup.addItem(withTitle: title)
            }
            if let current = values[definition.name] ?? definition.defaultValue,
               let index = definition.options.firstIndex(where: {
                   $0.value == current
               }) {
                popup.selectItem(at: index)
            }
            popup.widthAnchor.constraint(equalToConstant: 330).isActive = true
            register(popup, name: definition.name)
            control = popup

        case .file:
            let field = NSTextField(
                string: stringValue(for: definition)
            )
            field.placeholderString = "Choose an image or media file"
            field.isEditable = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            fileFields[definition.name] = field

            let button = NSButton(
                title: "Choose…",
                target: self,
                action: #selector(chooseFile(_:))
            )
            register(button, name: definition.name)
            let fileRow = NSStackView(views: [field, button])
            fileRow.orientation = .horizontal
            fileRow.spacing = 8
            control = fileRow

        case .textInput, .color, .unknown:
            let field = NSTextField(
                string: stringValue(for: definition)
            )
            field.target = self
            field.action = #selector(controlChanged(_:))
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 330).isActive = true
            register(field, name: definition.name)
            control = field

        case .group:
            return
        }

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -24
        ).isActive = true
    }

    private func register(_ control: NSControl, name: String) {
        controlNames[ObjectIdentifier(control)] = name
    }

    private func boolValue(for definition: WallpaperPropertyDefinition) -> Bool {
        guard case .bool(let value) =
                values[definition.name] ?? definition.defaultValue else {
            return false
        }
        return value
    }

    private func numberValue(for definition: WallpaperPropertyDefinition) -> Double {
        guard case .number(let value) =
                values[definition.name] ?? definition.defaultValue else {
            return definition.minimum ?? 0
        }
        return value
    }

    private func stringValue(for definition: WallpaperPropertyDefinition) -> String {
        guard case .string(let value) =
                values[definition.name] ?? definition.defaultValue else {
            return ""
        }
        return value
    }

    @objc private func controlChanged(_ sender: NSControl) {
        guard let name = controlNames[ObjectIdentifier(sender)],
              let definition = definitionsByName[name] else {
            return
        }

        switch sender {
        case let checkbox as NSButton where definition.kind == .bool:
            values[name] = .bool(checkbox.state == .on)
        case let slider as NSSlider:
            let step = definition.step ?? 0
            let rawValue = slider.doubleValue
            let value = step > 0 ? (rawValue / step).rounded() * step : rawValue
            values[name] = .number(value)
            sliderValueLabels[name]?.stringValue =
                WallpaperPropertyValue.number(value).displayValue
        case let popup as NSPopUpButton:
            let index = popup.indexOfSelectedItem
            guard definition.options.indices.contains(index) else { return }
            values[name] = definition.options[index].value
        case let field as NSTextField:
            values[name] = .string(field.stringValue)
        default:
            return
        }
        onChange(values)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        controlChanged(field)
    }

    @objc private func chooseFile(_ sender: NSButton) {
        guard let name = controlNames[ObjectIdentifier(sender)] else { return }
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.message = """
        The selected file stays local. LiveWall converts it to a data URL for \
        the web wallpaper instead of exposing your filesystem.
        """
        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }
        values[name] = .string(url.path)
        fileFields[name]?.stringValue = url.path
        onChange(values)
    }

    @objc private func resetDefaults() {
        values = project.defaultPropertyValues
        onChange(values)
        panel?.close()
        panel = nil
        show()
    }

    @objc private func closeEditor() {
        panel?.close()
    }
}
