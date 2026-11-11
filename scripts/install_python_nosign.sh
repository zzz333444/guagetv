#!/bin/bash
# Install the embedded Python stdlib + extension modules into the app
# bundle. Adapted from BeeWare python-apple-support's build/utils.sh
# (BSD 3-clause), with the codesign step REMOVED: this project builds
# unsigned and SideStore re-signs the whole bundle — generated module
# frameworks included — with the user's identity at install time.
#
# Layout produced inside the .app (what PythonRuntime expects):
#   python/lib/python3.13/…                 stdlib .py files
#   python/lib/python3.13/lib-dynload/*.fwork  placeholders
#   Frameworks/<module>.framework/<module>  the actual extension binaries
set -e

XCF="$PROJECT_DIR/Python.xcframework"
APP_DIR="$CODESIGNING_FOLDER_PATH"
DEST="$APP_DIR/python/lib"

mkdir -p "$DEST"
if [ -d "$XCF/lib" ]; then
    rsync -a --delete "$XCF/lib/" "$DEST/" --exclude 'libpython*.dylib'
    rsync -a "$XCF/ios-arm64/lib-arm64/" "$DEST/" --exclude 'libpython*.dylib'
else
    rsync -a --delete "$XCF/ios-arm64/lib/" "$DEST/" --exclude 'libpython*.dylib'
fi

PYVER=$(ls "$DEST" | grep -E '^python3\.[0-9]+$' | head -1)
echo "Installing Python $PYVER stdlib extension modules..."
DLDIR="$DEST/$PYVER/lib-dynload"

find "$DLDIR" -name '*.so' | while read -r FULL_EXT; do
    EXT=$(basename "$FULL_EXT")
    MODULE_NAME=$(echo "$EXT" | cut -d. -f1)
    RELATIVE_EXT=${FULL_EXT#$APP_DIR/}
    PYTHON_EXT=${RELATIVE_EXT#python/lib/$PYVER/lib-dynload/}
    FULL_MODULE_NAME=$(echo "${PYTHON_EXT%.so}" | tr '/' '.')
    FRAMEWORK_FOLDER="Frameworks/$FULL_MODULE_NAME.framework"
    BUNDLE_ID=$(echo "$PRODUCT_BUNDLE_IDENTIFIER.$FULL_MODULE_NAME" | tr '_' '-')

    mkdir -p "$APP_DIR/$FRAMEWORK_FOLDER"
    cp "$XCF/build/iOS-dylib-Info-template.plist" "$APP_DIR/$FRAMEWORK_FOLDER/Info.plist"
    plutil -replace CFBundleExecutable -string "$FULL_MODULE_NAME" "$APP_DIR/$FRAMEWORK_FOLDER/Info.plist"
    plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_DIR/$FRAMEWORK_FOLDER/Info.plist"

    mv "$FULL_EXT" "$APP_DIR/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
    echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" > "${FULL_EXT%.so}.fwork"
    echo "${RELATIVE_EXT%.so}.fwork" > "$APP_DIR/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME.origin"
done

echo "Python install complete: $(ls "$APP_DIR/Frameworks" | wc -l) frameworks in bundle"
