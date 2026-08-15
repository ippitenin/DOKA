// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DOKA",
    defaultLocalization: "en",   // язык отката для неподдерживаемых языков системы
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
        // Локальные модели распознавания: Whisper через WhisperKit (Argmax OSS SDK)
        // и Parakeet V3 через FluidAudio. Обе — CoreML/ANE, macOS 14+.
        // ВНИМАНИЕ: линия 0.18.x — последняя без бага мультиарх-сборки SPM
        // (в 1.x два executable-продукта argmax-cli/whisperkit-cli делят один
        // таргет ArgmaxCLI → «duplicate key found» при --arch arm64 --arch x86_64).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", .upToNextMinor(from: "0.18.0")),
        // Линия пинится минорной по той же причине, что и WhisperKit: 0.x меняет
        // требования к тулчейну и состав таргетов между минорами, а ломается это
        // только на release-сборке. Смена линии — осознанная, с прогоном ./build.sh.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.5"))
    ],
    targets: [
        .executableTarget(
            name: "DOKA",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/DOKA",
            resources: [.process("Resources")]
        ),
        // Тесты чистой логики. Сплит на отдельную библиотеку НЕ нужен: SPM
        // тестирует executable-таргет напрямую, несмотря на top-level код
        // в main.swift (проверено). Покрывается только логика без UI, звука
        // и сети — остальное проверяется ручным smoke (см. CLAUDE.md).
        .testTarget(
            name: "DOKATests",
            dependencies: ["DOKA"],
            path: "Tests/DOKATests"
        )
    ]
)
