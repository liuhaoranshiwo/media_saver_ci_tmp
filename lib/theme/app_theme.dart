import 'package:flutter/material.dart';

/// 设计 Tokens —— 统一色彩/字号/间距/圆角，全 App 只从这里取值
class AppColors {
  static const primary = Color(0xFF2F6BFF); // 主操作
  static const primaryDark = Color(0xFF1E4FD6);
  static const bg = Color(0xFFF7F8FA); // 页面底色
  static const surface = Color(0xFFFFFFFF); // 卡片
  static const text = Color(0xFF1A1D26); // 一级文字
  static const textSecondary = Color(0xFF6B7280); // 二级文字
  static const textTertiary = Color(0xFF9CA3AF); // 占位/辅助
  static const divider = Color(0xFFEEF0F4);
  static const success = Color(0xFF16A34A);
  static const danger = Color(0xFFEF4444);
  static const liveBadge = Color(0xFFFF3B5C); // LIVE 角标
}

class AppRadius {
  static const card = 16.0;
  static const button = 12.0;
  static const chip = 8.0;
}

class AppSpacing {
  static const xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0, xxl = 32.0;
}

class AppText {
  static const title = TextStyle(
      fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.text, height: 1.3);
  static const subtitle = TextStyle(
      fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.text, height: 1.4);
  static const body = TextStyle(
      fontSize: 14, fontWeight: FontWeight.w400, color: AppColors.text, height: 1.5);
  static const secondary = TextStyle(
      fontSize: 13, fontWeight: FontWeight.w400, color: AppColors.textSecondary, height: 1.4);
  static const caption = TextStyle(
      fontSize: 12, fontWeight: FontWeight.w400, color: AppColors.textTertiary, height: 1.3);
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      surface: AppColors.surface,
    ),
    scaffoldBackgroundColor: AppColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: AppText.subtitle,
      iconTheme: IconThemeData(color: AppColors.text),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.divider, thickness: 0.5),
  );

  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.primary,
        side: const BorderSide(color: AppColors.primary, width: 1.2),
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.l, vertical: AppSpacing.m),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.button),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
      hintStyle: AppText.caption,
    ),
  );
}
