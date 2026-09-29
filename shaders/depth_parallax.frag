// 占位 fragment shader（SkSL）。
// 上游公开仓库从未提交真实的 depth_parallax.frag（pubspec.yaml 却引用了它，
// 导致 flutter build 在资产校验阶段失败）。Lite 用此占位文件解除打包阻塞：
// standard 包中 3D 深度封面被 feature flag（ENABLE_DEPTH_3D）关闭，
// FragmentProgram.fromAsset 不会被调用；depth3d flavor 在 Lite 中不构建。
// 如需真实视差效果，请用 impellerc 编译正式 SkSL 替换本文件。
uniform shader uTexture;
uniform float2 uSize;

half4 main(float2 fragCoord) {
  return uTexture.eval(fragCoord);
}
