#!/bin/bash
set -e

echo "🛠️  Regenerating Xcode project..."
xcodegen

echo "🏗️  Building Apex Agent..."
xcodebuild build -scheme ApexAgent -project ApexAgent.xcodeproj -destination "platform=macOS" CONFIGURATION_BUILD_DIR="./build"

echo "🚀 Launching Apex Agent..."
open ./build/ApexAgent.app

echo "✅ Done!"
