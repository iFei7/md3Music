#!/usr/bin/env bash
# sync_jnilibs.sh — 将预编译 so 从 Flutter 侧同步到 native 工程（防漂移）。
#
# 来源（相对本脚本解析，与调用 cwd 无关）：
#   android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a}/libkugou_server.so   Rust API 服务器
#   third_party/just_audio/android/src/main/jniLibs/arm64-v8a/libflacJNI.so   FLAC 扩展解码
# 目标：
#   native/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a}/
#
# 策略与 Flutter 工程一致：so 提交进 Git、CI 不编译；本脚本在构建前运行以校验一致性。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SRC_KUGOU="${REPO_ROOT}/android/app/src/main/jniLibs"
SRC_FLAC="${REPO_ROOT}/third_party/just_audio/android/src/main/jniLibs"
DST="${REPO_ROOT}/native/app/src/main/jniLibs"

# src: dst 映射（相对各自根目录）
SO_MAP=(
  "${SRC_KUGOU}/arm64-v8a/libkugou_server.so|arm64-v8a/libkugou_server.so"
  "${SRC_KUGOU}/armeabi-v7a/libkugou_server.so|armeabi-v7a/libkugou_server.so"
  "${SRC_FLAC}/arm64-v8a/libflacJNI.so|arm64-v8a/libflacJNI.so"
)

echo "[sync_jnilibs] 仓库根：${REPO_ROOT}"
echo "[sync_jnilibs] 目标：${DST}"

# 1) 存在性校验：任一源缺失即失败（防静默缺包）
for entry in "${SO_MAP[@]}"; do
  src="${entry%%|*}"
  if [[ ! -f "${src}" ]]; then
    echo "[sync_jnilibs][ERROR] 缺少源文件：${src}" >&2
    exit 1
  fi
done

# 2) 同步并输出大小（人工核对漂移用）
mkdir -p "${DST}/arm64-v8a" "${DST}/armeabi-v7a"
for entry in "${SO_MAP[@]}"; do
  src="${entry%%|*}"
  rel="${entry##*|}"
  cp -f "${src}" "${DST}/${rel}"
  size_src="$(stat -c%s "${src}")"
  size_dst="$(stat -c%s "${DST}/${rel}")"
  if [[ "${size_src}" != "${size_dst}" ]]; then
    echo "[sync_jnilibs][ERROR] 大小不一致：${rel} src=${size_src} dst=${size_dst}" >&2
    exit 1
  fi
  printf '[sync_jnilibs] %-38s %10s bytes\n' "${rel}" "${size_dst}"
done

echo "[sync_jnilibs] 完成：3 个 so 已同步"
