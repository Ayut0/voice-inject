import XCTest
@testable import VoiceInject

final class ConfigSublineTests: XCTestCase {
    func testFormatsEnglishModelWithMaxAndSilence() {
        let cfg = DaemonConfig(lang: "en", model: "/x/ggml-base.en.bin", minRecordMs: 700, maxRecordMs: 45_000, silenceTimeoutMs: 3_000, minTextLength: 3, maxTextLength: 5_000, camelCaseRule: false, maxSymbolRatio: 0.5)
        XCTAssertEqual(configSubline(cfg), "base (English) · max 45s · silence 3s")
    }

    func testFormatsCustomModelName() {
        let cfg = DaemonConfig(lang: "ja", model: "/x/my-custom-model.bin", minRecordMs: 700, maxRecordMs: 60_000, silenceTimeoutMs: 4_000, minTextLength: 3, maxTextLength: 5_000, camelCaseRule: false, maxSymbolRatio: 0.5)
        XCTAssertEqual(configSubline(cfg), "my-custom-model · max 60s · silence 4s")
    }
}
