import 'package:material_ui/material_ui.dart';

/// 赞助支持页：展示收款码，邀请用户支持作者持续开发。
///
/// 视觉层级（从上到下）：
/// 1. 顶部图标 + 大标题 + 副标题
/// 2. 正文文案（开发与成本说明）
/// 3. 收款码卡片（微信 / 支付宝合一码）
/// 4. 底部致谢小字
class SupportPage extends StatelessWidget {
  const SupportPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('赞助支持'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ① 顶部图标 + 标题区
            Icon(Icons.favorite, size: 56, color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              '请作者喝杯咖啡',
              textAlign: TextAlign.center,
              style: textTheme.titleLarge?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '每一份支持都是继续更新的动力',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            // ② 正文文案
            Text(
              '这个应用由作者利用业余时间独立开发与维护。\n\n'
              '从功能打磨、问题修复，到接入 AI 能力（歌词识别、智能推荐等）'
              '背后的模型调用与 token 开销，都是实实在在的持续投入——'
              '服务器、开发工具与 API 费用全部自掏腰包，没有任何广告与数据收集。\n\n'
              '如果它为你的生活带来了便利与愉悦，欢迎请作者喝杯咖啡 ☕。'
              '你的每一份赞助，都会变成更快的问题响应、更勤的功能更新，'
              '和坚持下去的更大动力。\n\n'
              '金额不限，心意最重。哪怕只是一句好评与推荐，也是莫大的鼓励。',
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 24),
            // ③ 收款码卡片
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  elevation: 0,
                  color: colorScheme.surfaceContainerLowest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: colorScheme.outlineVariant,
                      width: 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          'assets/images/support_qrcode.png',
                          fit: BoxFit.contain,
                          width: double.infinity,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '微信 / 支付宝 扫码赞赏',
                          textAlign: TextAlign.center,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            // ④ 底部致谢
            Text(
              '感谢每一位支持独立开发的朋友 ❤',
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
