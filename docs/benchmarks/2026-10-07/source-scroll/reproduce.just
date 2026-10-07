# Run from the repository root with --working-directory . and --justfile <this file>.
build:
    mkdir -p .build
    xcrun swiftc -swift-version 6 -O -parse-as-library docs/benchmarks/2026-10-07/source-scroll/native-probe.swift -o .build/native-scroll-probe

[positional-arguments]
profile output=".build/native-scroll.trace": build
    xcrun xctrace record --template 'Time Profiler' --instrument 'Points of Interest' --time-limit 30s \
        --recording-options docs/benchmarks/2026-10-07/source-scroll/wait-options.json \
        --output "$1" --target-stdout - --no-prompt --launch -- .build/native-scroll-probe

format:
    swift format format --in-place docs/benchmarks/2026-10-07/source-scroll/native-probe.swift

lint:
    swift format lint --strict docs/benchmarks/2026-10-07/source-scroll/native-probe.swift

# Diagnostic tests intentionally expose different failures on upstream and the rejected prototype.
[positional-arguments]
redraw-test checkout:
    cp docs/benchmarks/2026-10-07/source-scroll/redraw/CachedFragmentRedrawTests.swift "$1/Tests/STTextViewAppKitTests/"
    swift test --package-path "$1" --filter CachedFragmentRedrawTests

redraw-lint:
    swift format lint --strict docs/benchmarks/2026-10-07/source-scroll/redraw/CachedFragmentRedrawTests.swift

standalone-build:
    swift build -c release --package-path docs/benchmarks/2026-10-07/source-scroll/standalone --scratch-path .build/standalone-scroll --product ScrollProbe

standalone-format:
    swift format format --in-place --recursive docs/benchmarks/2026-10-07/source-scroll/standalone/Package.swift docs/benchmarks/2026-10-07/source-scroll/standalone/Sources docs/benchmarks/2026-10-07/source-scroll/standalone/fixture-identity.swift docs/benchmarks/2026-10-07/source-scroll/standalone/Tests

standalone-lint:
    swift format lint --strict --recursive docs/benchmarks/2026-10-07/source-scroll/standalone/Package.swift docs/benchmarks/2026-10-07/source-scroll/standalone/Sources docs/benchmarks/2026-10-07/source-scroll/standalone/fixture-identity.swift docs/benchmarks/2026-10-07/source-scroll/standalone/Tests

[positional-arguments]
standalone-profile renderer="sttextview" output=".build/standalone-scroll.trace": standalone-build
    xcrun xctrace record --template 'Time Profiler' --instrument 'Points of Interest' --time-limit 30s \
        --recording-options docs/benchmarks/2026-10-07/source-scroll/wait-options.json \
        --env "SCROLL_PROBE_RENDERER=$1" --output "$2" --target-stdout - --no-prompt \
        --launch -- .build/standalone-scroll/release/ScrollProbe

standalone-fixture:
    mkdir -p .build/standalone-scroll
    xcrun swiftc -swift-version 6 -DDEBUG -O -parse-as-library \
        Packages/AgenthesiaKit/Sources/AgenthesiaUI/Lab/TranscriptGenerator.swift \
        docs/benchmarks/2026-10-07/source-scroll/standalone/fixture-identity.swift \
        -o .build/standalone-scroll/fixture-identity
    .build/standalone-scroll/fixture-identity > .build/standalone-scroll/fixture.json

[positional-arguments]
standalone-run output=".build/standalone-results": standalone-build standalone-fixture
    python3 docs/benchmarks/2026-10-07/source-scroll/standalone/run.py \
        .build/standalone-scroll/release/ScrollProbe .build/standalone-scroll/fixture.json "$1"

standalone-test:
    swift test -c release --package-path docs/benchmarks/2026-10-07/source-scroll/standalone --scratch-path .build/standalone-scroll
