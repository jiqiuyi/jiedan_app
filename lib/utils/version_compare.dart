/// 语义化版本号逐段比较（如 "1.48.2"）。
///
/// 规则：按 '.' 拆分后逐段转 int 比较，缺段按 0 处理；
/// 返回 1 表示 a 更新，-1 表示 b 更新，0 表示相等。
int compareVersion(String a, String b) {
  List<int> parts(String s) => s
      .split('.')
      .map((e) => int.tryParse(e.trim()) ?? 0)
      .toList();
  final pa = parts(a);
  final pb = parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}
