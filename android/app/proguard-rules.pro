# 防破解加固（P3）：R8/ProGuard 保留规则
# Flutter 引擎与插件反射调用类，混淆可能导致运行时崩溃，需保留

# Flutter embedding
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# flutter_secure_storage 使用的平台类
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# sqflite
-keep class com.tekartik.sqflite.** { *; }
-dontwarn com.tekartik.sqflite.**

# flutter_local_notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-dontwarn com.dexterous.flutterlocalnotifications.**

# file_picker / share_plus / path_provider 等常用插件平台类
-keep class io.flutter.plugins.pathprovider.** { *; }
-dontwarn io.flutter.plugins.pathprovider.**

# 应用自身平台通道类（MainActivity）
-keep class com.jiedan.guanjia.MainActivity { *; }

# 泛型与枚举保留（避免 R8 误删）
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod
