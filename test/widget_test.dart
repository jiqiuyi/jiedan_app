import 'package:flutter_test/flutter_test.dart';

import 'package:jiedan_guanjia/constants.dart';

void main() {
  test('AppConfig 基线参数校验', () {
    expect(AppConfig.appName, '接单管家');
    expect(AppConfig.freeCustomerLimit, 1);
    expect(AppConfig.freeProjectLimit, 3);
    expect(AppConfig.monthlyPrice, 12.0);
    expect(AppConfig.yearlyPrice, 88.0);
  });

  test('项目状态流转有序', () {
    expect(ProjectStatus.values.length, 4);
    expect(ProjectStatus.accepted.index, 0);
    expect(ProjectStatus.done.index, 3);
  });
}
