package com.ryanheise.just_audio;

import static org.junit.Assert.assertArrayEquals;

import org.junit.Test;

/**
 * 批次49：硬件优先排序的纯函数单测（纯 JVM，无 Android 依赖）。
 *
 * <p>核心语义是「稳定分区」：硬件加速项整体前移，但两组内部都保持原有相对顺序——
 * 这一点很关键，因为 Media3 后续还会用 {@code getDecoderInfosSortedByFormatSupport}
 * 做一次稳定排序，两层稳定排序叠加后，同分候选仍维持平台注册顺序，不会因为本类
 * 引入不确定的顺序抖动。
 */
public class PreferHardwareAudioDecoderSelectorTest {

  @Test
  public void allSoftware_keepsOriginalOrder() {
    assertArrayEquals(
        new int[] {0, 1, 2},
        PreferHardwareAudioDecoderSelector.hardwareFirstOrder(
            new boolean[] {false, false, false}));
  }

  @Test
  public void allHardware_keepsOriginalOrder() {
    assertArrayEquals(
        new int[] {0, 1, 2},
        PreferHardwareAudioDecoderSelector.hardwareFirstOrder(
            new boolean[] {true, true, true}));
  }

  @Test
  public void hardwareMovesToFront_softwareKeepsRelativeOrder() {
    // [软, 硬, 软] -> [1, 0, 2]
    assertArrayEquals(
        new int[] {1, 0, 2},
        PreferHardwareAudioDecoderSelector.hardwareFirstOrder(
            new boolean[] {false, true, false}));
  }

  @Test
  public void multipleHardware_keepRelativeOrder() {
    // [软, 硬, 软, 硬] -> [1, 3, 0, 2]
    assertArrayEquals(
        new int[] {1, 3, 0, 2},
        PreferHardwareAudioDecoderSelector.hardwareFirstOrder(
            new boolean[] {false, true, false, true}));
  }

  @Test
  public void singleCandidate_unchanged() {
    assertArrayEquals(
        new int[] {0},
        PreferHardwareAudioDecoderSelector.hardwareFirstOrder(new boolean[] {false}));
    assertArrayEquals(
        new int[] {0},
        PreferHardwareAudioDecoderSelector.hardwareFirstOrder(new boolean[] {true}));
  }

  @Test
  public void emptyInput_returnsEmptyOrder() {
    assertArrayEquals(
        new int[0], PreferHardwareAudioDecoderSelector.hardwareFirstOrder(new boolean[0]));
  }
}
