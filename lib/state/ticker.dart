import 'dart:async';

/// 全局数据变更广播：各页面监听后自动刷新
class Ticker {
  Ticker._();
  static final _controller = StreamController<int>.broadcast(sync: true);

  static Stream<int> get counterStream => _controller.stream;

  static void ping() {
    if (!_controller.isClosed) _controller.add(1);
  }
}
