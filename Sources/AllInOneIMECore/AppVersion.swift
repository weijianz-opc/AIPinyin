/// The version of AllInOneIME, shown by `--status` (`make status`) and `allinoneime-cli --version`.
/// Resources/Info.plist, Resources/Settings-Info.plist and Resources/Installer-Info.plist carry the
/// same CFBundleShortVersionString (and one CFBundleVersion); `AppVersionTests` fails when they drift
/// apart, so bump all four together.
public enum AppVersion {
    public static let string = "0.5.0"
}
