set shell := ["bash", "-euo", "pipefail", "-c"]

package := "Packages/AgenthesiaKit"
derived_data := ".build/xcode"
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
ci: lint test app

# Remove build artifacts
clean:
    rm -rf {{package}}/.build {{derived_data}}
