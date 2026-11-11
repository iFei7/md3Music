// 批次50：tv_ui 播放链的 AudioService 出口。io 平台复用 lite 既有引擎实现
// （lib/core/services/audio_service_io.dart，androidAudioSessionId /
// androidAudioSessionIdsStream / playingStream / setVolumeNormalization 四个
// tv_ui 消费面成员均已具备）；web 平台用 tv_ui 自带变体。此前 io 分支指向
// 不存在的 audio_service_io.dart，TV 构建编译 AudioService 未定义（批次50
// 接线时实跑测试暴露）。
export 'package:md3music/tv_ui/core/services/audio_service_web.dart'
    if (dart.library.io)
        'package:md3music/core/services/audio_service_io.dart';
