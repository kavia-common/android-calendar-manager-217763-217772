#!/usr/bin/env bash
# Stub gradlew for CI environments without Android project files.
# Exits successfully to avoid breaking database container CI runs.
echo "Stub gradlew invoked at $(pwd). No Android project present. Exiting 0."
exit 0
