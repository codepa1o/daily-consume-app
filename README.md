# 日常 · 身体与饮食消费记录

Android 优先、离线使用的 Flutter 应用。身体数据和饮食消费记录保存在设备本地 SQLite 数据库中，不需要注册账号或联网。

## 当前实现

- 身体页：记录身高与每日体重，展示最近记录和身高/体重趋势折线图。
- 饮食页：按日期记录早餐、午餐、晚餐的餐食内容与消费金额。
- 消费统计：按日、周、月汇总餐费，并展示各餐次消费。
- 本地数据：体重以克、身高以毫米、金额以分写入 SQLite；同一天、同一餐次可编辑。

## 运行

需要安装 Flutter SDK 和 Android 开发工具。当前执行环境没有 Flutter SDK 或 Android SDK，因此 Android 平台生成文件尚未在此处创建。

在本机 Flutter 环境中，从项目根目录运行：

    flutter create --platforms=android --project-name=daily_consume .
    flutter pub get
    flutter run

构建可安装 APK：

    flutter build apk --release

APK 默认输出到 build/app/outputs/flutter-apk/app-release.apk。
