package com.ryanheise.just_audio;

import android.util.Log;
import androidx.media3.common.MimeTypes;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * MD3Music fork（批次49）：音频解码器候选**优先硬件 / DSP 解码器**。
 *
 * <p>为什么需要它：Media3 的 {@code MediaCodecAudioRenderer.getDecoderInfos} 只调用
 * {@link MediaCodecUtil#getDecoderInfosSortedByFormatSupport}，该方法**只按「格式是否
 * 功能支持」打分（0/1）**，完全不看 {@link MediaCodecInfo#hardwareAccelerated}；同分项
 * 之间保持 {@code MediaCodecList} 的原始注册顺序。也就是说「用厂商 DSP 解码器还是
 * c2.android 纯 CPU 软解器」由平台注册顺序决定，App 层此前完全没有干预。
 *
 * <p>在支持的设备上（如高通平台的 {@code c2.qti.*} 音频解码器运行在 ADSP 上），把硬件
 * 加速解码器排到前面可以显著降低软解路径的 CPU 占用——这与 AudioTrack offload 是两条
 * 不同的省电路径：offload 是「不解码，码流直通 DSP」，本类优化的是「必须解码时，
 * 让 DSP 而不是 CPU 来解」。
 *
 * <p>三条安全约束：
 * <ul>
 *   <li>**只调顺序，不裁剪候选**：全量返回，配合 {@code setEnableDecoderFallback(true)}，
 *       初始化失败时 ExoPlayer 会自动尝试下一个候选；
 *   <li>**只对音频生效**：视频轨保持原顺序（硬件视频解码器与显示路径抢核，排序收益另论）；
 *   <li>**只用官方标记**：判据是 {@code MediaCodecInfo.hardwareAccelerated}（API 29+ 由
 *       平台上报），不做名字前缀猜测——避免把「名字像厂商但其实有 bug」的解码器排到前面。
 *       若某机型厂商解码器未上报该标记，行为与改动前完全一致（等于 no-op）。
 * </ul>
 *
 * <p>可观测性：每个 mimeType 首次查询时打一条日志（TAG {@code MD3AudioCodec}），
 * 含候选顺序与各自是否硬件加速，便于在真机上验证本策略是否真的生效。
 */
public final class PreferHardwareAudioDecoderSelector implements MediaCodecSelector {

  private static final String TAG = "MD3AudioCodec";

  /** 每个 mimeType 只打一次日志，避免每次切歌刷屏。 */
  private static final Set<String> LOGGED_MIME_TYPES = new HashSet<>();

  private final MediaCodecSelector delegate;

  public PreferHardwareAudioDecoderSelector(MediaCodecSelector delegate) {
    this.delegate = delegate;
  }

  @Override
  public List<MediaCodecInfo> getDecoderInfos(
      String mimeType, boolean requiresSecureDecoder, boolean requiresTunnelingDecoder)
      throws MediaCodecUtil.DecoderQueryException {
    List<MediaCodecInfo> infos =
        delegate.getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder);
    if (infos == null || infos.isEmpty()) {
      return infos;
    }
    if (!MimeTypes.isAudio(mimeType) || infos.size() < 2) {
      logOnce(mimeType, infos);
      return infos;
    }
    boolean[] hardwareAccelerated = new boolean[infos.size()];
    for (int i = 0; i < infos.size(); i++) {
      hardwareAccelerated[i] = infos.get(i).hardwareAccelerated;
    }
    int[] order = hardwareFirstOrder(hardwareAccelerated);
    List<MediaCodecInfo> reordered = new ArrayList<>(infos.size());
    for (int index : order) {
      reordered.add(infos.get(index));
    }
    logOnce(mimeType, reordered);
    return reordered;
  }

  /**
   * 稳定分区：硬件加速项在前，其余保持原相对顺序（纯函数，便于 JVM 单测）。
   *
   * <p>返回的是原数组下标序列——不复制对象，也不改变同组内的相对顺序，
   * 从而保留 Media3 后续 {@code getDecoderInfosSortedByFormatSupport} 的稳定排序语义。
   */
  static int[] hardwareFirstOrder(boolean[] hardwareAccelerated) {
    final int n = hardwareAccelerated.length;
    int[] order = new int[n];
    int write = 0;
    for (int i = 0; i < n; i++) {
      if (hardwareAccelerated[i]) {
        order[write++] = i;
      }
    }
    for (int i = 0; i < n; i++) {
      if (!hardwareAccelerated[i]) {
        order[write++] = i;
      }
    }
    return order;
  }

  private static void logOnce(String mimeType, List<MediaCodecInfo> infos) {
    synchronized (LOGGED_MIME_TYPES) {
      if (!LOGGED_MIME_TYPES.add(mimeType)) {
        return;
      }
    }
    StringBuilder builder = new StringBuilder(mimeType).append(" 候选解码器: ");
    for (int i = 0; i < infos.size(); i++) {
      if (i > 0) {
        builder.append(" > ");
      }
      MediaCodecInfo info = infos.get(i);
      builder.append(info.name).append(info.hardwareAccelerated ? "(硬件)" : "(软件)");
    }
    Log.i(TAG, builder.toString());
  }
}
