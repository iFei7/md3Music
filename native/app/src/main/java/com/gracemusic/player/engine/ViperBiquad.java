// MD3Music native —— 蝰蛇母带 DSP 核心（just_audio fork 资产移植）。
//
// 来源：third_party/just_audio/android/src/main/java/com/ryanheise/just_audio/ViperBiquad.java
// 移植方式：**仅重命名 package**（com.ryanheise.just_audio → com.gracemusic.player.engine），
//           类体逐字节保持与 fork 一致（算法/常量/注释均不改动），保证音质行为 1:1 等价。
// 同步责任：fork 侧若改动本文件，须同步移植到此处。
//
// 为什么不直接复用 third_party 源码目录：同目录下并存 4 个依赖 io.flutter 的插件类
// （AudioPlayer / JustAudioPlugin / BetterEventChannel / MainMethodCallHandler），
// 而 AGP 源集不支持按文件过滤，故按文件移植。
package com.gracemusic.player.engine;

/**
 * RBJ peaking 双二阶滤波器（Direct Form I，系数按 a0 归一，含 NaN 溢出自愈）。
 *
 * <p>规格对齐 EchoMusic dsp/basic.rs：A = 10^(dB/40)，中心频点幅度 = A² = 10^(dB/20)；
 * process 与 basic.rs 同款自愈（输出非有限值时清空状态返回 0）。
 */
final class ViperBiquad {

  private float b0, b1, b2, a1, a2;
  private float z1, z2;

  private ViperBiquad() {}

  /** 构造峰值滤波器：中心 frequency Hz、Q 值 q、增益 gainDb（±12）。 */
  static ViperBiquad peaking(float sampleRate, float frequency, float q, float gainDb) {
    double a = Math.pow(10.0, gainDb / 40.0); // RBJ: A = 10^(dB/40)
    double w0 = 2.0 * Math.PI * frequency / sampleRate;
    double cosW0 = Math.cos(w0);
    double sinW0 = Math.sin(w0);
    double alpha = sinW0 / (2.0 * q);
    double b0 = 1.0 + alpha * a;
    double b1 = -2.0 * cosW0;
    double b2 = 1.0 - alpha * a;
    double a0 = 1.0 + alpha / a;
    double a1 = -2.0 * cosW0;
    double a2 = 1.0 - alpha / a;
    ViperBiquad f = new ViperBiquad();
    f.b0 = (float) (b0 / a0);
    f.b1 = (float) (b1 / a0);
    f.b2 = (float) (b2 / a0);
    f.a1 = (float) (a1 / a0);
    f.a2 = (float) (a2 / a0);
    return f;
  }

  /** 处理一个样本；输出非有限值时清空状态返回 0（溢出自愈）。 */
  float process(float in) {
    float out = b0 * in + z1;
    if (!Float.isFinite(out)) {
      z1 = 0f;
      z2 = 0f;
      return 0f;
    }
    z1 = b1 * in - a1 * out + z2;
    z2 = b2 * in - a2 * out;
    return out;
  }

  /** 归一化传递函数在角频率 omega 处的幅度（headroom 测量用）。 */
  double magnitudeAt(double omega) {
    double cos1 = Math.cos(omega);
    double sin1 = Math.sin(omega);
    double cos2 = Math.cos(2.0 * omega);
    double sin2 = Math.sin(2.0 * omega);
    double numRe = b0 + b1 * cos1 + b2 * cos2;
    double numIm = -(b1 * sin1 + b2 * sin2);
    double denRe = 1.0 + a1 * cos1 + a2 * cos2;
    double denIm = -(a1 * sin1 + a2 * sin2);
    double den = Math.hypot(denRe, denIm);
    if (den < 1e-12) {
      return Double.MAX_VALUE;
    }
    return Math.hypot(numRe, numIm) / den;
  }

  /** 清空滤波器状态（歌曲边界/seek 不拖尾）。 */
  void reset() {
    z1 = 0f;
    z2 = 0f;
  }
}
