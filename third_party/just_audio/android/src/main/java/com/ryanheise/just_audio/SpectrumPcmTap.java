package com.ryanheise.just_audio;

import android.content.Context;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * 频谱 PCM 捕获层（MD3Music fork）。
 *
 * 在 handleBuffer 截取解码后的原始 PCM 快照，交给应用侧频谱插件自己算 FFT。
 * 数据在 AudioFlinger 混音之前，不受系统媒体音量影响 —— 静音播放时频谱依然
 * 有真实数据（Visualizer 做不到这点）。
 *
 * 包装器在 ExoPlayer 构建时注入，未注册 listener 时零开销透传。
 * 线程模型：configure/handleBuffer 在 ExoPlayer 渲染线程执行。
 */
public final class SpectrumPcmTap extends ForwardingAudioSink {

    /** 频谱 PCM 捕获监听（MD3Music 频谱功能用）。 */
    public interface PcmCaptureListener {
        /**
         * @param buffer      当前块 PCM（position 指向读取起点，调用方勿改动原始 buffer）
         * @param encoding    C.ENCODING_PCM_16BIT / PCM_24BIT / PCM_32BIT / PCM_FLOAT
         * @param sampleRate  解码采样率（Hz）
         * @param channelCount 声道数
         */
        void onPcm(java.nio.ByteBuffer buffer, int encoding, int sampleRate, int channelCount);
    }

    private static volatile PcmCaptureListener pcmCaptureListener = null;

    public static void setPcmCaptureListener(PcmCaptureListener listener) {
        pcmCaptureListener = listener;
    }

    /** 所有存活包装器（应用可能创建多个播放器实例），防止被 GC 后 listener 失联。 */
    private static final List<SpectrumPcmTap> liveSinks = new CopyOnWriteArrayList<>();

    private int currentEncoding = C.ENCODING_PCM_16BIT;
    private int currentSampleRate = 0;
    private int currentChannelCount = 0;

    public SpectrumPcmTap(AudioSink delegate, Context ctx) {
        super(delegate);
        ctx = ctx.getApplicationContext();
        liveSinks.add(this);
    }

    @Override
    public void configure(Format inputFormat, int specifiedBufferSize, int[] outputChannels)
            throws ConfigurationException {
        int enc = inputFormat.pcmEncoding;
        if (enc != Format.NO_VALUE) currentEncoding = enc;
        currentSampleRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 0;
        currentChannelCount = inputFormat.channelCount > 0 ? inputFormat.channelCount : 0;
        super.configure(inputFormat, specifiedBufferSize, outputChannels);
    }

    @Override
    public boolean handleBuffer(ByteBuffer buffer, long presentationTimeUs, int encodedAccessUnitCount)
            throws InitializationException, WriteException {
        PcmCaptureListener listener = pcmCaptureListener;
        if (listener != null && currentSampleRate > 0 && buffer != null && buffer.remaining() > 0) {
            try {
                listener.onPcm(
                        buffer.duplicate().order(buffer.order()),
                        currentEncoding, currentSampleRate, currentChannelCount);
            } catch (Exception ignored) {
                // 频谱回调异常不得影响播放
            }
        }
        return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount);
    }
}
