@echo off
REM ============================================================
REM 正式发布构建（防破解 P3）
REM   - R8/ProGuard 混淆（Android 层，build.gradle 已开）
REM   - --obfuscate         Dart 层混淆
REM   - --split-debug-info  混淆符号表（仅用于崩溃栈还原，勿分发）
REM ============================================================
set PUB_CACHE=D:\pub-cache
flutter build apk --release --obfuscate --split-debug-info=./debug-info

echo.
echo ============================================================
echo 构建完成:
echo   APK : build\app\outputs\flutter-apk\app-release.apk
echo   符号: .\debug-info （仅用于崩溃栈还原，请勿分发）
echo ============================================================
pause
