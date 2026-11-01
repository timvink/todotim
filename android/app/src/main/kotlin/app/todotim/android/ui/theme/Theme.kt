package app.todotim.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import app.todotim.core.Priority

/** Todoist's brand red: FAB, selected tab, accents. */
val TodoRed = Color(0xFFDC4C3E)

/** Colours outside the Material scheme: priorities and due-date states, per theme. */
@Immutable
data class TodoColors(
    val p1: Color,
    val p2: Color,
    val p3: Color,
    val p4: Color,
    val overdue: Color,
    val today: Color,
    val tomorrow: Color,
    val thisWeek: Color,
    val later: Color,
    val divider: Color,
    val secondaryText: Color,
) {
    fun priority(p: Priority): Color = when (p) {
        Priority.P1 -> p1
        Priority.P2 -> p2
        Priority.P3 -> p3
        Priority.P4 -> p4
    }
}

private val LightTodoColors = TodoColors(
    p1 = Color(0xFFD1453B), p2 = Color(0xFFEB8909), p3 = Color(0xFF246FE0), p4 = Color(0xFF808080),
    overdue = Color(0xFFD1453B), today = Color(0xFF058527), tomorrow = Color(0xFFAD6200),
    thisWeek = Color(0xFF692EC2), later = Color(0xFF808080),
    divider = Color(0xFFEEEEEE), secondaryText = Color(0xFF808080),
)

private val DarkTodoColors = TodoColors(
    p1 = Color(0xFFFF7066), p2 = Color(0xFFFF9A13), p3 = Color(0xFF5297FF), p4 = Color(0xFF8A8A8A),
    overdue = Color(0xFFFF7066), today = Color(0xFF25B84C), tomorrow = Color(0xFFFF9A13),
    thisWeek = Color(0xFFA970FF), later = Color(0xFF8A8A8A),
    divider = Color(0xFF2B2B2B), secondaryText = Color(0xFF9A9A9A),
)

val LocalTodoColors = staticCompositionLocalOf { LightTodoColors }

private val LightScheme = lightColorScheme(
    primary = TodoRed,
    onPrimary = Color.White,
    secondaryContainer = Color(0xFFFCE8E6),
    onSecondaryContainer = Color(0xFFB03D32),
    background = Color.White,
    surface = Color.White,
    surfaceContainer = Color(0xFFFAF9F7),
    surfaceContainerLow = Color(0xFFFAFAFA),
    surfaceContainerHigh = Color(0xFFF5F5F5),
    onSurface = Color(0xFF202020),
    onSurfaceVariant = Color(0xFF666666),
    outlineVariant = Color(0xFFEEEEEE),
)

private val DarkScheme = darkColorScheme(
    primary = Color(0xFFE5675B),
    onPrimary = Color.White,
    secondaryContainer = Color(0xFF3D2421),
    onSecondaryContainer = Color(0xFFFF8A80),
    background = Color(0xFF1E1E1E),
    surface = Color(0xFF1E1E1E),
    surfaceContainer = Color(0xFF242424),
    surfaceContainerLow = Color(0xFF222222),
    surfaceContainerHigh = Color(0xFF2A2A2A),
    onSurface = Color(0xFFE8E8E8),
    onSurfaceVariant = Color(0xFFAAAAAA),
    outlineVariant = Color(0xFF2B2B2B),
)

@Composable
fun TodoTimTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalTodoColors provides if (darkTheme) DarkTodoColors else LightTodoColors) {
        MaterialTheme(colorScheme = if (darkTheme) DarkScheme else LightScheme, content = content)
    }
}

/** Shorthand for the TodoTim-specific colours of the current theme. */
val todoColors: TodoColors
    @Composable get() = LocalTodoColors.current
