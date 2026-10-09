/// The version of AllInOneIME, shown by `--status` (`make status`) and `allinoneime-cli --version`.
/// Resources/Info.plist and Resources/Settings-Info.plist carry the same CFBundleShortVersionString;
/// `AppVersionTests` fails when they drift apart, so bump all three together.
public enum AppVersion {
    public static let string = "0.2.0"
}
