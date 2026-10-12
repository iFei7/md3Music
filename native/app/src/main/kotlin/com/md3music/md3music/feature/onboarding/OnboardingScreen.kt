package com.md3music.md3music.feature.onboarding

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import com.md3music.md3music.core.theme.Md3MusicTheme
import com.md3music.md3music.core.ui.RoutePlaceholder

/**
 * 新手引导占位（路由 `/onboarding`）。
 *
 * P0-C 仅路由占位。lite 的转场为 fade + emphasisDuration(600ms)，
 * 转场细节 P3 补齐（见 `ui.Md3MusicNavHost` 的 TODO）。
 */
@Composable
fun OnboardingScreen(modifier: Modifier = Modifier) {
    RoutePlaceholder(route = "/onboarding", modifier = modifier)
}

@Preview(name = "新手引导占位", showBackground = true)
@Composable
private fun OnboardingScreenPreview() {
    Md3MusicTheme {
        OnboardingScreen()
    }
}
