import 'package:flutter/material.dart';

import '../constants.dart';
import '../theme.dart';

/// 隐私政策页（独立页面）。
/// 说明 App 的数据存储方式、业务数据归属、云端同步范围与联系方式。
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('隐私政策')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          _SectionTitle('一、我们如何收集和使用信息'),
          _Paragraph(
              '「接单管家」仅在您主动填写时收集必要信息，包括：'
              '注册账号所需的手机号与密码（密码经本地哈希处理，不存储明文）；'
              '业务运营所需的客户、项目、收款记录等数据；'
              '开通专业版所需的订阅信息。'),
          _Paragraph(
              '除上述为实现功能所必需的信息外，我们不会收集您的通讯录、'
              '相册、定位、通话记录等与功能无关的个人信息。'),
          _SectionTitle('二、数据存储方式'),
          _Paragraph(
              '您的业务数据（客户、项目、收款记录、报价单等）仅保存在您自己的设备本地，'
              '不经过我们的服务器，我们无法读取或访问这些本地业务数据。'
              '卸载或清除应用数据会删除本地业务数据，请提前做好备份。'),
          _Paragraph(
              '仅以下与账号体系相关的数据会同步至云端服务器：'
              '账号信息（手机号、昵称）、订阅状态（是否专业版及到期时间）、'
              '订单与模拟支付记录、推广活动（邀请关系、返现金额、推荐送VIP）。'
              '钱包相关（充值记录、提现记录）当前仅存本地。'),
          _SectionTitle('三、信息共享与对外提供'),
          _Paragraph(
              '我们不会向任何第三方出售、出租或共享您的个人信息，'
              '法律法规另有规定或获得您明确授权的情形除外。'
              '云端数据仅用于支撑账号登录、订阅校验与推广结算等核心功能。'),
          _SectionTitle('四、信息安全'),
          _Paragraph(
              '密码采用加盐哈希存储，本地数据库位于应用沙箱目录。'
              '请妥善保管您的手机号与密码，不要向他人泄露。'
              '如需删除云端账号数据，请联系下方联系方式处理。'),
          _SectionTitle('五、您的权利'),
          _Paragraph(
              '您可以随时在应用内查看、修改或删除本机业务数据；'
              '删除客户 / 项目时，其关联的收款记录会一并删除。'
              '如需注销云端账号或删除云端数据，请联系我们。'),
          _SectionTitle('六、政策更新'),
          _Paragraph(
              '我们可能会适时更新本隐私政策，重大变更将通过应用内公告或推送告知。'
              '继续使用本应用即视为您接受更新后的政策。'),
          _SectionTitle('七、联系我们'),
          _Paragraph(
              '如您对本隐私政策有任何疑问或建议，可通过应用内「意见反馈」提交，'
              '或发送邮件至联系邮箱：support@jiedan-guanjia.local。'
              '我们将在收到反馈后的合理时间内回复您。'),
          SizedBox(height: 12),
          Text(
            '生效日期：2026-08-29\n版本：${AppConfig.version}',
            style: TextStyle(fontSize: 12, color: AppTheme.textSub),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(text,
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textMain)),
    );
  }
}

class _Paragraph extends StatelessWidget {
  final String text;
  const _Paragraph(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(
              fontSize: 13.5, height: 1.6, color: AppTheme.textMain)),
    );
  }
}
