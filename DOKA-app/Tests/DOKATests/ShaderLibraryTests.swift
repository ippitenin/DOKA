import Metal
import XCTest
@testable import DOKA

/// Шейдеры панели «Аврора» собираются ОТДЕЛЬНЫМ шагом (scripts/build-shaders.sh):
/// SwiftPM .metal не компилирует, а build-tool-плагин ломает universal-сборку.
/// Значит metallib легко забыть перегенерить — тогда панель молча останется без
/// эффекта. Эти проверки — единственный автоматический гейт на этот случай.
final class ShaderLibraryTests: XCTestCase {

    func testMetallibIsBundled() {
        XCTAssertNotNil(
            Bundle.module.url(forResource: "default", withExtension: "metallib"),
            "default.metallib нет в бандле — прогоните scripts/build-shaders.sh"
        )
        XCTAssertTrue(DropShaders.isAvailable)
    }

    /// Имена функций зашиты в вызовах `ShaderLibrary` строками — опечатка
    /// в Swift или переименование в .metal иначе всплывут только на экране.
    func testShaderFunctionsExist() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "default", withExtension: "metallib"))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let names = try device.makeLibrary(URL: url).functionNames
        XCTAssertTrue(names.contains("dokaDropWave"), "функции волны нет: \(names)")
        XCTAssertTrue(names.contains("dokaDropDots"), "функции точек нет: \(names)")
        XCTAssertTrue(names.contains("dokaDropGlass"), "функции стекла нет: \(names)")
    }
}
