import Foundation
import JSONUtilities
import PathKit
import ProjectSpec
import XcodeProj
import Yams

extension Project {
    public func getProjectBuildSettings(config: Config) -> BuildSettings {
        var buildSettings: BuildSettings = [:]

        // set project SDKROOT is a single platform
        if let firstPlatform = targets.first?.platform,
           targets.allSatisfy({ $0.platform == firstPlatform })
        {
            buildSettings["SDKROOT"] = .string(firstPlatform.sdkRoot)
        }

        if let type = config.type, options.settingPresets.applyProject {
            buildSettings += SettingsPresetFile.base.getBuildSettings()
            buildSettings += SettingsPresetFile.config(type).getBuildSettings()
        }

        // apply custom platform version
        for platform in Platform.allCases {
            if let version = options.deploymentTarget.version(for: platform) {
                buildSettings[platform.deploymentTargetSetting] = .string(version.deploymentTarget)
            }
        }

        // Prevent setting presets from overwriting settings in project xcconfig files
        if let configPath = configFiles[config.name] {
            buildSettings = removeConfigFileSettings(from: buildSettings, configPath: configPath)
        }

        buildSettings += getBuildSettings(settings: settings, config: config)

        return buildSettings
    }

    public func getTargetBuildSettings(target: Target, config: Config) -> BuildSettings {
        var buildSettings = BuildSettings()
        
        // list of supported destination sorted by priority
        let specSupportedDestinations = target.supportedDestinations?.sorted(by: { $0.priority < $1.priority }) ?? []
        
        if options.settingPresets.applyTarget {
            let platform: Platform
            
            if target.platform == .auto,
               let firstDestination = specSupportedDestinations.first,
               let firstDestinationPlatform = Platform(rawValue: firstDestination.rawValue) {
                
                platform = firstDestinationPlatform
            } else {
                platform = target.platform
            }
            
            buildSettings += SettingsPresetFile.platform(platform).getBuildSettings()
            buildSettings += SettingsPresetFile.product(target.type).getBuildSettings()
            buildSettings += SettingsPresetFile.productPlatform(target.type, platform).getBuildSettings()
            
            if target.platform == .auto {
                // this fix is necessary because the platform preset overrides the original value
                buildSettings["SDKROOT"] = .string(Platform.auto.rawValue)
            }
            
            if !specSupportedDestinations.isEmpty {
                var supportedPlatforms: [String] = []
                var targetedDeviceFamily: [String] = []
                
                for supportedDestination in specSupportedDestinations {
                    let supportedPlatformBuildSettings = SettingsPresetFile.supportedDestination(supportedDestination).getBuildSettings()
                    buildSettings += supportedPlatformBuildSettings
                    
                    if let value = supportedPlatformBuildSettings?["SUPPORTED_PLATFORMS"]?.stringValue {
                        supportedPlatforms += value.components(separatedBy: " ")
                    }
                    if let value = supportedPlatformBuildSettings?["TARGETED_DEVICE_FAMILY"]?.stringValue {
                        targetedDeviceFamily += value.components(separatedBy: ",")
                    }
                }
                
                buildSettings["SUPPORTED_PLATFORMS"] = .string(supportedPlatforms.joined(separator: " "))
                buildSettings["TARGETED_DEVICE_FAMILY"] = .string(targetedDeviceFamily.joined(separator: ","))
            }
        }
        
        // apply custom platform version
        if let version = target.deploymentTarget {
            if !specSupportedDestinations.isEmpty {
                for supportedDestination in specSupportedDestinations {
                    if let platform = Platform(rawValue: supportedDestination.rawValue) {
                        buildSettings[platform.deploymentTargetSetting] = .string(version.deploymentTarget)
                    }
                }
            } else {
                buildSettings[target.platform.deploymentTargetSetting] = .string(version.deploymentTarget)
            }
        }

        // Prevent setting presets from overrwriting settings in target xcconfig files
        if let configPath = target.configFiles[config.name] {
            buildSettings = removeConfigFileSettings(from: buildSettings, configPath: configPath)
        }
        // Prevent setting presets from overrwriting settings in project xcconfig files
        if let configPath = configFiles[config.name] {
            buildSettings = removeConfigFileSettings(from: buildSettings, configPath: configPath)
        }

        buildSettings += getBuildSettings(settings: target.settings, config: config)

        return buildSettings
    }

    public func getBuildSettings(settings: Settings, config: Config) -> BuildSettings {
        var buildSettings: BuildSettings = [:]

        for group in settings.groups {
            if let settings = settingGroups[group] {
                buildSettings += getBuildSettings(settings: settings, config: config)
            }
        }

        buildSettings += settings.buildSettings

        for (configVariant, settings) in settings.configSettings {
            let isPartialMatch = config.name.lowercased().contains(configVariant.lowercased())
            if isPartialMatch {
                let exactConfig = getConfig(configVariant)
                let matchesExactlyToOtherConfig = exactConfig != nil && exactConfig?.name != config.name
                if !matchesExactlyToOtherConfig {
                    buildSettings += getBuildSettings(settings: settings, config: config)
                }
            }
        }

        return buildSettings
    }

    // combines all levels of a target's settings: target, target config, project, project config
    public func getCombinedBuildSetting(_ setting: String, target: ProjectTarget, config: Config) -> BuildSetting? {
        if let target = target as? Target,
            let value = getTargetBuildSettings(target: target, config: config)[setting] {
            return value
        }
        if let configFilePath = target.configFiles[config.name],
            let value = loadConfigFileBuildSettings(path: configFilePath)?[setting] {
            return value
        }
        if let value = getProjectBuildSettings(config: config)[setting] {
            return value
        }
        if let configFilePath = configFiles[config.name],
            let value = loadConfigFileBuildSettings(path: configFilePath)?[setting] {
            return value
        }
        return nil
    }

    public func getBoolBuildSetting(_ setting: String, target: ProjectTarget, config: Config) -> Bool? {
        getCombinedBuildSetting(setting, target: target, config: config)?.boolValue
    }

    public func targetHasBuildSetting(_ setting: String, target: Target, config: Config) -> Bool {
        getCombinedBuildSetting(setting, target: target, config: config) != nil
    }

    /// Removes values from build settings if they are defined in an xcconfig file
    private func removeConfigFileSettings(from buildSettings: BuildSettings, configPath: String) -> BuildSettings {
        var buildSettings = buildSettings

        if let configSettings = loadConfigFileBuildSettings(path: configPath) {
            for key in configSettings.keys {
                // FIXME: Catch platform specifier. e.g. LD_RUNPATH_SEARCH_PATHS[sdk=iphone*]
                buildSettings.removeValue(forKey: key)
                buildSettings.removeValue(forKey: key.quoted)
            }
        }

        return buildSettings
    }

    /// Returns cached build settings from a config file
    private func loadConfigFileBuildSettings(path: String) -> BuildSettings? {
        let configFilePath = basePath + path
        if let cached = configFileSettings[configFilePath.string] {
            return cached.value
        } else {
            guard let configFile = try? XCConfig(path: configFilePath) else {
                configFileSettings[configFilePath.string] = .nothing
                return nil
            }
            let settings = configFile.flattenedBuildSettings()
            configFileSettings[configFilePath.string] = .cached(settings)
            return settings
        }
    }
}

private enum Cached<T> {
    case cached(T)
    case nothing

    var value: T? {
        switch self {
        case let .cached(value): return value
        case .nothing: return nil
        }
    }
}

// cached flattened xcconfig file settings
private var configFileSettings: [String: Cached<BuildSettings>] = [:]

// cached setting preset settings
private var settingPresetSettings: [String: Cached<BuildSettings>] = [:]

let embeddedSettingPresets: [String: String] = [
    "Product_Platform/application_macOS": "ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n",
    "Product_Platform/application_visionOS": "ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n",
    "Product_Platform/app-extension_macOS": "LD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/../Frameworks\", \"@executable_path/../../../../Frameworks\"]\n",
    "Product_Platform/application_tvOS": "ASSETCATALOG_COMPILER_APPICON_NAME: App Icon & Top Shelf Image\nASSETCATALOG_COMPILER_LAUNCHIMAGE_NAME: LaunchImage\n",
    "Product_Platform/application_iOS": "CODE_SIGN_IDENTITY: iPhone Developer\nASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n",
    "Product_Platform/application_watchOS": "ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n",
    "Product_Platform/bundle.unit-test_macOS": "LD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/../Frameworks\", \"@loader_path/../Frameworks\"]\n",
    "Configs/release": "---\n# Settings take from the following file and sorted\n# /Applications/Xcode.app/Contents/Developer/Library/Xcode/Templates/Project Templates/Base/Base_ProjectSettings.xctemplate/TemplateInfo.plist\nDEBUG_INFORMATION_FORMAT: dwarf-with-dsym\nENABLE_NS_ASSERTIONS: NO\nMTL_ENABLE_DEBUG_INFO: NO\n\n# Swift Settings\nSWIFT_COMPILATION_MODE: wholemodule\nSWIFT_OPTIMIZATION_LEVEL: -O\n",
    "Configs/debug": "---\n# Settings take from the following file and sorted\n# /Applications/Xcode.app/Contents/Developer/Library/Xcode/Templates/Project Templates/Base/Base_ProjectSettings.xctemplate/TemplateInfo.plist\nDEBUG_INFORMATION_FORMAT: dwarf\nENABLE_TESTABILITY: YES\nGCC_DYNAMIC_NO_PIC: NO\nGCC_OPTIMIZATION_LEVEL: '0'\nGCC_PREPROCESSOR_DEFINITIONS: [\"$(inherited)\", \"DEBUG=1\"]\nMTL_ENABLE_DEBUG_INFO: INCLUDE_SOURCE\nONLY_ACTIVE_ARCH: YES\n\n# Swift Settings\nSWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG\nSWIFT_OPTIMIZATION_LEVEL: -Onone\n",
    "Platforms/tvOS": "LD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/Frameworks\"]\nSDKROOT: appletvos\nTARGETED_DEVICE_FAMILY: 3\n",
    "Platforms/watchOS": "SDKROOT: watchos\nSKIP_INSTALL: 'YES'\nTARGETED_DEVICE_FAMILY: 4\n",
    "Platforms/visionOS": "LD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/Frameworks\"]\nSDKROOT: xros\nTARGETED_DEVICE_FAMILY: 7\n",
    "Platforms/iOS": "LD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/Frameworks\"]\nSDKROOT: iphoneos\nTARGETED_DEVICE_FAMILY: '1,2'\n",
    "Platforms/macOS": "LD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/../Frameworks\"]\nSDKROOT: macosx\nCOMBINE_HIDPI_IMAGES: 'YES'\n",
    "base": "---\n# Settings take from the following file and sorted\n# /Applications/Xcode.app/Contents/Developer/Library/Xcode/Templates/Project Templates/Base/Base_ProjectSettings.xctemplate/TemplateInfo.plist\nALWAYS_SEARCH_USER_PATHS: NO\nCLANG_ANALYZER_NONNULL: YES\nCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION: YES_AGGRESSIVE\nCLANG_CXX_LANGUAGE_STANDARD: gnu++14\nCLANG_CXX_LIBRARY: libc++\nCLANG_ENABLE_MODULES: YES\nCLANG_ENABLE_OBJC_ARC: YES\nCLANG_ENABLE_OBJC_WEAK: YES\nCLANG_WARN_BLOCK_CAPTURE_AUTORELEASING: YES\nCLANG_WARN_BOOL_CONVERSION: YES\nCLANG_WARN_COMMA: YES\nCLANG_WARN_CONSTANT_CONVERSION: YES\nCLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS: YES\nCLANG_WARN_DIRECT_OBJC_ISA_USAGE: YES_ERROR\nCLANG_WARN_DOCUMENTATION_COMMENTS: YES\nCLANG_WARN_EMPTY_BODY: YES\nCLANG_WARN_ENUM_CONVERSION: YES\nCLANG_WARN_INFINITE_RECURSION: YES\nCLANG_WARN_INT_CONVERSION: YES\nCLANG_WARN_NON_LITERAL_NULL_CONVERSION: YES\nCLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF: YES\nCLANG_WARN_OBJC_LITERAL_CONVERSION: YES\nCLANG_WARN_OBJC_ROOT_CLASS: YES_ERROR\nCLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER: YES\nCLANG_WARN_RANGE_LOOP_ANALYSIS: YES\nCLANG_WARN_STRICT_PROTOTYPES: YES\nCLANG_WARN_SUSPICIOUS_MOVE: YES\nCLANG_WARN_UNGUARDED_AVAILABILITY: YES_AGGRESSIVE\nCLANG_WARN_UNREACHABLE_CODE: YES\nCLANG_WARN__DUPLICATE_METHOD_MATCH: YES\nCOPY_PHASE_STRIP: NO\nENABLE_STRICT_OBJC_MSGSEND: YES\nGCC_C_LANGUAGE_STANDARD: gnu11\nGCC_NO_COMMON_BLOCKS: YES\nGCC_WARN_64_TO_32_BIT_CONVERSION: YES\nGCC_WARN_ABOUT_RETURN_TYPE: YES_ERROR\nGCC_WARN_UNDECLARED_SELECTOR: YES\nGCC_WARN_UNINITIALIZED_AUTOS: YES_AGGRESSIVE\nGCC_WARN_UNUSED_FUNCTION: YES\nGCC_WARN_UNUSED_VARIABLE: YES\nMTL_FAST_MATH: YES\n\n# Target Settings\nPRODUCT_NAME: $(TARGET_NAME)\n\n# Swift Settings\nSWIFT_VERSION: '5.0'\n",
    "SupportedDestinations/tvOS": "SUPPORTED_PLATFORMS: appletvos appletvsimulator\nTARGETED_DEVICE_FAMILY: '3'\n",
    "SupportedDestinations/watchOS": "SUPPORTED_PLATFORMS: watchos watchsimulator\nTARGETED_DEVICE_FAMILY: '4'\n",
    "SupportedDestinations/visionOS": "SUPPORTED_PLATFORMS: xros xrsimulator\nTARGETED_DEVICE_FAMILY: '7'\nSUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD: NO\n",
    "SupportedDestinations/iOS": "SUPPORTED_PLATFORMS: iphoneos iphonesimulator\nTARGETED_DEVICE_FAMILY: '1,2'\nSUPPORTS_MACCATALYST: NO\nSUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: YES\nSUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD: YES\n",
    "SupportedDestinations/macOS": "SUPPORTED_PLATFORMS: macosx\nSUPPORTS_MACCATALYST: NO\nSUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO\n",
    "SupportedDestinations/macCatalyst": "SUPPORTS_MACCATALYST: YES\nSUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO\n",
    "Products/watchkit2-extension": "LD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/Frameworks\", \"@executable_path/../../Frameworks\"]\nASSETCATALOG_COMPILER_COMPLICATION_NAME: Complication\n",
    "Products/framework.static": "CURRENT_PROJECT_VERSION: 1\nDEFINES_MODULE: 'YES'\nCODE_SIGN_IDENTITY: \"\"\nDYLIB_COMPATIBILITY_VERSION: 1\nDYLIB_CURRENT_VERSION: 1\nVERSIONING_SYSTEM: \"apple-generic\"\nINSTALL_PATH: \"$(LOCAL_LIBRARY_DIR)/Frameworks\"\nDYLIB_INSTALL_NAME_BASE: \"@rpath\"\nSKIP_INSTALL: 'YES'\n",
    "Products/tv-app-extension": "SKIP_INSTALL: 'YES'\nLD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/Frameworks\", \"@executable_path/../../Frameworks\"]\n",
    "Products/app-extension.intents-service": "LD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/Frameworks\", \"@executable_path/../../Frameworks\", \"@executable_path/../../../../Frameworks\"]\n",
    "Products/bundle.ui-testing": "BUNDLE_LOADER: $(TEST_HOST)\nLD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/Frameworks\", \"@loader_path/Frameworks\"]\n",
    "Products/framework": "CURRENT_PROJECT_VERSION: 1\nDEFINES_MODULE: 'YES'\nCODE_SIGN_IDENTITY: \"\"\nDYLIB_COMPATIBILITY_VERSION: 1\nDYLIB_CURRENT_VERSION: 1\nVERSIONING_SYSTEM: \"apple-generic\"\nINSTALL_PATH: \"$(LOCAL_LIBRARY_DIR)/Frameworks\"\nDYLIB_INSTALL_NAME_BASE: \"@rpath\"\nSKIP_INSTALL: 'YES'\n",
    "Products/app-extension": "LD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/Frameworks\", \"@executable_path/../../Frameworks\"]\n",
    "Products/library.static": "SKIP_INSTALL: 'YES'\n",
    "Products/app-extension.messages": "ASSETCATALOG_COMPILER_APPICON_NAME: iMessage App Icon\nLD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/Frameworks\", \"@executable_path/../../Frameworks\"]\n",
    "Products/bundle.unit-test": "BUNDLE_LOADER: $(TEST_HOST)\nLD_RUNPATH_SEARCH_PATHS: [\"$(inherited)\", \"@executable_path/Frameworks\", \"@loader_path/Frameworks\"]\n"
]

extension SettingsPresetFile {
    public func getBuildSettings() -> BuildSettings? {
        if let cached = settingPresetSettings[path] {
            return cached.value
        }

        guard let yaml = embeddedSettingPresets[path] else {
            switch self {
            case .base, .config, .platform, .supportedDestination:
                print("No \"\(name)\" settings found")
            case .product, .productPlatform:
                break
            }
            settingPresetSettings[path] = .nothing
            return nil
        }

        guard let dictionary = try? loadYamlDictionary(contents: yaml) else {
            print("Error parsing \"\(name)\" settings")
            return nil
        }
        let buildSettings: BuildSettings = dictionary.mapValues { BuildSetting(any: $0) }
        settingPresetSettings[path] = .cached(buildSettings)
        return buildSettings
    }
}