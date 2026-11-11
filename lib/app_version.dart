/// 应用版本信息
///
/// CI 构建时通过 --dart-define 注入真实构建号（GITHUB run_number），
/// 本地运行时回退到 pubspec 里的默认值。
class AppVersion {
  static const name = String.fromEnvironment('APP_VERSION', defaultValue: '1.2.0');
  static const build = String.fromEnvironment('APP_BUILD', defaultValue: '1');
  static String get full => 'v$name ($build)';
}
