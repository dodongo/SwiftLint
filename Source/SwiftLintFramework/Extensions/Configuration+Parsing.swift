extension Configuration {
    private enum Key: String {
        case cachePath = "cache_path"
        case disabledRules = "disabled_rules"
        case enabledRules = "enabled_rules" // deprecated in favor of optInRules
        case excluded = "excluded"
        case included = "included"
        case optInRules = "opt_in_rules"
        case reporter = "reporter"
        case swiftlintVersion = "swiftlint_version"
        case useNestedConfigs = "use_nested_configs" // deprecated
        case warningThreshold = "warning_threshold"
        case whitelistRules = "whitelist_rules"
        case indentation = "indentation"
        case analyzerRules = "analyzer_rules"
        case plugins = "plugins"
    }

    private static func validKeys(ruleList: RuleList, remoteRules: [RemoteRule]) -> [String] {
        return [
            Key.cachePath,
            .disabledRules,
            .enabledRules,
            .excluded,
            .included,
            .optInRules,
            .reporter,
            .swiftlintVersion,
            .useNestedConfigs,
            .warningThreshold,
            .whitelistRules,
            .indentation,
            .analyzerRules,
            .plugins
        ].map({ $0.rawValue }) + ruleList.allValidIdentifiers() + remoteRules.flatMap { $0.description.allIdentifiers }
    }

    private static func getIndentationLogIfInvalid(from dict: [String: Any]) -> IndentationStyle {
        if let rawIndentation = dict[Key.indentation.rawValue] {
            if let indentationStyle = Configuration.IndentationStyle(rawIndentation) {
                return indentationStyle
            }

            queuedPrintError("Invalid configuration for '\(Key.indentation)'. Falling back to default.")
            return .default
        }

        return .default
    }

    public init?(dict: [String: Any], ruleList: RuleList = masterRuleList, enableAllRules: Bool = false,
                 cachePath: String? = nil) {
        // Use either new 'opt_in_rules' or deprecated 'enabled_rules' for now.
        let optInRules = defaultStringArray(
            dict[Key.optInRules.rawValue] ?? dict[Key.enabledRules.rawValue]
        )

        let plugins = defaultStringArray(dict[Key.plugins.rawValue])
        let resolver = RemoteRuleResolver()
        let remoteRules = plugins.compactMap {
            try? resolver.remoteRule(forExecutable: $0, configuration: dict)
        }

        Configuration.validateConfigurationKeys(dict: dict, ruleList: ruleList, remoteRules: remoteRules)

        let disabledRules = defaultStringArray(dict[Key.disabledRules.rawValue])
        let whitelistRules = defaultStringArray(dict[Key.whitelistRules.rawValue])
        let analyzerRules = defaultStringArray(dict[Key.analyzerRules.rawValue])
        let included = defaultStringArray(dict[Key.included.rawValue])
        let excluded = defaultStringArray(dict[Key.excluded.rawValue])
        let indentation = Configuration.getIndentationLogIfInvalid(from: dict)

        Configuration.warnAboutDeprecations(configurationDictionary: dict, disabledRules: disabledRules,
                                            optInRules: optInRules, whitelistRules: whitelistRules, ruleList: ruleList)

        let configuredRules: [Rule]
        do {
            configuredRules = try ruleList.configuredRules(with: dict)
        } catch RuleListError.duplicatedConfigurations(let ruleType) {
            Configuration.warnAboutDuplicateConfigurations(for: ruleType)
            return nil
        } catch {
            return nil
        }

        let swiftlintVersion = dict[Key.swiftlintVersion.rawValue].map { ($0 as? String) ?? String(describing: $0) }
        self.init(disabledRules: disabledRules,
                  optInRules: optInRules,
                  enableAllRules: enableAllRules,
                  whitelistRules: whitelistRules,
                  analyzerRules: analyzerRules,
                  included: included,
                  excluded: excluded,
                  warningThreshold: dict[Key.warningThreshold.rawValue] as? Int,
                  reporter: dict[Key.reporter.rawValue] as? String ?? XcodeReporter.identifier,
                  ruleList: ruleList,
                  configuredRules: configuredRules,
                  swiftlintVersion: swiftlintVersion,
                  cachePath: cachePath ?? dict[Key.cachePath.rawValue] as? String,
                  indentation: indentation,
                  plugins: plugins,
                  remoteRules: remoteRules)
    }

    private init?(disabledRules: [String],
                  optInRules: [String],
                  enableAllRules: Bool,
                  whitelistRules: [String],
                  analyzerRules: [String],
                  included: [String],
                  excluded: [String],
                  warningThreshold: Int?,
                  reporter: String = XcodeReporter.identifier,
                  ruleList: RuleList = masterRuleList,
                  configuredRules: [Rule]?,
                  swiftlintVersion: String?,
                  cachePath: String?,
                  indentation: IndentationStyle,
                  plugins: [String],
                  remoteRules: [RemoteRule]) {
        let rulesMode: RulesMode
        if enableAllRules {
            rulesMode = .allEnabled
        } else if !whitelistRules.isEmpty {
            if !disabledRules.isEmpty || !optInRules.isEmpty {
                queuedPrintError("'\(Key.disabledRules.rawValue)' or " +
                    "'\(Key.optInRules.rawValue)' cannot be used in combination " +
                    "with '\(Key.whitelistRules.rawValue)'")
                return nil
            }
            rulesMode = .whitelisted(whitelistRules + analyzerRules)
        } else {
            rulesMode = .default(disabled: disabledRules, optIn: optInRules + analyzerRules)
        }

        self.init(rulesMode: rulesMode,
                  included: included,
                  excluded: excluded,
                  warningThreshold: warningThreshold,
                  reporter: reporter,
                  ruleList: ruleList,
                  configuredRules: configuredRules,
                  swiftlintVersion: swiftlintVersion,
                  cachePath: cachePath,
                  indentation: indentation,
                  plugins: plugins,
                  remoteRules: remoteRules)
    }

    private static func warnAboutDeprecations(configurationDictionary dict: [String: Any],
                                              disabledRules: [String] = [],
                                              optInRules: [String] = [],
                                              whitelistRules: [String] = [],
                                              ruleList: RuleList) {
        // Deprecation warning for "enabled_rules"
        if dict[Key.enabledRules.rawValue] != nil {
            queuedPrintError("'\(Key.enabledRules.rawValue)' has been renamed to " +
                "'\(Key.optInRules.rawValue)' and will be completely removed in a " +
                "future release.")
        }

        // Deprecation warning for "use_nested_configs"
        if dict[Key.useNestedConfigs.rawValue] != nil {
            queuedPrintError("Support for '\(Key.useNestedConfigs.rawValue)' has " +
                "been deprecated and its value is now ignored. Nested configuration files are " +
                "now always considered.")
        }

        // Deprecation warning for rules
        let deprecatedRulesIdentifiers = ruleList.list.flatMap { identifier, rule -> [(String, String)] in
            return rule.description.deprecatedAliases.map { ($0, identifier) }
        }

        let userProvidedRuleIDs = Set(disabledRules + optInRules + whitelistRules)
        let deprecatedUsages = deprecatedRulesIdentifiers.filter { deprecatedIdentifier, _ in
            return dict[deprecatedIdentifier] != nil || userProvidedRuleIDs.contains(deprecatedIdentifier)
        }

        for (deprecatedIdentifier, identifier) in deprecatedUsages {
            queuedPrintError("'\(deprecatedIdentifier)' rule has been renamed to '\(identifier)' and will be " +
                "completely removed in a future release.")
        }
    }

    private static func warnAboutDuplicateConfigurations(for ruleType: Rule.Type) {
        let aliases = ruleType.description.deprecatedAliases.map { "'\($0)'" }.joined(separator: ", ")
        let identifier = ruleType.description.identifier
        queuedPrintError("Multiple configurations found for '\(identifier)'. Check for any aliases: \(aliases).")
    }

    private static func validateConfigurationKeys(dict: [String: Any], ruleList: RuleList, remoteRules: [RemoteRule]) {
        // Log an error when supplying invalid keys in the configuration dictionary
        let invalidKeys = Set(dict.keys).subtracting(validKeys(ruleList: ruleList,
                                                               remoteRules: remoteRules))
        if !invalidKeys.isEmpty {
            queuedPrintError("Configuration contains invalid keys:\n\(invalidKeys)")
        }
    }
}

private func defaultStringArray(_ object: Any?) -> [String] {
    return [String].array(of: object) ?? []
}
