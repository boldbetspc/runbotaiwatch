#!/bin/bash

# Verification script for Watch App Extension structure
# Run this after restructuring in Xcode

echo "🔍 Verifying Project Structure..."
echo ""

# Check if project file exists
if [ ! -f "RunbotAIWatch.xcodeproj/project.pbxproj" ]; then
    echo "❌ Project file not found"
    exit 1
fi

# Check for Extension target
if grep -q "RunbotAIWatchExtension" "RunbotAIWatch.xcodeproj/project.pbxproj"; then
    echo "✅ Watch App Extension target found"
else
    echo "❌ Watch App Extension target NOT found"
    echo "   → Create it in Xcode: File → New → Target → Watch App Extension"
fi

# Check for Watch App target
if grep -q "261B1A882EE30D150041BB64.*RunbotAIWatch" "RunbotAIWatch.xcodeproj/project.pbxproj"; then
    echo "✅ Watch App target found"
else
    echo "❌ Watch App target not found"
fi

# Check for iOS Wrapper target
if grep -q "RunbotAIWatch iOS Wrapper" "RunbotAIWatch.xcodeproj/project.pbxproj"; then
    echo "✅ iOS Wrapper target found"
else
    echo "❌ iOS Wrapper target not found"
fi

# Check SKIP_INSTALL for iOS Wrapper
SKIP_COUNT=$(grep -c "SKIP_INSTALL = YES" "RunbotAIWatch.xcodeproj/project.pbxproj" | head -1)
if [ "$SKIP_COUNT" -ge 2 ]; then
    echo "✅ SKIP_INSTALL = YES found for iOS Wrapper (at least 2 instances)"
else
    echo "⚠️  SKIP_INSTALL may not be set correctly for iOS Wrapper"
fi

# Check for WKWatchOnly
if grep -q "WKWatchOnly" "RunbotAIWatch.xcodeproj/project.pbxproj"; then
    echo "✅ WKWatchOnly setting found"
else
    echo "⚠️  WKWatchOnly setting not found in build settings"
fi

# Check for WKRunsIndependentlyOfCompanionApp
if grep -q "WKRunsIndependentlyOfCompanionApp" "RunbotAIWatch.xcodeproj/project.pbxproj"; then
    echo "✅ WKRunsIndependentlyOfCompanionApp setting found"
else
    echo "⚠️  WKRunsIndependentlyOfCompanionApp setting not found"
fi

echo ""
echo "📋 Next Steps:"
echo "1. Open project in Xcode: open RunbotAIWatch.xcodeproj"
echo "2. Follow RESTRUCTURE_PROJECT.md instructions"
echo "3. Run this script again to verify"
echo ""
echo "✅ Verification complete"

