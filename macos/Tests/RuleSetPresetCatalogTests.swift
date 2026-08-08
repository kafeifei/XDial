import XCTest

final class RuleSetPresetCatalogTests: XCTestCase {
    func testDecodesOnePrivateCatalogWithInvertedPreset() throws {
        let data = Data("""
        {
          "schema_version": 1,
          "presets": [
            {
              "id": "blank",
              "name_zh": "空白",
              "name_en": "Blank",
              "url": "",
              "format": "auto"
            },
            {
              "id": "outside",
              "name_zh": "列表之外",
              "name_en": "Outside",
              "url": "https://rules.example/list.srs",
              "format": "srs",
              "invert": true
            }
          ]
        }
        """.utf8)

        let catalog = try RuleSetPresetCatalog.decode(data)

        XCTAssertEqual(catalog.presets.count, 2)
        XCTAssertFalse(catalog.presets[0].invert)
        XCTAssertTrue(catalog.presets[1].invert)
    }

    func testRejectsDuplicateIDs() {
        let data = Data("""
        {
          "schema_version": 1,
          "presets": [
            {
              "id": "same",
              "name_zh": "一",
              "name_en": "One",
              "format": "auto"
            },
            {
              "id": "same",
              "name_zh": "二",
              "name_en": "Two",
              "format": "auto"
            }
          ]
        }
        """.utf8)

        XCTAssertThrowsError(try RuleSetPresetCatalog.decode(data))
    }
}
