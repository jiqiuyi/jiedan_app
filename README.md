# 接单管家（JieDan GuanJia）

> 面向自由职业者 / 接单设计师的接单、报价、收款全流程管理工具。
> 纯本地存储、无服务器依赖，数据安全由用户自己掌握，开箱即用。

一个从 0 到 1 独立开发的 Flutter Android 应用：需求分析 → UI/UX 设计 → 分层编码 → 真机迭代 → 打包发布。

## 功能特性

| 模块 | 说明 |
|------|------|
| 看板 | 本月收入、进行中项目、待收尾款、客户数、项目总数一屏总览 |
| 客户管理 | 客户信息维护、按名称快速搜索 |
| 项目管理 | 状态流转：接单 → 制作中 → 待收尾款 → 完结；已收/待收/结清金额一目了然；项目搜索 |
| 报价单 | 生成报价单，金额输入智能格式校验（防"145 变 541"类误输入） |
| 收款记录 | 定金/尾款/全额三种类型；项目列表快捷登记收款，无需进详情页 |
| 收入统计 | 历史收入按 **年 / 月 / 周 / 自定义区间** 四种维度筛选 |
| 账号体系 | 手机号 + 密码本地登录；订阅 Pro 解锁额度（月 12 / 年 88） |
| 意见反馈 | App 内反馈入口，一键唤起邮箱上报 |

## 技术栈

- **Flutter / Dart 3**（Kotlin 2.x 构建）
- **SQLite（sqflite）** 本地数据库，无后端、无服务器
- **SHA-256** 本地密码哈希（带盐 `jiedan@2026|phone|pwd`）
- **全局中文本地化**（Material 组件日期/时间选择器全面中文化）
- 分层架构：`constants(业务参数) → models → database → state/theme → pages/widgets`

## 项目结构

```
lib/
├── main.dart                # 入口，全局中文本地化配置
├── constants.dart           # 硬编码业务参数（额度/价格/费率/状态等）
├── models.dart              # 数据模型
├── database.dart            # SQLite 数据层（建表/迁移/增删改查）
├── app_state.dart           # 全局状态（登录态、订阅、当前用户）
├── theme.dart               # 主题
├── state/                   # 业务状态
├── widgets/                 # 公共组件（收款弹窗等）
└── pages/                   # 页面
    ├── home_shell.dart          # 主框架（五 Tab 常驻）
    ├── dashboard_page.dart      # 看板
    ├── projects_page.dart       # 项目
    ├── project_detail_page.dart # 项目详情
    ├── customers_page.dart      # 客户
    ├── quote_page.dart          # 报价
    ├── income_history_page.dart # 收入统计（四维筛选）
    ├── login_page.dart          # 登录注册
    ├── paywall_page.dart        # 订阅页
    ├── feedback_page.dart       # 意见反馈
    └── settings_page.dart       # 我的/设置
```

## 快速构建

```bash
# 环境：Flutter SDK + JDK 17 + Android SDK
flutter pub get
flutter build apk --release   # 产物：build/app/outputs/flutter-apk/app-release.apk
```

## 版本记录

| 版本 | 内容 |
|------|------|
| v1.0.0 | MVP：客户 / 项目 / 报价 / 收款 / 看板五模块 |
| v1.2.0 | 历史收入查看，按月筛选收款明细 |
| v1.3.0 | 收入筛选扩展为年 / 月 / 周 / 自定义区间；本地账号登录 + 订阅体系 |
| v1.3.1 | 意见反馈入口 + 邮箱上报；日期选择器全面中文化；正式签名 release 包 |

## 设计要点（踩坑沉淀）

- **看板与列表 UI 加固**：可滚动容器内禁用 `Spacer`（无界高度导致整页空白）；金额展示用 `FittedBox` 缩放防溢出红条
- **真机为纲**：交付前逐 Tab 真机截图核对，杜绝溢出与空白回归
- **本地账号无服务器**：当前为本地方案，后续可平滑迁移 Firebase / Supabase / 自建后端
- **上架就绪**：已完成正式签名（release keystore 自持），不依赖 debug 密钥
