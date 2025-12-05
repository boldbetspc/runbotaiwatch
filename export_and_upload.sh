#!/bin/bash

# Script to export watchOS archive and prepare for upload
# Usage: ./export_and_upload.sh

echo "🔍 Finding RunbotAIWatch archive..."

# Find the most recent archive
ARCHIVE_PATH=$(find ~/Library/Developer/Xcode/Archives -name "RunbotAIWatch.xcarchive" -type d -maxdepth 3 | sort -r | head -1)

if [ -z "$ARCHIVE_PATH" ]; then
    echo "❌ Archive not found!"
    echo "Please make sure you've archived the app in Xcode."
    echo "Archive location: ~/Library/Developer/Xcode/Archives/"
    exit 1
fi

echo "✅ Found archive: $ARCHIVE_PATH"
echo ""

# Create export directory
EXPORT_DIR="./export"
mkdir -p "$EXPORT_DIR"

echo "📦 Exporting archive..."
echo ""

# Export the archive
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist ExportOptions.plist

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Export successful!"
    echo ""
    echo "📱 IPA file location: $EXPORT_DIR/"
    echo ""
    echo "📤 Next steps:"
    echo "1. Open Transporter app (from Mac App Store)"
    echo "2. Sign in with your Apple Developer account"
    echo "3. Drag the .ipa file from $EXPORT_DIR/ into Transporter"
    echo "4. Click 'Deliver' to upload to App Store Connect"
    echo ""
    echo "Or upload via command line if you have API credentials."
else
    echo ""
    echo "❌ Export failed!"
    echo "Check the error messages above."
    exit 1
fi

