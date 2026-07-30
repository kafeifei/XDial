import Foundation

struct RuleSetPreset: Codable, Equatable, Identifiable {
    let id: String
    let nameZH: String
    let nameEN: String
    let url: String
    let format: String
    let invert: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case nameZH = "name_zh"
        case nameEN = "name_en"
        case url
        case format
        case invert
    }

    init(
        id: String,
        nameZH: String,
        nameEN: String,
        url: String,
        format: String,
        invert: Bool = false
    ) {
        self.id = id
        self.nameZH = nameZH
        self.nameEN = nameEN
        self.url = url
        self.format = format
        self.invert = invert
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        nameZH = try values.decode(String.self, forKey: .nameZH)
        nameEN = try values.decode(String.self, forKey: .nameEN)
        url = try values.decodeIfPresent(
            String.self,
            forKey: .url
        ) ?? ""
        format = try values.decodeIfPresent(
            String.self,
            forKey: .format
        ) ?? "auto"
        invert = try values.decodeIfPresent(
            Bool.self,
            forKey: .invert
        ) ?? false
    }
}

struct RuleSetPresetCatalog: Codable, Equatable {
    let schemaVersion: Int
    let presets: [RuleSetPreset]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case presets
    }

    static let fallback = RuleSetPresetCatalog(
        schemaVersion: 1,
        presets: [
            RuleSetPreset(
                id: "blank",
                nameZH: "空白配置",
                nameEN: "Blank",
                url: "",
                format: "auto"
            ),
        ]
    )

    static func load(bundle: Bundle = .main) -> RuleSetPresetCatalog {
        guard
            let url = bundle.url(
                forResource: "RuleSetPresets",
                withExtension: "json"
            ),
            let data = try? Data(contentsOf: url),
            let catalog = try? decode(data)
        else {
            return fallback
        }
        return catalog
    }

    static func decode(_ data: Data) throws -> RuleSetPresetCatalog {
        let catalog = try JSONDecoder().decode(
            RuleSetPresetCatalog.self,
            from: data
        )
        guard catalog.schemaVersion == 1 else {
            throw CatalogError.unsupportedSchema(catalog.schemaVersion)
        }
        guard !catalog.presets.isEmpty else {
            throw CatalogError.empty
        }

        var seen = Set<String>()
        for preset in catalog.presets {
            guard !preset.id.isEmpty, seen.insert(preset.id).inserted else {
                throw CatalogError.duplicateOrEmptyID(preset.id)
            }
            guard ["auto", "srs", "json", "text"].contains(preset.format) else {
                throw CatalogError.unsupportedFormat(preset.format)
            }
        }
        return catalog
    }

    enum CatalogError: LocalizedError {
        case unsupportedSchema(Int)
        case empty
        case duplicateOrEmptyID(String)
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchema(version):
                return "Unsupported RuleSet preset schema \(version)"
            case .empty:
                return "RuleSet preset catalog is empty"
            case let .duplicateOrEmptyID(id):
                return "Duplicate or empty RuleSet preset id: \(id)"
            case let .unsupportedFormat(format):
                return "Unsupported RuleSet preset format: \(format)"
            }
        }
    }
}
