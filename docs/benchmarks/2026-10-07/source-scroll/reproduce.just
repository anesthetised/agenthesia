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
