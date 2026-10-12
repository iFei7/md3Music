package com.md3music.md3music.player.gate

/**
 * P1-1 临时最小 Song 模型（仅含播放闸门票务判定实际读取的字段）。
 *
 * 背景：Dart 侧 [PlaylistPrefetchTicket] / [CrossfadePreparationTicket] 依赖
 * lib/data/models/song.dart 的完整 Song 模型，但 native 数据层（P2）尚未移植。
 * 为遵守 T41 文件归属约束（仅允许 player/gate 目录树），此处只落地两个票务
 * canCommit 实际读取的字段：id / albumId / albumAudioId / url / isOnline。
 *
 * 后续 P2 数据层移植正式 Song 模型后，应将两个票务类改为引用正式模型并删除
 * 本文件（字段语义一致，canCommit 逻辑无需调整）。
 *
 * 注意：Dart 的 Song `==` 只比较 id；此处按 data class 全字段相等，
 * 闸门逻辑本身不依赖 Song 相等性（均为逐字段比较），对该差异不敏感。
 */
data class Song(
    val id: String,
    val albumId: String? = null,
    val albumAudioId: String? = null,
    val url: String? = null,
    val isOnline: Boolean = false,
)
