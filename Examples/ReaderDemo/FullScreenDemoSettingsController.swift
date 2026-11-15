import UIKit

/// 原生阅读设置面板；所有修改先写入草稿，应用成功后才关闭面板。
@MainActor
final class FullScreenDemoSettingsController: UITableViewController, UIAdaptivePresentationControllerDelegate, UISearchResultsUpdating {
    var onClose: (() -> Void)?

    fileprivate typealias Field = FullScreenDemoSettings.Field
    private let originalSettings: FullScreenDemoSettings
    private var draft: FullScreenDemoSettings
    private let onApply: (FullScreenDemoSettings) -> String?
    private var didClose = false
    private var isClosing = false
    private var notifyOnDisappear = false
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchQuery = ""
    private var groups: [FullScreenDemoSettings.Group] {
        guard !searchQuery.isEmpty else { return FullScreenDemoSettings.groups }
        return FullScreenDemoSettings.groups.compactMap { group in
            let fields = group.fields.filter { ($0.title + " " + $0.name + " " + $0.hint).localizedCaseInsensitiveContains(searchQuery) }
            return fields.isEmpty ? nil : .init(title: group.title, hint: group.hint, fields: fields)
        }
    }

    /// - Parameter searchController: 搜索输入；实时过滤设置名称及 API 字段名。
    func updateSearchResults(for searchController: UISearchController) {
        searchQuery = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        tableView.reloadData()
    }

    /// - Parameters: settings: 已应用的原始设置，按值复制为草稿；onApply: 接收完整草稿，成功返回 nil，失败返回中文原因并保持旧阅读配置。
    /// - Returns: 使用系统分组表格的设置控制器，由宿主放入导航控制器展示。
    init(settings: FullScreenDemoSettings, onApply: @escaping (FullScreenDemoSettings) -> String?) {
        originalSettings = settings
        draft = settings
        self.onApply = onApply
        super.init(style: .insetGrouped)
    }

    /// - Parameter coder: 归档器；此面板只允许显式传入设置，返回 nil。
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 无参数及返回值；配置导航按钮、自动行高和辅助功能标识。
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "阅读设置"
        navigationItem.largeTitleDisplayMode = .never
        let cancel = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancelSettings))
        cancel.accessibilityIdentifier = "settings-cancel"
        navigationItem.leftBarButtonItem = cancel
        let apply = UIBarButtonItem(title: "应用", style: .done, target: self, action: #selector(applySettings))
        apply.accessibilityIdentifier = "settings-apply"
        navigationItem.rightBarButtonItem = apply
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.placeholder = "搜索设置"
        searchController.searchBar.searchTextField.accessibilityIdentifier = "settings-search"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        tableView.accessibilityIdentifier = "reader-settings"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.sectionFooterHeight = UITableView.automaticDimension
        tableView.estimatedSectionFooterHeight = 64
        tableView.backgroundColor = .systemGroupedBackground
    }

    /// - Parameter animated: 是否有出现动画；无返回值，宿主未指定代理时接管侧滑关闭通知。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let presentation = navigationController?.presentationController ?? presentationController
        if presentation?.delegate == nil { presentation?.delegate = self }
    }

    /// - Parameter animated: 是否有消失动画；无返回值，记录整个面板的真实关闭而非压入选项页面。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        notifyOnDisappear = observeSettingsDismissal(of: self) { [weak self] in self?.notifyClosed() }
    }

    /// - Parameter animated: 是否有消失动画；无返回值，为没有转场协调器的关闭补发通知。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if notifyOnDisappear {
            notifyOnDisappear = false
            notifyClosed()
        }
    }

    /// - Parameter presentationController: 已完成关闭的系统展示容器；无返回值，只通知一次。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        notifyClosed()
    }

    // MARK: - 原生表单

    /// - Parameter tableView: 当前表格；返回设置分组数及一组恢复默认入口。
    override func numberOfSections(in tableView: UITableView) -> Int { groups.count + 1 }

    /// - Parameters: tableView: 当前表格；section: 分组索引；返回可操作行数。
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == groups.count ? 1 : groups[section].fields.count
    }

    /// - Parameters: tableView: 当前表格；section: 分组索引；返回中文分组标题。
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == groups.count ? nil : groups[section].title
    }

    /// - Parameters: tableView: 当前表格；section: 分组索引；返回适用范围及草稿说明。
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == groups.count ? "仅重置当前草稿，点击“应用”后才更改阅读页面。" : groups[section].hint
    }

    /// - Parameters: tableView: 当前表格；indexPath: 设置位置；返回支持动态字号和多行中文的系统单元格。
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.section < groups.count else {
            let cell = makeSettingsCell(title: "恢复默认设置", detail: "重置当前草稿", identifier: "setting-resetDefaults")
            var configuration = cell.defaultContentConfiguration()
            configuration.text = "恢复默认设置"
            configuration.secondaryText = "重置当前草稿"
            configuration.textProperties.color = tableView.tintColor
            configureSettingsText(&configuration)
            cell.contentConfiguration = configuration
            cell.accessibilityTraits = .button
            return cell
        }
        let field = groups[indexPath.section].fields[indexPath.row]
        let unavailable = unavailableReason(for: field)
        let hint = [field.hint, unavailable].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let detail = [valueDescription(for: field), hint].filter { !$0.isEmpty }.joined(separator: "\n")
        let cell = makeSettingsCell(title: field.title, detail: detail, identifier: "setting-\(field.name)")
        switch field.input {
        case .toggle(let keyPath):
            let control = UISwitch()
            control.isOn = draft[keyPath: keyPath]
            control.isEnabled = unavailable == nil
            control.accessibilityIdentifier = "setting-\(field.name)"
            control.accessibilityLabel = field.title
            control.accessibilityHint = hint
            control.addAction(UIAction { [weak self] action in
                guard let self, let control = action.sender as? UISwitch else { return }
                self.draft[keyPath: keyPath] = control.isOn
            }, for: .valueChanged)
            cell.accessoryView = control
            cell.selectionStyle = unavailable == nil ? .default : .none
        case .choice, .number, .integer:
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityTraits = .button
        }
        if unavailable != nil, var configuration = cell.contentConfiguration as? UIListContentConfiguration {
            configuration.textProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
        }
        return cell
    }

    /// - Parameters: tableView: 当前表格；indexPath: 点击位置；无返回值，修改草稿或打开原生编辑入口。
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isClosing else { return }
        guard indexPath.section < groups.count else {
            draft = FullScreenDemoSettings()
            tableView.reloadData()
            return
        }
        let field = groups[indexPath.section].fields[indexPath.row]
        guard unavailableReason(for: field) == nil else { return }
        switch field.input {
        case .toggle(let keyPath):
            draft[keyPath: keyPath].toggle()
            (tableView.cellForRow(at: indexPath)?.accessoryView as? UISwitch)?.setOn(draft[keyPath: keyPath], animated: true)
        case .choice(let keyPath, let choices):
            let controller = FullScreenDemoChoiceController(field: field, choices: choices, selected: draft[keyPath: keyPath]) { [weak self] value in
                guard let self else { return }
                self.draft[keyPath: keyPath] = value
                self.tableView.reloadRows(at: [indexPath], with: .none)
            }
            controller.onContainerDismiss = { [weak self] in self?.notifyClosed() }
            navigationController?.pushViewController(controller, animated: true)
        case .number, .integer:
            editNumber(field)
        }
    }
}

// MARK: - 应用、取消和输入验证

private extension FullScreenDemoSettingsController {
    /// 无参数及返回值；完整验证后交给宿主，失败保持草稿和面板。
    @objc func applySettings() {
        guard !isClosing else { return }
        view.endEditing(true)
        if let message = draft.validationMessage() {
            showError(message)
            return
        }
        if let message = onApply(draft) {
            showError(message)
            return
        }
        closeSettings()
    }

    /// 无参数及返回值；丢弃草稿，宿主通过 onClose 释放设置面板的临时暂停原因。
    @objc func cancelSettings() {
        guard !isClosing else { return }
        draft = originalSettings
        closeSettings()
    }

    /// 无参数及返回值；关闭整个展示的导航容器，避免只弹出当前选项页。
    func closeSettings() {
        guard !isClosing else { return }
        isClosing = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.isEnabled = false
        let container: UIViewController = navigationController ?? self
        if container.presentingViewController != nil {
            container.dismiss(animated: true) { [self] in notifyClosed() }
        } else {
            notifyClosed()
        }
    }

    /// 无参数及返回值；按钮关闭、转场回调和系统侧滑共享唯一关闭通知。
    func notifyClosed() {
        guard !didClose else { return }
        didClose = true
        let callback = onClose
        onClose = nil
        callback?()
    }

    /// - Parameter message: 验证或宿主返回的中文原因；无返回值，保留原设置和编辑草稿。
    func showError(_ message: String) {
        let alert = UIAlertController(title: "无法应用设置", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }

    /// - Parameter field: 当前字段；返回不可操作原因，其他模式暂不适用的字段仍可编辑。
    func unavailableReason(for field: Field) -> String? {
        guard field.name == "reservedRegions" else { return nil }
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) { return nil }
        return "当前系统不支持读取保留区域；需 iOS 27.1 或更新版本，阅读页使用系统安全区。"
        #else
        return "当前构建工具链不支持读取保留区域；需支持此能力的工具链及 iOS 27.1，阅读页使用系统安全区。"
        #endif
    }

    /// - Parameter field: 当前字段；返回已保存草稿的中文值，不展示运行状态。
    func valueDescription(for field: Field) -> String {
        switch field.input {
        case .toggle: return ""
        case .choice(let keyPath, let choices):
            return choices.first(where: { $0.value == draft[keyPath: keyPath] })?.title ?? "选项无效，请重新选择"
        case .number(let keyPath, _, let unit):
            return "\(draft[keyPath: keyPath].formatted(.number.precision(.fractionLength(0...8)))) \(unit)".trimmingCharacters(in: .whitespaces)
        case .integer(let keyPath, _, let unit):
            return "\(draft[keyPath: keyPath]) \(unit)".trimmingCharacters(in: .whitespaces)
        }
    }

    /// - Parameter field: 数值字段；无返回值，以系统输入框精确编辑，非法输入保留并解释。
    func editNumber(_ field: Field) {
        let initialText: String
        let limits: String
        switch field.input {
        case .number(let keyPath, let range, let unit):
            initialText = String(draft[keyPath: keyPath])
            limits = "允许范围：\(range.lowerBound)～\(range.upperBound) \(unit)。请输入有限数字。"
        case .integer(let keyPath, let range, let unit):
            initialText = String(draft[keyPath: keyPath])
            limits = "允许范围：\(range.lowerBound)～\(range.upperBound) \(unit)。请输入整数。"
        default: return
        }
        let explanation = [field.hint, limits].filter { !$0.isEmpty }.joined(separator: "\n")
        let alert = UIAlertController(title: field.title, message: explanation, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = initialText
            textField.accessibilityIdentifier = "number-\(field.name)"
            textField.accessibilityLabel = field.title
            textField.keyboardType = .numbersAndPunctuation
            textField.autocorrectionType = .no
            textField.spellCheckingType = .no
            textField.font = .preferredFont(forTextStyle: .body)
            textField.adjustsFontForContentSizeCategory = true
            textField.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        let save = UIAlertAction(title: "确定", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text else { return }
            if let error = self.updateNumber(text, field: field, commit: true) {
                // 禁用的按钮不会进入此分支；仍保留旧值并说明重新校验失败的原因。
                alert?.message = explanation + "\n" + error
                return
            }
            self.tableView.reloadData()
        }
        alert.addAction(save)
        if let textField = alert.textFields?.first {
            let error = updateNumber(initialText, field: field, commit: false)
            save.isEnabled = error == nil
            if let error { alert.message = explanation + "\n" + error }
            textField.addAction(UIAction { [weak self, weak alert, weak save] action in
                guard let self, let textField = action.sender as? UITextField else { return }
                let error = self.updateNumber(textField.text ?? "", field: field, commit: false)
                save?.isEnabled = error == nil
                alert?.message = error.map { explanation + "\n" + $0 } ?? explanation
            }, for: .editingChanged)
        }
        present(alert, animated: true)
    }

    /// - Parameters: text: 完整输入文本；field: 数值字段；commit: 是否写入草稿。
    /// - Returns: 非法输入的中文原因，合法时返回 nil；不截断字符串、不钳制值、不保存非有限数。
    func updateNumber(_ text: String, field: Field, commit: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.input {
        case .number(let keyPath, let range, _):
            let separator = Locale.current.decimalSeparator ?? "."
            let normalized = separator == "." ? trimmed : trimmed.replacingOccurrences(of: separator, with: ".")
            guard let value = Double(normalized), value.isFinite else { return "请输入完整的有限数字，不能留空或输入非数字。" }
            guard range.contains(value) else { return "数值超出允许范围，请修改后再确定。" }
            if commit { draft[keyPath: keyPath] = value }
        case .integer(let keyPath, let range, _):
            guard let value = Int(trimmed) else { return "请输入完整整数，不能包含小数或其他字符。" }
            guard range.contains(value) else { return "整数超出允许范围，请修改后再确定。" }
            if commit { draft[keyPath: keyPath] = value }
        default: return "此选项不是数值输入。"
        }
        return nil
    }
}

// MARK: - 选项列表

@MainActor
private final class FullScreenDemoChoiceController: UITableViewController {
    var onContainerDismiss: (() -> Void)?
    private let field: FullScreenDemoSettings.Field
    private let choices: [FullScreenDemoSettings.Choice]
    private let onSelect: (String) -> Void
    private var selected: String
    private var notifyOnDisappear = false

    /// - Parameters: field: 字段定义；choices: 允许的中文选项；selected: 当前草稿值；onSelect: 保存选择的回调；无返回值。
    init(field: FullScreenDemoSettings.Field, choices: [FullScreenDemoSettings.Choice], selected: String,
         onSelect: @escaping (String) -> Void) {
        self.field = field
        self.choices = choices
        self.selected = selected
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
    }

    /// - Parameter coder: 归档器；不支持归档构造，返回 nil。
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 无参数及返回值；设置标题、多行自适应行高和辅助功能标识。
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = field.title
        tableView.accessibilityIdentifier = "choices-\(field.name)"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.sectionFooterHeight = UITableView.automaticDimension
        tableView.estimatedSectionFooterHeight = 64
    }

    /// - Parameter animated: 是否有转场动画；无返回值，选项页处于顶层时仍观察面板关闭。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        notifyOnDisappear = observeSettingsDismissal(of: self) { [weak self] in self?.onContainerDismiss?() }
    }

    /// - Parameter animated: 是否有转场动画；无返回值，为无协调器的关闭补发通知。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if notifyOnDisappear {
            notifyOnDisappear = false
            onContainerDismiss?()
        }
    }

    /// - Parameters: tableView: 当前表格；section: 分组索引；返回允许的选项数。
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { choices.count }

    /// - Parameters: tableView: 当前表格；section: 分组索引；返回当前字段的适用说明。
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { field.hint }

    /// - Parameters: tableView: 当前表格；indexPath: 选项位置；返回中文选项及当前值勾选状态。
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let choice = choices[indexPath.row]
        let cell = makeSettingsCell(title: choice.title, detail: "", identifier: "choice-\(field.name)-\(choice.value)")
        cell.accessoryType = selected == choice.value ? .checkmark : .none
        cell.accessibilityTraits = selected == choice.value ? [.button, .selected] : .button
        return cell
    }

    /// - Parameters: tableView: 当前表格；indexPath: 选中位置；无返回值，保存草稿选项并返回设置表。
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selected = choices[indexPath.row].value
        onSelect(selected)
        tableView.reloadData()
        navigationController?.popViewController(animated: true)
    }
}

// MARK: - 原生显示与关闭观察

/// - Parameters: title: 中文标题；detail: 值及说明；identifier: 稳定辅助功能标识。
/// - Returns: 使用系统动态颜色、动态字号和至少 44 点点击区域的多行单元格。
@MainActor
private func makeSettingsCell(title: String, detail: String, identifier: String) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    var configuration = cell.defaultContentConfiguration()
    configuration.text = title
    configuration.secondaryText = detail.isEmpty ? nil : detail
    configureSettingsText(&configuration)
    cell.contentConfiguration = configuration
    cell.accessibilityIdentifier = identifier
    cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    return cell
}

/// - Parameter configuration: 要更新的系统文字配置；无返回值，允许长中文和辅助功能大字号换行。
@MainActor
private func configureSettingsText(_ configuration: inout UIListContentConfiguration) {
    configuration.textProperties.font = .preferredFont(forTextStyle: .body)
    configuration.textProperties.adjustsFontForContentSizeCategory = true
    configuration.textProperties.numberOfLines = 0
    configuration.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
    configuration.secondaryTextProperties.adjustsFontForContentSizeCategory = true
    configuration.secondaryTextProperties.numberOfLines = 0
    configuration.secondaryTextProperties.color = .secondaryLabel
}

/// - Parameters: controller: 即将消失的设置或选项控制器；completion: 面板确认关闭后的回调。
/// - Returns: 是否需要在 viewDidDisappear 中补发回调；取消的交互式关闭不会通知宿主。
@MainActor
private func observeSettingsDismissal(of controller: UIViewController, completion: @escaping () -> Void) -> Bool {
    guard controller.isBeingDismissed || controller.navigationController?.isBeingDismissed == true else { return false }
    guard let coordinator = controller.transitionCoordinator else { return true }
    let registered = coordinator.animate(alongsideTransition: nil) { context in
        if !context.isCancelled { completion() }
    }
    return !registered
}
