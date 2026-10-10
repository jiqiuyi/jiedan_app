/// 设计一致性统一组件出口（barrel）。
///
/// 页面统一 `import '../widgets/app_ui.dart';` 即可使用：
/// - [AppButton] 统一按钮（消除胶囊/方形混用、高度与字号不统一）
/// - [AppFilterChip] / [AppTag] 统一筛选按钮与状态标签
/// - [AppCard] / [AppCardDivider] 统一卡片容器与卡片内分割线
/// - [AppLoading] / [AppEmpty] 统一加载态与空状态
/// - [showAppSheet] / [AppSheetHeader] 统一底部弹层
library;

export 'app_button.dart';
export 'app_card.dart';
export 'app_sheet.dart';
export 'app_states.dart';
export 'app_tag.dart';
