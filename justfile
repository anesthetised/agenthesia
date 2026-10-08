set shell := ["bash", "-euo", "pipefail", "-c"]

package := "Packages/AgenthesiaKit"
derived_data := ".build/xcode"
coverage_thresholds := "JSONRPC=90 ACP=90 AgentRuntime=80 Workspace=90 Persistence=90 Rendering=90 acp-cli=80"
sources := package + "/Package.swift " + package + "/Sources " + package + "/Tests App"

# List available recipes
default:
    @just --list

# Build the core package
build:
    swift build --package-path {{package}}

# Run package tests
test: test-scripts
    swift test --package-path {{package}}

# Test benchmark and coverage tooling without launching benchmarks
test-scripts:
    python3 -m unittest discover -s scripts -p 'test_*.py'

# Run package tests with coverage and enforce per-module thresholds (e.g. `just coverage --badge out.svg`)
coverage *args:
    scripts/coverage.py clean {{package}}
    scripts/coverage.py test {{package}}
    scripts/coverage.py report {{package}} {{coverage_thresholds}} {{args}}

# Check formatting
lint:
    swift format lint --strict --recursive --parallel {{sources}}

# Format code in place
format:
    swift format format --in-place --recursive --parallel {{sources}}

# Build the app with xcodebuild
app configuration="Debug":
    xcodebuild -project Agenthesia.xcodeproj -scheme Agenthesia -configuration {{configuration}} \
        -destination 'platform=macOS' -derivedDataPath {{derived_data}} build

# Build and launch the app
run: app
    open {{derived_data}}/Build/Products/Debug/Agenthesia.app

# Run and save sequential fresh-process measurements; agree on resource use before running
[positional-arguments]
bench *args:
    python3 scripts/bench.py micro "$@"

# Build the microbenchmarks without running them
bench-build:
    swift build -c release --package-path {{package}} --product rendering-bench

# Measure append throughput and latency in fresh processes; agree on resource use before running
[positional-arguments]
bench-persistence *args:
    python3 scripts/bench.py persistence "$@"

# Build the persistence benchmark without running it
bench-persistence-build:
    swift build -c release --package-path {{package}} --product persistence-bench

# Locate the Release executable for the benchmark runner
bench-path:
    @swift build -c release --package-path {{package}} --show-bin-path

# Build an optimized Debug build, which has the Rendering Lab, for measurements
lab-build:
    xcodebuild -project Agenthesia.xcodeproj -scheme Agenthesia -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath .build/xcode-lab build -quiet \
        SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s

# Launch the optimized lab build
lab: lab-build
    open .build/xcode-lab/Build/Products/Debug/Agenthesia.app

# Leave the Mac alone while it runs: a window behind others gets a throttled display link.
# Save lab scenarios in fresh processes, e.g. `just lab-run S1:A2,S4:cold+lines+colors --runs 1`
[positional-arguments]
lab-run *args:
    python3 scripts/bench.py lab "$@"

# Profile one lab scenario; profiled timings are not benchmark results
[positional-arguments]
lab-profile scenario="S6:A2" output=".build/rendering.trace" options="": lab-build
    #!/usr/bin/env bash
    set -eo pipefail
    recording_options=()
    if [[ -n "$3" ]]; then recording_options=(--recording-options "$3"); fi
    xcrun xctrace record --template 'Time Profiler' --instrument 'Points of Interest' --time-limit 30s \
        "${recording_options[@]}" \
        --output "$2" --env "AGENTHESIA_LAB_RUNS=$1" --target-stdout - \
        --no-prompt --launch -- .build/xcode-lab/Build/Products/Debug/Agenthesia.app/Contents/MacOS/Agenthesia

# Export CPU samples for inspection; the trace also opens directly in Instruments
[positional-arguments]
lab-profile-export trace output schema="time-profile":
    xcrun xctrace export --input "$1" --output "$2" \
        --xpath "/trace-toc/run[@number='1']/data/table[@schema='$3']"

# Run acp-cli, e.g. `just cli chat -- npx -y @agentclientprotocol/claude-agent-acp`
[positional-arguments]
cli *args:
    swift run --quiet --package-path {{package}} acp-cli "$@"

# Chat with the bundled MockAgent through acp-cli
mock-chat:
    swift build --quiet --package-path {{package}} --product MockAgent
    swift run --quiet --package-path {{package}} acp-cli chat -- "$(swift build --package-path {{package}} --show-bin-path)/MockAgent"

# Run everything CI runs
ci: lint test-scripts coverage app

# Remove build artifacts
clean:
    rm -rf {{package}}/.build {{derived_data}} .build/xcode-lab
