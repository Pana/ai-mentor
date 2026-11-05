package cn.littlebear.tutor

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

val Paper = Color(0xFFF7F5EF)
val Ink = Color(0xFF293F38)
val Forest = Color(0xFF376E57)
val Muted = Color(0xFF77837B)
val Sage = Color(0xFFE8EEE4)
val Ochre = Color(0xFFB47C43)

@Composable fun BearTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = lightColorScheme(primary = Forest, onPrimary = Color.White,
        background = Paper, surface = Color.White, onBackground = Ink, onSurface = Ink,
        secondaryContainer = Sage, onSecondaryContainer = Forest), content = content)
}

@Composable fun Panel(modifier: Modifier = Modifier, color: Color = Color.White, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.background(color, RoundedCornerShape(24.dp)).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
}

@Composable fun SectionTitle(title: String, subtitle: String = "") {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, fontSize = 26.sp, fontWeight = FontWeight.Bold, color = Ink)
        if (subtitle.isNotEmpty()) Text(subtitle, color = Muted, fontSize = 14.sp)
    }
}

@Composable fun Tag(text: String, color: Color = Forest) {
    Text(text, color = color, fontSize = 12.sp, modifier = Modifier
        .background(color.copy(alpha = .09f), RoundedCornerShape(8.dp)).padding(horizontal = 10.dp, vertical = 6.dp))
}

@Composable fun Bear(modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val factor = minOf(size.width / 220f, size.height / 240f)
        scale(factor, factor, pivot = Offset.Zero) {
            val fur = Color(0xFFC99566)
            val light = Color(0xFFF2DDBB)
            val dark = Color(0xFF4E392D)
            drawOval(Color(0xFFD8E0CF), Offset(20f, 215f), Size(180f, 20f))
            drawOval(Forest, Offset(53f, 128f), Size(116f, 97f))
            drawCircle(fur, 28f, Offset(48f, 55f)); drawCircle(fur, 28f, Offset(172f, 55f))
            drawCircle(light, 16f, Offset(48f, 55f)); drawCircle(light, 16f, Offset(172f, 55f))
            drawOval(fur, Offset(33f, 42f), Size(154f, 123f))
            drawOval(light, Offset(77f, 101f), Size(66f, 48f))
            drawCircle(dark, 5f, Offset(77f, 97f)); drawCircle(dark, 5f, Offset(143f, 97f))
            drawCircle(Color.White, 1.5f, Offset(78f, 95f)); drawCircle(Color.White, 1.5f, Offset(144f, 95f))
            drawOval(dark, Offset(102f, 110f), Size(16f, 11f))
            drawPath(Path().apply { moveTo(98f, 130f); quadraticTo(110f, 140f, 122f, 130f) }, dark, style = Stroke(2.5f))
            drawOval(Color(0xFFD68973).copy(alpha = .6f), Offset(51f, 112f), Size(22f, 10f))
            drawOval(Color(0xFFD68973).copy(alpha = .6f), Offset(148f, 112f), Size(22f, 10f))
            drawRoundRect(light, Offset(63f, 177f), Size(94f, 45f), androidx.compose.ui.geometry.CornerRadius(7f))
            drawLine(Ochre, Offset(110f, 180f), Offset(110f, 220f), 2f)
            drawOval(fur, Offset(40f, 169f), Size(36f, 28f)); drawOval(fur, Offset(145f, 169f), Size(36f, 28f))
        }
    }
}

fun Subject.tint() = when (this) { Subject.MATH -> Forest; Subject.CHINESE -> Ochre; Subject.ENGLISH -> Color(0xFF6C6AA0) }
