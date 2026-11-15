import XCTest
@testable import ReaderCore

final class LocalTranslationTests: XCTestCase {
    func testSimplifiedToTraditionalKeepsSentenceStructure() {
        let src = "这本书讨论了摄影与绘画的关系，以及它们在当代艺术中的地位。"
        guard case .convert(let out) = LocalTranslation.decide(text: src, target: .zhHantTW) else {
            return XCTFail("應走本機轉換")
        }
        XCTAssertEqual(out, "這本書討論了攝影與繪畫的關係，以及它們在當代藝術中的地位。")
        XCTAssertEqual(out.count, src.count, "只轉字形，字數不變")
    }

    func testTaiwanTermsOnlyForClearDifferences() {
        guard case .convert(let out) = LocalTranslation.decide(text: "下载软件后请连接网络并打印文件。", target: .zhHantTW) else {
            return XCTFail()
        }
        XCTAssertTrue(out.contains("軟體"), out)
        XCTAssertTrue(out.contains("網路"), out)
        XCTAssertTrue(out.contains("列印"), out)
    }

    func testTraditionalStaysOriginalForTraditionalTarget() {
        XCTAssertEqual(LocalTranslation.decide(text: "這是一段繁體中文。", target: .zhHantTW), .keepOriginal)
    }

    func testTraditionalToSimplified() {
        XCTAssertEqual(LocalTranslation.decide(text: "攝影與繪畫", target: .zhHans), .convert("摄影与绘画"))
    }

    func testOtherLanguagesUseEngine() {
        XCTAssertEqual(LocalTranslation.decide(text: "Photography has never been more widely used.", target: .zhHantTW), .useEngine)
        XCTAssertEqual(LocalTranslation.decide(text: "摄影与绘画的关系", target: .en), .useEngine)
    }

    func testAlreadyTargetLanguageIsKept() {
        XCTAssertEqual(LocalTranslation.decide(text: "Photography has never been more widely used as a means of expression.",
                                               target: .en), .keepOriginal)
    }

    func testPromptMentionsTargetLanguage() {
        let req = TranslationRequest(segments: [.init(id: "a", kind: .paragraph, text: "Hello")], targetLanguage: "ja")
        let prompt = TranslationPrompt.build(req)
        XCTAssertTrue(prompt.contains("Japanese"))
        XCTAssertTrue(prompt.contains("<BOOK_DATA>"))
    }
}
