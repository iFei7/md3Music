package com.ryanheise.just_audio;

import androidx.media3.exoplayer.audio.DefaultAudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioTrackBufferSizeProvider;

/**
 * MD3Music fork（批次47）：按输出档位选择 AudioTrack 缓冲深度——软解后台能耗优化主项。
 *
 * <p>Media3 默认的 PCM 缓冲是「minBufferSize × 4，钳在 250~750ms」（见
 * {@link DefaultAudioTrackBufferSizeProvider} 的 MIN/MAX_PCM_BUFFER_DURATION_US）。
 * 软解播放时解码线程与渲染线程必须持续小步快跑：队列只有几百毫秒余量，
 * 解码线程几乎每 250~750ms 就要醒来喂一次数据，无法进入长睡眠。
 *
 * <p>本类把**非 offload 档**放宽到「× 8，钳在 500~2000ms」：队列加深后解码线程
 * 的唤醒间隔上限翻倍以上，后台（尤其熄屏高负载调度延迟大的场景）欠载重试减少，
 * CPU 可以更久地停留在空闲态——这是用起播排队的 RAM（几十 KB 量级）换能耗与稳定性。
 *
 * <p>「offload」档必须回落到 Media3 默认实现：offload 的缓冲时长语义是
 * 「编码帧 50s」（{@code DefaultAudioTrackBufferSizeProvider.OFFLOAD_BUFFER_DURATION_US}），
 * 与本类的 PCM 深缓冲目标（500~2000ms 排队）不是一回事；套用 DEEP 会把编码缓冲
 * 压到 PCM 量级，直接增加 offload 欠载与断音风险。
 *
 * <p>与上游版本的差异：上游还有一个「系统 Direct PCM + 低延迟」档保持默认值
 * （低延迟目标与深缓冲冲突）；lite 已下线 DirectPcm 链路（commit 62d8b2f），
 * sink 构建也未开启低延迟（无 setLowLatencyEnabled），因此该分支直接不存在。
 *
 * <p>本类只在 {@code configure()} 时被调用。加深缓冲不会引入音画不同步：
 * 本 fork 只播音频，MV / 动态封面走 video_player 的独立播放器实例。
 * 变速播放由 Sonic 处理器完成，与 AudioTrack 容量无关，不受影响。
 */
public final class AdaptiveAudioTrackBufferSizeProvider
    implements DefaultAudioSink.AudioTrackBufferSizeProvider {

  /** 抗卡顿档：minBufferSize × 8，钳在 500~2000ms。 */
  private static final DefaultAudioSink.AudioTrackBufferSizeProvider DEEP =
      new DefaultAudioTrackBufferSizeProvider.Builder()
          .setMinPcmBufferDurationUs(500_000)
          .setMaxPcmBufferDurationUs(2_000_000)
          .setPcmBufferMultiplicationFactor(8)
          .build();

  @Override
  public int getBufferSizeInBytes(
      int minBufferSizeInBytes,
      int encoding,
      int outputMode,
      int pcmFrameSize,
      int sampleRate,
      int bitrate,
      double maxAudioTrackPlaybackSpeed) {
    // offload 档回落默认：编码缓冲语义（50s 帧队列）与 PCM 深缓冲语义不兼容。
    if (outputMode == DefaultAudioSink.OUTPUT_MODE_OFFLOAD) {
      return DefaultAudioSink.AudioTrackBufferSizeProvider.DEFAULT.getBufferSizeInBytes(
          minBufferSizeInBytes,
          encoding,
          outputMode,
          pcmFrameSize,
          sampleRate,
          bitrate,
          maxAudioTrackPlaybackSpeed);
    }
    // lite 已无低延迟档（DirectPcm 已下线、未开 setLowLatencyEnabled），
    // 其余全部档位统一走深缓冲。
    return DEEP.getBufferSizeInBytes(
        minBufferSizeInBytes,
        encoding,
        outputMode,
        pcmFrameSize,
        sampleRate,
        bitrate,
        maxAudioTrackPlaybackSpeed);
  }
}
