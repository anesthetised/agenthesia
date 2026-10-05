set shell := ["bash", "-euo", "pipefail", "-c"]

package := "Packages/AgenthesiaKit"
derived_data := ".build/xcode"
coverage_thresholds := "JSONRPC=90 ACP=90"
sources := package + "/Package.swift " + package + "/Sources " + package + "/Tests App"

# List available recipes
default:
    @just --list

# Build the core package
build:
    swift build --package-path {{package}}

# Run package tests
test:
    swift test --package-path {{package}}

# Run package tests with coverage and enforce per-module thresholds
coverage:
    swift test --package-path {{package}} --enable-code-coverage
    scripts/coverage.py "$(swift test --package-path {{package}} --show-codecov-path)" {{coverage_thresholds}}

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

# Run everything CI runs
ci: lint coverage app

# Remove build artifacts
clean:
    rm -rf {{package}}/.build {{derived_data}}
