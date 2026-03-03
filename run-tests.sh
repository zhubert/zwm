#!/bin/bash
cd "$(dirname "$0")"

# Swift Testing framework needs explicit path when using CommandLineTools (no Xcode)
TESTING_FLAGS=(
    -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks
    -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
    -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
)

if swift test "${TESTING_FLAGS[@]}" "$@"; then
    echo "All tests passed"
else
    echo "Tests failed"
    exit 1
fi
