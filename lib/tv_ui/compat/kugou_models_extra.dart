// 批次50：上游（rust-local-force）kugou_models/remote_storage_config/kugou_provider
// 新增类型与顶级解析 helper 摘本。lite kugou_models.dart 为跨界类型源
// （lite KugouProvider 产出），不能整文件副本；本文件仅摘出 lite 完全
// 缺失的新类型。上游原样搬运。

import 'dart:convert' show jsonDecode;
import 'package:intl/intl.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

// 批次50：上游（rust-local-force）kugou_models/remote_storage_config 新增类型摘本。
// lite kugou_models.dart 为跨界类型源（lite KugouProvider 产出），不能整文件副本；
// 本文件仅摘出 lite 完全缺失的新类型，供 tv_ui 命名空间使用。上游原样搬运。
// source: origin/rust-local-force lib/services/kugou_api/kugou_models.dart 等

/// 伴奏匹配（/audio/accompany/matching）：上游为这首歌返回的最佳伴奏曲目。
/// 实测响应（探针 tests/smoke.rs::accompany_matching_probe）：
/// `{"data":{"singername":"希林娜依高","accompanySongId":"43522508","remark":"伴奏",
///   "bitrate":"128","filesize":"3457210","songname":"Shine Brighter (愈加璀璨)",
///   "duration":"216000","extname":"mp3","hash":"8153F7E7…","songid":"43522508",…},
///   "error_code":0,"status":1}`
class KugouAccompany {
  /// 上游业务状态：1 = 匹配成功。
  final int? status;
  final int? errorCode;

  /// 伴奏曲目 hash（试听播放入口，也是 K 歌数量接口 songHash 入参的来源）。
  final String? hash;

  /// 伴奏曲目名（如 "Shine Brighter (愈加璀璨)"）。
  final String? songName;
  final String? singerName;

  /// 伴奏时长（毫秒，上游为字符串数字）。
  final int? durationMs;

  /// 音质信息：码率 kbps / 扩展名 / 文件大小（字节）。
  final int? bitrate;
  final String? extName;
  final int? fileSize;

  /// 上游备注（实测恒为 "伴奏"）。
  final String? remark;

  /// 伴奏曲目 id（K 歌数量接口 songId 入参的来源）。
  final String? songId;

  const KugouAccompany({
    this.status,
    this.errorCode,
    this.hash,
    this.songName,
    this.singerName,
    this.durationMs,
    this.bitrate,
    this.extName,
    this.fileSize,
    this.remark,
    this.songId,
  });

  /// 匹配成功且伴奏 hash 可用（可试听 / 可作 K 歌数量入参）。
  bool get hasMatch => status == 1 && (hash?.isNotEmpty ?? false);

  factory KugouAccompany.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    return KugouAccompany(
      status: _parseIntOrNull(json['status']),
      errorCode: _parseIntOrNull(json['error_code']),
      hash: _strNull(data['hash']),
      songName: _strNull(data['songname'] ?? data['songName']),
      singerName: _strNull(data['singername'] ?? data['singerName']),
      durationMs: _parseIntOrNull(data['duration']),
      bitrate: _parseIntOrNull(data['bitrate']),
      extName: _strNull(data['extname'] ?? data['extName']),
      fileSize: _parseIntOrNull(data['filesize'] ?? data['fileSize']),
      remark: _strNull(data['remark']),
      songId: _strNull(data['songid'] ?? data['accompanySongId'] ?? data['songId']),
    );
  }
}

/// 内容黑名单条目（/blacklist/list 的 data.items 项）。
/// 歌曲条目含 `song_k/song_v`（k 为小写 FileHash），歌手条目含 `singer_k/singer_v`
/// （k 为歌手 ID）；*_v 为 JSON 字符串 `{"n":显示名,"m":mixsongid(仅歌曲),"t":秒}`，
/// 解析容忍字符串/对象两种形态，失败按空值处理（显示名空时由调用方回退）。
class KugouBlacklistEntry {
  /// 黑名单类型：song / singer
  final String label;

  /// 条目键：歌曲为 FileHash（小写），歌手为歌手 ID
  final String key;

  /// 显示名（歌曲为「歌手 - 歌名」，歌手为歌手名；空串回退「未命名歌曲/歌手」）
  final String name;

  /// 歌曲 MixSongID（仅歌曲条目，用于展示与跳转）
  final String? mixSongId;

  /// 标记时间（unix 秒；上游缺失时 0，UI 不显示时间行）
  final int createdAtSec;

  const KugouBlacklistEntry({
    required this.label,
    required this.key,
    this.name = '',
    this.mixSongId,
    this.createdAtSec = 0,
  });

  static (String name, String? mixSongId, int t) _parseValue(dynamic value) {
    dynamic obj;
    if (value is String && value.isNotEmpty) {
      try {
        obj = jsonDecode(value);
      } catch (_) {
        obj = null;
      }
    } else if (value is Map) {
      obj = value;
    }
    if (obj is! Map) return ('', null, 0);
    final t = obj['t'];
    return (
      obj['n']?.toString() ?? '',
      obj['m']?.toString(),
      t is num ? t.toInt() : int.tryParse('${t ?? ''}') ?? 0,
    );
  }

  factory KugouBlacklistEntry.fromJson(Map<String, dynamic> json) {
    final hasSong = json['song_k'] != null;
    final hasSinger = json['singer_k'] != null;
    final isSong = hasSong || !hasSinger;
    final parsed = _parseValue(isSong ? json['song_v'] : json['singer_v']);
    // 时间以 value 内的 t 为准，缺失回退条目级 t（用户文档返回示例的两级字段）
    final outerT = json['t'];
    final createdAt = parsed.$3 != 0
        ? parsed.$3
        : (outerT is num
            ? outerT.toInt()
            : int.tryParse('${outerT ?? ''}') ?? 0);
    return KugouBlacklistEntry(
      label: isSong ? 'song' : 'singer',
      key: (isSong ? json['song_k'] : json['singer_k'])?.toString() ?? '',
      name: parsed.$1,
      mixSongId: parsed.$2,
      createdAtSec: createdAt,
    );
  }

  /// 显示名；空名回退 [fallback]（歌曲「未命名歌曲」/ 歌手「未命名歌手」，EchoMusic 同款）。
  String displayName(String fallback) => name.isEmpty ? fallback : name;

  /// 标记时间展示：`yyyy-MM-dd`；无时间（0）返回空串。
  String get createdAtText {
    if (createdAtSec <= 0) return '';
    return DateFormat('yyyy-MM-dd')
        .format(DateTime.fromMillisecondsSinceEpoch(createdAtSec * 1000));
  }
}

/// `/blacklist/list` 完整响应的解析结果。`ok` 为 false 表示上游返回业务错误
/// （如 token 失效），此时 entries 为空但不应展示「黑名单为空」。
class KugouBlacklistSnapshot {
  final String label;
  final int page;
  final int pagesize;
  final int total;
  final List<KugouBlacklistEntry> entries;
  final bool ok;

  const KugouBlacklistSnapshot({
    this.label = 'song',
    this.page = 1,
    this.pagesize = 30,
    this.total = 0,
    this.entries = const [],
    this.ok = true,
  });

  factory KugouBlacklistSnapshot.fromJson(Map<String, dynamic> json) {
    // 业务成功判定与 KugouApiClient.isBizOk 同口径：error_code 0/缺失 且 status 1/缺失。
    final errorCode = json['error_code'];
    final status = json['status'];
    final ok = (errorCode == null || errorCode == 0 || errorCode == '0') &&
        (status == null || status == 1 || status == '1');
    final data = json['data'];
    final dataMap = data is Map ? Map<String, dynamic>.from(data) : const {};
    final rawList = dataMap['items'];
    final entries = <KugouBlacklistEntry>[];
    if (rawList is List) {
      for (final item in rawList) {
        if (item is! Map) continue;
        try {
          entries.add(
            KugouBlacklistEntry.fromJson(Map<String, dynamic>.from(item)),
          );
        } catch (_) {
          // 单条解析失败跳过，不影响整页
        }
      }
    }
    int toInt(dynamic v, int fallback) =>
        v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? fallback;
    return KugouBlacklistSnapshot(
      label: dataMap['label']?.toString() ?? 'song',
      page: toInt(dataMap['page'], 1),
      pagesize: toInt(dataMap['pagesize'], 30),
      total: toInt(dataMap['total'], entries.length),
      entries: entries,
      ok: ok,
    );
  }
}

/// `/user/history`（playhistory /v1/get_songs）里的单条最近播放记录。
///
/// 2026-10-11 实机确认的条目结构：`{mxid, ot, pc, op, sr, info:{name,
/// singername, hash, timelen, cover, mixsongid, album_id, singerinfo, ...}}`
/// —— 歌曲信息嵌套在 `info` 层，`pc` 为该曲累计播放次数（服务端保持 max），
/// `ot` 为最后一次播放时间（秒）。
class KugouHistoryEntry {
  final Song song;

  /// 播放时间（unix 秒；上游缺失为 0，UI 不显示时间）。
  final int timestampSec;

  /// 累计播放次数（上游 `pc`；缺失为 0）。
  final int playCount;

  const KugouHistoryEntry({
    required this.song,
    this.timestampSec = 0,
    this.playCount = 0,
  });
}

/// `/user/history` 的解析结果。[nextBp] 为下一页游标（响应里原样取出的
/// `bp`/`next_bp`/`cursor`，为空表示没有更多页或响应未提供游标）。
class KugouHistorySnapshot {
  final List<KugouHistoryEntry> entries;
  final String? nextBp;
  final bool ok;

  const KugouHistorySnapshot({
    this.entries = const [],
    this.nextBp,
    this.ok = true,
  });

  bool get hasMore {
    final bp = nextBp;
    return bp != null && bp.isNotEmpty;
  }

  factory KugouHistorySnapshot.fromJson(Map<String, dynamic> json) {
    final errorCode = json['error_code'];
    final status = json['status'];
    final ok = (errorCode == null || errorCode == 0 || errorCode == '0') &&
        (status == null || status == 1 || status == '1');
    final data = json['data'];
    final dataMap = data is Map
        ? Map<String, dynamic>.from(data)
        : const <String, dynamic>{};
    final rawList = _findListenItemArray(json) ?? const [];
    final entries = <KugouHistoryEntry>[];
    for (final item in rawList) {
      final songMap = _listenItemSongMap(item);
      if (songMap == null) continue;
      try {
        final song = KugouSongDetail.fromJson(songMap).toSong();
        if (song.id.isEmpty) continue;
        final itemMap =
            item is Map ? Map<String, dynamic>.from(item) : const <String, dynamic>{};
        final ts = _listenItemTimestampSec(itemMap);
        // pc = 该曲累计播放次数（实机确认字段；服务端保持 max）
        final pc = itemMap['pc'] is num
            ? (itemMap['pc'] as num).toInt()
            : int.tryParse('${itemMap['pc'] ?? ''}') ?? 0;
        entries.add(
          KugouHistoryEntry(song: song, timestampSec: ts, playCount: pc),
        );
      } catch (_) {
        // 单条解析失败跳过，不影响整页
      }
    }
    // 翻页游标：响应未文档化，多候选防御式提取（实调确认后可收窄）
    String? nextBp;
    for (final scope in <Map<String, dynamic>>[dataMap, json]) {
      for (final key in const ['bp', 'next_bp', 'nextBp', 'cursor']) {
        final v = scope[key];
        if (v == null) continue;
        final s = v.toString();
        if (s.isNotEmpty && s != '0') {
          nextBp = s;
          break;
        }
      }
      if (nextBp != null) break;
    }
    return KugouHistorySnapshot(entries: entries, nextBp: nextBp, ok: ok);
  }
}

/// `/login/device`（酷狗 `userinfoservice.kugou.com/v2/get_dev`）返回的单台登录
/// 设备（`data.li[]` 条目）。字段全部字符串化：上游这些键在 JSON 里 string/number
/// 混用，而踢下线接口要求把它们原样回传（web 签名对 string/number 的拼接结果一致）。
///
/// 本机判定依赖 `/login/device` 响应顶层由 Rust 服务器注入的 `local_device`
/// （本机 mid/dfid，来自 device_info.json）——设备列表项的 `mid` 与之相同即为本机；
/// mid 缺失时回退 dfid（`mt` 键）比对。上游响应本身不带本机标识，不能用客户端
/// 自存的 dfid 判定（可能过期，误判会把本机标成可踢设备）。
class KugouLoginDevice {
  /// 设备 mid（kick 的 t_mid）。
  final String mid;

  /// 记录的 `mt` 键 = 本机 dfid。
  final String dfid;

  /// `dev` 键：机型描述。
  final String model;

  /// `app` 键：客户端平台。
  final String platform;

  /// `loc` 键：登录/活跃位置（如「广东省深圳市 联通」）。
  final String loc;

  /// `t` 键：活跃时间原始值（unix 秒或毫秒，亦是 kick 的 t）。
  final String t;

  /// `ver` 键：客户端版本（kick 的 t_clientver）。
  final String ver;

  /// `appid` 键：客户端 appid（kick 的 t_appid）。
  final String appid;

  /// `new` 键原始值：等于 [t] 且非 '0' 时视为新设备。
  final String newFlag;

  /// `login_type` 键：0 密码 1 手机 2 微信 3 QQ 4 苹果 5 微博 6 扫码。
  final String loginType;

  /// 是否本机（当前登录设备）。
  final bool isCurrent;

  /// 列表序号（1 起），仅作展示兜底「登录设备 N」。
  final int index;

  const KugouLoginDevice({
    required this.mid,
    required this.dfid,
    required this.model,
    required this.platform,
    required this.loc,
    required this.t,
    required this.ver,
    required this.appid,
    required this.newFlag,
    required this.loginType,
    required this.isCurrent,
    required this.index,
  });

  factory KugouLoginDevice.fromJson(
    Map<String, dynamic> json, {
    String localMid = '',
    String localDfid = '',
    int index = 0,
  }) {
    final mid = _str(json['mid']);
    final dfid = _str(json['mt']);
    return KugouLoginDevice(
      mid: mid,
      dfid: dfid,
      model: _strNull(json['dev']) ?? '',
      platform: _str(json['app']),
      loc: _strNull(json['loc']) ?? '',
      t: _str(json['t']),
      ver: _str(json['ver']),
      appid: _str(json['appid']),
      newFlag: _strNull(json['new']) ?? '',
      loginType: _str(json['login_type']),
      isCurrent: _isCurrentDevice(mid, dfid, localMid, localDfid),
      index: index,
    );
  }

  /// 本机判定：mid 双方齐全时按 mid 比对；否则回退 dfid。
  static bool _isCurrentDevice(
    String mid,
    String dfid,
    String localMid,
    String localDfid,
  ) {
    if (localMid.isEmpty && localDfid.isEmpty) return false;
    if (mid.isNotEmpty && localMid.isNotEmpty) return mid == localMid;
    if (dfid.isNotEmpty && localDfid.isNotEmpty) return dfid == localDfid;
    return false;
  }

  /// 能否被踢下线：非本机且 kick 四元组（mid/t/appid/ver）齐全。
  bool get canKick =>
      !isCurrent &&
      mid.isNotEmpty &&
      t.isNotEmpty &&
      appid.isNotEmpty &&
      ver.isNotEmpty;

  /// 新设备标记：`new === t` 且非 '0'（酷狗以登录时间回填 new）。
  bool get isNew => newFlag.isNotEmpty && newFlag == t && t != '0';

  /// 展示标题兜底链：机型 → 平台含安卓 → 平台 → 「登录设备 N」。
  String get title {
    final m = model.trim();
    if (m.isNotEmpty) return m;
    final p = platform.trim();
    if (p.isNotEmpty) {
      final lower = p.toLowerCase();
      if (p.contains('安卓') || lower.contains('android')) {
        return '酷狗Android客户端';
      }
      return p;
    }
    return index > 0 ? '登录设备 $index' : '登录设备';
  }

  /// 登录方式文案；未知值展示原值。
  String get loginTypeLabel {
    switch (loginType) {
      case '0':
        return '账号密码';
      case '1':
        return '手机';
      case '2':
        return '微信';
      case '3':
        return 'QQ';
      case '4':
        return '苹果';
      case '5':
        return '微博';
      case '6':
        return '扫码';
      default:
        return loginType.isEmpty ? '未知' : '未知($loginType)';
    }
  }

  /// 位置展示：loc 按空白/逗号/斜杠分割取最后一段（如「广东省深圳市 联通」→「联通」）。
  String get locationLabel {
    final l = loc.trim();
    if (l.isEmpty) return '';
    final parts =
        l.split(RegExp(r'[\s,，/]+')).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? l : parts.last;
  }

  /// 活跃时间的毫秒值（解析失败为 0，仅用于排序）。
  int get activeTimeMs => int.tryParse(t) ?? 0;

  /// 活跃时间展示：unix 秒（≤10 位 ×1000）/毫秒/日期串 → `yyyy-MM-dd HH:mm`。
  String get activeTimeText {
    final raw = t.trim();
    if (raw.isEmpty) return '';
    DateTime? time;
    final ms = int.tryParse(raw);
    if (ms != null) {
      final normalized = raw.length <= 10 ? ms * 1000 : ms;
      time =
          DateTime.fromMillisecondsSinceEpoch(normalized);
    } else {
      time = DateTime.tryParse(raw);
    }
    if (time == null) return raw;
    return DateFormat('yyyy-MM-dd HH:mm').format(time);
  }
}

/// `/login/device` 完整响应的解析结果：设备列表（已按本机优先、活跃时间降序排列）
/// 与 Rust 服务器注入的本机设备标识。`ok` 为 false 表示上游返回了业务错误
/// （如 token 失效），此时 devices 为空但不应展示「暂无设备」。
class KugouLoginDeviceSnapshot {
  final List<KugouLoginDevice> devices;
  final String localMid;
  final String localDfid;
  final bool ok;

  const KugouLoginDeviceSnapshot({
    required this.devices,
    this.localMid = '',
    this.localDfid = '',
    this.ok = true,
  });

  factory KugouLoginDeviceSnapshot.fromJson(Map<String, dynamic> json) {
    // 业务成功判定与 KugouApiClient.isBizOk 同口径：error_code 0/缺失 且 status 1/缺失。
    final errorCode = json['error_code'];
    final status = json['status'];
    final ok = (errorCode == null || errorCode == 0 || errorCode == '0') &&
        (status == null || status == 1 || status == '1');
    final local = json['local_device'];
    final localMap = local is Map
        ? Map<String, dynamic>.from(local)
        : const <String, dynamic>{};
    final localMid = _str(localMap['mid']);
    final localDfid = _str(localMap['dfid']);
    final data = json['data'];
    final li = data is Map ? data['li'] : null;
    final rawList = li is List ? li : const [];
    final devices = <KugouLoginDevice>[];
    var index = 0;
    for (final item in rawList) {
      if (item is! Map) continue;
      index++;
      devices.add(
        KugouLoginDevice.fromJson(
          Map<String, dynamic>.from(item),
          localMid: localMid,
          localDfid: localDfid,
          index: index,
        ),
      );
    }
    devices.sort((a, b) {
      if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
      return b.activeTimeMs.compareTo(a.activeTimeMs);
    });
    return KugouLoginDeviceSnapshot(
      devices: devices,
      localMid: localMid,
      localDfid: localDfid,
      ok: ok,
    );
  }
}

class KugouMvBrief {
  final String videoId;
  final String name;
  final String? coverUrl;
  final String? authorName;
  final int timelengthMs;
  final String? publishDate;
  final String? albumAudioId;
  final String? hash;

  const KugouMvBrief({
    required this.videoId,
    required this.name,
    this.coverUrl,
    this.authorName,
    this.timelengthMs = 0,
    this.publishDate,
    this.albumAudioId,
    this.hash,
  });

  factory KugouMvBrief.fromJson(Map<String, dynamic> json) {
    // 上游缺失字段常返回空串而不是 null，而 [_strNull] 只做 toString、空串会原样留下，
    // 因此这里局部收口一次「空串当 null」（同 KugouSongDetail.fromJson 里的 firstIdOf 闭包写法）。
    String? textOf(dynamic v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    return KugouMvBrief(
      videoId: _str(
        json['video_id'] ??
            json['id'] ??
            json['videoid'] ??
            '',
      ),
      name: _str(
        json['video_name'] ??
            json['name'] ??
            json['title'] ??
            json['mv_name'] ??
            '',
      ),
      coverUrl: _resolveFirstArtwork([
        json['hdpic'],
        json['cover'],
        json['pic'],
        json['imgurl'],
        json['sizable_cover'],
      ]),
      authorName: textOf(
        json['author_name'] ??
            json['singer_name'] ??
            json['singername'] ??
            json['author'],
      ),
      timelengthMs: _parseInt(json['timelength'] ?? json['duration'] ?? 0),
      publishDate: textOf(
        json['publish_date'] ??
            json['publishtime'] ??
            json['publish_time'],
      ),
      albumAudioId: textOf(
        json['album_audio_id'] ?? json['albumaudio_id'],
      ),
      // 清晰度由高到低回落；无 mkv_ 前缀的键名在同族上游里也出现过
      // （见 KugouSceneVideo.fromJson 的 sd_hash / qhd_hash）
      hash: textOf(
        json['mkv_qhd_hash'] ??
            json['mkv_hd_hash'] ??
            json['mkv_sd_hash'] ??
            json['qhd_hash'] ??
            json['sd_hash'] ??
            json['video_hash'] ??
            json['hash'],
      ),
    );
  }
}

/// QQ 扫码登录会话（`/login/qq/qr/create` 的输出）。
///
/// 上游是**根级扁平**结构（不是 `{data:{...}}` 嵌套），check 时必须把
/// [toQuery] 的 6 个字段原样回传，否则上游回 `ptuiCB('7')` 参数错误。
class KugouQqQrSession {
  /// 二维码图片 base64（**JPEG**，ptqrshow 返回的就是 JPEG）。
  final String imageBase64;
  final String qrsig;
  final int ptqrtoken;
  final String ptLoginSig;
  final String ptOpenloginData;
  final String xloginUrl;
  final String cookie;

  const KugouQqQrSession({
    required this.imageBase64,
    required this.qrsig,
    required this.ptqrtoken,
    required this.ptLoginSig,
    required this.ptOpenloginData,
    required this.xloginUrl,
    required this.cookie,
  });

  /// 会话字段缺失（任一必需项为空）时返回 null。
  static KugouQqQrSession? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final image = _strNull(json['qrcode']);
    final qrsig = _strNull(json['qrsig']);
    final token = _parseIntOrNull(json['ptqrtoken']);
    final loginSig = _strNull(json['pt_login_sig']);
    final openlogin = _strNull(json['pt_openlogin_data']);
    final xlogin = _strNull(json['xlogin_url']);
    final cookie = _strNull(json['cookie']);
    if (image == null ||
        image.isEmpty ||
        qrsig == null ||
        qrsig.isEmpty ||
        token == null ||
        loginSig == null ||
        loginSig.isEmpty ||
        openlogin == null ||
        openlogin.isEmpty ||
        xlogin == null ||
        xlogin.isEmpty ||
        cookie == null ||
        cookie.isEmpty) {
      return null;
    }
    return KugouQqQrSession(
      imageBase64: image,
      qrsig: qrsig,
      ptqrtoken: token,
      ptLoginSig: loginSig,
      ptOpenloginData: openlogin,
      xloginUrl: xlogin,
      cookie: cookie,
    );
  }

  /// check 接口的 query（不含图片）。
  ///
  /// `pt_openlogin_data` 在这里**原样**下发：Rust 侧 `build_qq_poll_url` 直接拼接，
  /// 不会再编码一次；Dio 的 query 序列化会把它还原成单次编码态，正好与上游一致。
  Map<String, dynamic> toQuery() => {
    'qrsig': qrsig,
    'ptqrtoken': ptqrtoken,
    'pt_login_sig': ptLoginSig,
    'pt_openlogin_data': ptOpenloginData,
    'xlogin_url': xloginUrl,
    'cookie': cookie,
  };
}

/// 云端听歌排行/历史里的单首歌曲（复用 [KugouSongDetail] 的字段别名解析转 [Song]）。
class KugouRankedSong {
  final Song song;

  /// 云端播放次数（响应未提供时为 null，UI 只显示排名不显示次数）。
  final int? playCount;

  const KugouRankedSong({required this.song, this.playCount});
}

/// 曲谱标签（/sheet/tags，2026-10-24 实测：`tagid/tagname`）。
class KugouSheetTag {
  final String id;
  final String name;

  const KugouSheetTag({required this.id, required this.name});

  factory KugouSheetTag.fromJson(Map<String, dynamic> json) {
    return KugouSheetTag(
      id: _str(json['tagid'] ?? json['id'] ?? ''),
      name: _str(json['tagname'] ?? json['name'] ?? ''),
    );
  }
}

/// 成绩单详情（/song/ranking/filter）：单个子榜单的历史成绩条目。
class KugouSongRankingFilterItem {
  final int? area;
  final String? name;

  /// 累计上榜次数。
  final int? count;

  /// 历史最高名次（top_ranking，<=0 视为暂无排名）。
  final int? topRanking;
  final int? platform;
  final String? platformName;
  final String? logoPic;
  final String? sharePic;

  const KugouSongRankingFilterItem({
    this.area,
    this.name,
    this.count,
    this.topRanking,
    this.platform,
    this.platformName,
    this.logoPic,
    this.sharePic,
  });

  factory KugouSongRankingFilterItem.fromJson(Map<String, dynamic> json) {
    return KugouSongRankingFilterItem(
      area: _parseIntOrNull(json['area']),
      name: _strNull(json['name']),
      count: _parseIntOrNull(json['count']),
      topRanking: _parseIntOrNull(json['top_ranking'] ?? json['topRanking']),
      platform: _parseIntOrNull(json['platform']),
      platformName: _strNull(json['platform_name'] ?? json['platformName']),
      logoPic: _strNull(
        json['platform_logo'] ??
            json['platformLogo'] ??
            json['logo_pic'] ??
            json['logoPic'] ??
            json['logo'],
      ),
      sharePic: _strNull(json['share_pic'] ?? json['sharePic']),
    );
  }
}

/// 成绩单平台成就卡：一个平台一条（当前名次/累计上榜/最近上榜）。
class KugouSongRankingInfo {
  final int? platform;
  final String? platformName;

  /// 当前名次（ranking_num）。
  final int? rankingNum;

  /// 累计上榜次数。
  final int? rankingTimes;

  /// 最近上榜时间（上游原始字符串）。
  final String? lastTime;
  final String? logoPic;
  final String? sharePic;

  const KugouSongRankingInfo({
    this.platform,
    this.platformName,
    this.rankingNum,
    this.rankingTimes,
    this.lastTime,
    this.logoPic,
    this.sharePic,
  });

  factory KugouSongRankingInfo.fromJson(Map<String, dynamic> json) {
    return KugouSongRankingInfo(
      platform: _parseIntOrNull(json['platform']),
      platformName: _strNull(json['platform_name'] ?? json['platformName']),
      rankingNum: _parseIntOrNull(json['ranking_num'] ?? json['rankingNum']),
      rankingTimes:
          _parseIntOrNull(json['ranking_times'] ?? json['rankingTimes']),
      lastTime: _strNull(json['last_time'] ?? json['lastTime']),
      // 实测响应字段为 platform_logo；其余为旧口径/ camelCase 兜底
      logoPic: _strNull(
        json['platform_logo'] ??
            json['platformLogo'] ??
            json['logo_pic'] ??
            json['logoPic'] ??
            json['logo'],
      ),
      sharePic: _strNull(json['share_pic'] ?? json['sharePic']),
    );
  }
}

/// 微信扫码登录会话（`/login/wx/create` 的输出）。
///
/// 上游响应根级为 `{errcode, uuid, appname, qrcode:{qrcodebase64, qrcodeurl}}`，
/// 图片是 **JPEG**（不是 PNG），故前端用 `Image.memory` 按字节嗅探格式，
/// 不要假定 PNG 或拼 `data:image/png`。
class KugouWxQrSession {
  final String uuid;

  /// `qrcode.qrcodebase64`（不含 data: 前缀）。
  final String? imageBase64;

  /// `qrcode.qrcodeurl`（后端补的 `https://open.weixin.qq.com/connect/confirm?uuid=`）。
  final String? imageUrl;

  const KugouWxQrSession({
    required this.uuid,
    this.imageBase64,
    this.imageUrl,
  });

  /// 解析失败（无 uuid）时返回 null。
  static KugouWxQrSession? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final uuid = _strNull(json['uuid']);
    if (uuid == null || uuid.isEmpty) return null;
    final qr = json['qrcode'];
    String? base64;
    String? url;
    if (qr is Map) {
      base64 = _strNull(qr['qrcodebase64']);
      url = _strNull(qr['qrcodeurl']);
    }
    return KugouWxQrSession(uuid: uuid, imageBase64: base64, imageUrl: url);
  }

  bool get hasImage =>
      (imageBase64 != null && imageBase64!.isNotEmpty) ||
      (imageUrl != null && imageUrl!.isNotEmpty);
}

/// QQ 扫码轮询状态。
enum QqScanKind {
  /// 等待扫码（ptuiCB '66'）
  waiting,

  /// 已扫码，待确认（ptuiCB '67'）
  scanned,

  /// 二维码失效（ptuiCB '65'）
  expired,

  /// 上游风控拦截 / 链路不可用（HTTP 403、空响应、传输失败）。
  /// **不是**登录失败，UI 应提示改用其它方式并停止轮询。
  blocked,

  /// 登录成功（ptuiCB '0' 且已换到酷狗 token）
  success,

  /// 其它错误
  error,
}

/// 歌曲的远程来源类型。
///
/// 新增字段而非复用 `Song.isOnline`：`isOnline=true` 在播放器中触发酷狗
/// 富化/歌词检索/CDN 卡顿检测等在线专属逻辑，远程歌曲不需要这些行为。
enum SongRemoteType {
  none,
  webdav,
  ftp;

  static SongRemoteType fromJson(String? value) {
    switch (value) {
      case 'webdav':
        return SongRemoteType.webdav;
      case 'ftp':
        return SongRemoteType.ftp;
      default:
        return SongRemoteType.none;
    }
  }

  /// 序列化：none 输出 null（旧 JSON 缺省向后兼容）。
  String? toJson() => switch (this) {
        SongRemoteType.none => null,
        SongRemoteType.webdav => 'webdav',
        SongRemoteType.ftp => 'ftp',
      };
}

/// 微信扫码轮询状态。
enum WxScanKind {
  /// 等待扫码（上游 408）
  waiting,

  /// 已扫码，待手机确认（上游 404）
  scanned,

  /// 二维码过期（上游 402）
  expired,

  /// 用户在手机上拒绝（上游 403）
  rejected,

  /// 登录成功（上游 405 且已换到酷狗 token）
  success,

  /// 其它错误（网络 / 上游返回异常）
  error,
}

// 批次50：上游 kugou_provider.dart 的热搜状态类型摘本（上游原样搬运）。

/// 热搜榜单卡的加载状态（独立于全局 `_isLoading`/`_error`，
/// 见 KugouProvider.loadHotSearch 的隔离说明）。
// 批次50：上游 kugou_models.dart HotSearchBoard 摘本（lite 缺失，上游原样搬运）。
/// 热搜榜单（上游 `/api/v3/search/hot_tab` 的 `data.list` 元素）。
///
/// 上游每条只有 `keyword`（`reason` 与之完全重复、`icon/type/jumpurl/json_url`
/// 实测恒为空或固定值，**没有热度数值**），故模型只保留榜名与有序词表，
/// 不去伪造热度字段。
class HotSearchBoard {
  final String name;
  final List<String> keywords;

  const HotSearchBoard({required this.name, required this.keywords});

  /// 从 `/search/hot` 的响应 JSON 抽榜单。
  ///
  /// 关键：`data.list` 是**榜单数组**，词在 `list[i].keywords[j].keyword`。
  /// 直接把 `data.list` 当词数组取 `keyword ?? name` 会拿到一串榜名
  /// （这是旧实现 `kugou_api_client.dart` 的回归点）。
  static List<HotSearchBoard> parseList(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is! Map) return const [];
    final list = data['list'];
    if (list is! List) return const [];

    final boards = <HotSearchBoard>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final name = _str(entry['name']);
      final rawKeywords = entry['keywords'];
      if (name.isEmpty || rawKeywords is! List) continue;

      final words = <String>[];
      for (final item in rawKeywords) {
        final word = item is Map ? _str(item['keyword']) : _str(item);
        if (word.isNotEmpty) words.add(word);
      }
      if (words.isNotEmpty) {
        boards.add(HotSearchBoard(name: name, keywords: words));
      }
    }
    return boards;
  }
}

enum HotSearchStatus { idle, loading, ready, failed }

class HotSearchState {
  final HotSearchStatus status;
  final List<HotSearchBoard> boards;
  final String? error;

  const HotSearchState({
    this.status = HotSearchStatus.idle,
    this.boards = const [],
    this.error,
  });
}

// 批次50：补充摘本（compat 依赖闭包）。

class WxScanResult {
  final WxScanKind kind;

  /// 登录成功时的酷狗凭证。
  final String? token;
  final String? userid;
  final String? vipToken;

  /// 失败原因 / 状态文案。
  final String? message;

  const WxScanResult(
    this.kind, {
    this.token,
    this.userid,
    this.vipToken,
    this.message,
  });

  bool get isSuccess => kind == WxScanKind.success;
  bool get isTerminal =>
      kind == WxScanKind.success ||
      kind == WxScanKind.expired ||
      kind == WxScanKind.rejected ||
      kind == WxScanKind.error;
}

class QqScanResult {
  final QqScanKind kind;

  /// 登录成功时的酷狗凭证。
  final String? token;
  final String? userid;
  final String? vipToken;

  /// 失败原因 / 状态文案。
  final String? message;

  const QqScanResult(
    this.kind, {
    this.token,
    this.userid,
    this.vipToken,
    this.message,
  });

  bool get isSuccess => kind == QqScanKind.success;
  bool get isTerminal =>
      kind == QqScanKind.success ||
      kind == QqScanKind.expired ||
      kind == QqScanKind.blocked ||
      kind == QqScanKind.error;
}

/// 听歌偏好（/user/preference 返回的 data）。
///
/// lang/style 为基础偏好的 JSON 字符串（{"标签id":权重}，>50 视为启用）；
/// song_lang 为歌曲推荐强度 JSON 字符串（0 屏蔽 / 50 默认 / 100 加大），标签为
/// L*/S*/T*/N* 前缀 ID（L1 国语、L2 英语、L5 粤语、L4 韩语、L3 日语、L6 纯音乐、
/// S9 DJ、T1 翻唱、N2 现场、S28 AI 歌曲）。**两组标签 ID 相互独立，不应互相转换**。
/// gender/age/mode 为单个 id 字符串（'' = 未设置）。
class KugouUserPreference {
  /// 推荐模式：'' 未设置 / 0 默认 / 1 熟悉 / 2 尝鲜
  final String mode;

  /// 性别 id：'' 未设置 / 1 女 / 2 男
  final String gender;

  /// 年龄段 id：'' 未设置 / 0 其它 / 1 00后 / 2 90后 / 3 80后 / 4 70后 /
  /// 6 10后 / 7 05后 / 8 95后 / 9 85后 / 10 75后 / 11 65后 / 12 60后
  final String age;

  /// 语言偏好（{"标签id": 权重}，>50 视为启用）
  final Map<String, int> lang;

  /// 风格偏好（{"标签id": 权重}，>50 视为启用）
  final Map<String, int> style;

  /// 歌曲推荐强度（{"标签id": 0-100}，0 屏蔽 / 50 默认 / 100 加大）
  final Map<String, int> songLang;

  /// 三组 JSON 串的原始文本（UI 回显未识别标签、diff 兜底用）
  final String langRaw;
  final String styleRaw;
  final String songLangRaw;

  /// 其余上游原样字段（stylerec_taglist / wish_taglist / inactive_taglist /
  /// inactive_singerlist / song_style 等，UI 暂不消费，更新时原样保留语义）
  final Map<String, dynamic> rawData;

  const KugouUserPreference({
    this.mode = '',
    this.gender = '',
    this.age = '',
    this.lang = const {},
    this.style = const {},
    this.songLang = const {},
    this.langRaw = '',
    this.styleRaw = '',
    this.songLangRaw = '',
    this.rawData = const {},
  });

  factory KugouUserPreference.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as Map<String, dynamic>? ?? json;
    String rawOf(dynamic v) => v == null ? '' : v.toString();
    return KugouUserPreference(
      mode: rawOf(data['mode']),
      gender: rawOf(data['gender']),
      age: rawOf(data['age']),
      langRaw: rawOf(data['lang']),
      styleRaw: rawOf(data['style']),
      songLangRaw: rawOf(data['song_lang']),
      lang: _parseWeightMap(data['lang']),
      style: _parseWeightMap(data['style']),
      songLang: _parseWeightMap(data['song_lang']),
      rawData: data,
    );
  }

  /// 解析 {"1":100,"3":50} 形态的权重 JSON 串；非 Map / 解析失败回退空 map
  /// （原始串保留在 *Raw 字段）。
  static Map<String, int> _parseWeightMap(dynamic raw) {
    if (raw == null || raw.toString().isEmpty) return const {};
    if (raw is Map) {
      return _coerceWeightMap(raw);
    }
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is Map) return _coerceWeightMap(decoded);
    } catch (_) {}
    return const {};
  }

  static Map<String, int> _coerceWeightMap(Map<dynamic, dynamic> source) {
    final out = <String, int>{};
    source.forEach((k, v) {
      final n = v is num ? v.toInt() : int.tryParse(v.toString().trim());
      if (n != null) out[k.toString()] = n;
    });
    return out;
  }
}

/// 成绩单详情（/song/ranking/filter）：单个子榜单的历史成绩条目。


// 批次50：上游 kugou_models.dart 顶级私有解析 helper 摘本（上游原样搬运）。


// 批次50：上游 kugou_models.dart 顶级私有解析 helper 摘本（上游原样搬运）。

String _str(dynamic v) => v?.toString() ?? '';

// 批次50 适配：上游摘本暂无消费点，保留原样。
// ignore: unused_element
String _cleanName(dynamic v) {
  final raw = v?.toString() ?? '';
  return raw
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#\d+;', '');
}

String? _strNull(dynamic v) => v?.toString();
int _parseInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

/// 与 [_parseInt] 相同，但解析失败/缺失时返回 null（用于可选数字字段）。
int? _parseIntOrNull(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse(v.toString());
}

/// 解析可选浮点字段（响度/峰值等）。缺失或非有限值时返回 null。
// 批次50 适配：上游摘本暂无消费点，保留原样。
// ignore: unused_element
double? _optDouble(dynamic v) {
  if (v == null) return null;
  final parsed = v is num ? v.toDouble() : double.tryParse(v.toString());
  if (parsed == null || !parsed.isFinite) return null;
  return parsed;
}

// 批次50 适配：上游摘本暂无消费点，保留原样。
// ignore: unused_element
dynamic _zeroAsNull(dynamic v) {
  if (v == null) return null;
  final text = v.toString().trim();
  return text.isEmpty || text == '0' ? null : v;
}

/// 解析评论时间为秒级 Unix 时间戳。
///
/// 酷狗评论接口的 `addtime` 是 "2024-09-11 08:38:13" 这样的日期时间字符串而非
/// 时间戳，[_parseInt] 对它只能得到 0，时间戳因此完全渲染不出来。这里先按数字
/// （秒级时间戳）解析，失败再按日期时间字符串解析。
///
/// 字符串不带时区，实测是北京时间（UTC+8），按 UTC+8 而非设备本地时区解析，
/// 否则其他时区算出的「x 小时前」会整体偏移、甚至变成未来时间。
// 批次50 适配：上游摘本暂无消费点，保留原样。
// ignore: unused_element
int _parseCommentTime(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is double) return v.toInt();
  final text = v.toString().trim();
  if (text.isEmpty) return 0;
  final asTimestamp = int.tryParse(text);
  if (asTimestamp != null) return asTimestamp;
  var iso = text.replaceFirst(' ', 'T');
  if (!iso.endsWith('Z') && !_isoOffsetPattern.hasMatch(iso)) {
    iso = '$iso+08:00';
  }
  final parsed = DateTime.tryParse(iso);
  return parsed == null ? 0 : parsed.millisecondsSinceEpoch ~/ 1000;
}

final RegExp _isoOffsetPattern = RegExp(r'[+-]\d{2}:?\d{2}$');

/// 依次取第一个非空候选作为封面图（上游常返回空串 pic + 有效 bg_pic）。
String? _resolveFirstArtwork(List<dynamic> candidates) {
  for (final c in candidates) {
    if (c != null && c.toString().isNotEmpty) {
      return _resolveArtworkUri(c);
    }
  }
  return null;
}

String? _resolveArtworkUri(dynamic v) {
  if (v == null) return null;
  final s = v.toString();
  if (s.isEmpty) return null;
  return s.replaceAll('{size}', '400');
}

// 批次50 适配：上游摘本暂无消费点，保留原样。
// ignore: unused_element
List<KugouPlaylistBrief> _parsePlList(dynamic v) {
  if (v == null) return [];
  if (v is List) {
    return v
        .map((e) => KugouPlaylistBrief.fromJson(e as Map<String, dynamic>))
        .toList();
  }
  return [];
}


List<dynamic>? _findListenItemArray(Map<String, dynamic> json) {
  final data = json['data'];
  final scopes = <Map<String, dynamic>>[
    if (data is Map) Map<String, dynamic>.from(data),
    json,
  ];
  for (final scope in scopes) {
    for (final key in const ['lists', 'info', 'list', 'songs', 'data', 'items']) {
      final v = scope[key];
      if (v is List) return v;
    }
  }
  return null;
}

/// 从条目里取出可交给 [KugouSongDetail.fromJson] 的歌曲信息层：
/// 条目本身，或其内嵌的 `info`/`song`/`data` 子对象（部分响应把歌曲字段包一层）。
Map<String, dynamic>? _listenItemSongMap(dynamic item) {
  if (item is! Map) return null;
  final direct = Map<String, dynamic>.from(item);
  if (kugouItemLooksLikeSong(direct)) return direct;
  for (final key in const ['info', 'song', 'data', 'base']) {
    final inner = item[key];
    if (inner is Map) {
      final m = Map<String, dynamic>.from(inner);
      if (kugouItemLooksLikeSong(m)) return m;
    }
  }
  return direct;
}

/// 播放次数候选字段（酷狗各接口口径不一，全部尝试）。
/// `/user/listen` 实机确认的字段是 `listen_count`（2026-10-11）。
int? _listenItemPlayCount(Map<String, dynamic> item) {
  for (final key in const [
    'listen_count',
    'count',
    'play_count',
    'playcount',
    'score',
    'pc',
  ]) {
    final v = item[key];
    if (v is num && v > 0) return v.toInt();
    final parsed = int.tryParse('${v ?? ''}');
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
}

/// 播放时间候选字段 → 归一化为秒级时间戳（≤10 位视为秒，>10 位视为毫秒）。
int _listenItemTimestampSec(Map<String, dynamic> item) {
  for (final key in const ['timestamp', 'time', 'ot', 'play_time', 'last_time']) {
    final v = item[key];
    final n = v is num
        ? v.toInt()
        : int.tryParse('${v ?? ''}');
    if (n == null || n <= 0) continue;
    return n <= 9999999999 ? n : n ~/ 1000;
  }
  return 0;
}

/// 云端听歌排行/历史里的单首歌曲（复用 [KugouSongDetail] 的字段别名解析转 [Song]）。


/// `/user/listen`（listenservice /v2/get_list）的解析结果。
/// [ok] 为 false 表示上游返回业务错误（如未登录 token 失效），songs 为空。
class KugouListenRanking {
  /// 0 = 最近一周前 120 首，1 = 全部累计前 120 首
  final int type;
  final List<KugouRankedSong> songs;
  final bool ok;

  const KugouListenRanking({
    this.type = 0,
    this.songs = const [],
    this.ok = true,
  });

  factory KugouListenRanking.fromJson(
    Map<String, dynamic> json, {
    int type = 0,
  }) {
    final errorCode = json['error_code'];
    final status = json['status'];
    final ok = (errorCode == null || errorCode == 0 || errorCode == '0') &&
        (status == null || status == 1 || status == '1');
    final rawList = _findListenItemArray(json) ?? const [];
    final songs = <KugouRankedSong>[];
    for (final item in rawList) {
      final songMap = _listenItemSongMap(item);
      if (songMap == null) continue;
      try {
        final song = KugouSongDetail.fromJson(songMap).toSong();
        if (song.id.isEmpty) continue;
        songs.add(
          KugouRankedSong(
            song: song,
            playCount: _listenItemPlayCount(songMap),
          ),
        );
      } catch (_) {
        // 单条解析失败跳过，不影响整页
      }
    }
    return KugouListenRanking(type: type, songs: songs, ok: ok);
  }
}
class KugouQrKey {
  final String? qrcode;
  final String? qrcodeImg;

  const KugouQrKey({this.qrcode, this.qrcodeImg});

  factory KugouQrKey.fromJson(Map<String, dynamic> json) {
    return KugouQrKey(
      qrcode: _strNull(json['qrcode']),
      qrcodeImg: _strNull(json['qrcode_img']),
    );
  }
}

/// 批次50 适配：上游 KugouSongDetail.itemLooksLikeSong 静态方法（lite 类无），
/// 摘为顶级函数（上游实现原样搬运）。
bool kugouItemLooksLikeSong(Map<String, dynamic> json) {
  const hashKeys = [
    'hash', 'FileHash', 'Hash128', 'SQFileHash', 'HQFileHash', 'sd_hash',
    'hash_128', 'hash_320', 'hash_flac', 'sq_hash', 'hq_hash',
  ];
  const nameKeys = [
    'songname', 'SongName', 'name', 'ori_audio_name', 'FileName',
    'filename', 'audio_name',
  ];
  final hasHash = hashKeys.any(
    (k) => json[k] != null && json[k].toString().isNotEmpty,
  );
  if (hasHash) return true;
  return nameKeys.any(
    (k) => json[k] != null && json[k].toString().isNotEmpty,
  );
}
