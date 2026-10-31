import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // No title bar: the app's content runs to the top edge, with only the
    // window buttons floating over it. The strip under them still drags the window.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)

    // As on Linux: 1440×900, shrunk to fit a smaller screen, and centred.
    // The layout needs at least 750×500.
    self.contentMinSize = NSSize(width: 750, height: 500)
    var frame = self.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1440, height: 900))
    if let visible = (self.screen ?? NSScreen.main)?.visibleFrame {
      frame.size.width = min(frame.width, visible.width)
      frame.size.height = min(frame.height, visible.height)
      frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
    }
    self.setFrame(frame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    folders = FlutterMethodChannel(
      name: "eclipse/folders", binaryMessenger: flutterViewController.engine.binaryMessenger)
    folders?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "pick", let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let arguments = call.arguments as? [String: Any]
      self.pickFolder(title: arguments?["title"] as? String, start: arguments?["start"] as? String, result: result)
    }

    reminders = ReminderNotifications(
      channel: FlutterMethodChannel(
        name: "eclipse/notifications", binaryMessenger: flutterViewController.engine.binaryMessenger),
      window: self)

    super.awakeFromNib()
  }

  // Shows the app's reminders in Notification Centre.
  private var reminders: ReminderNotifications?

  // The app asks for a folder over this.
  private var folders: FlutterMethodChannel?

  // Finder's folder panel, as a sheet on this window; nil when cancelled.
  private func pickFolder(title: String?, start: String?, result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = title ?? ""
    panel.prompt = "Choose"
    if let start {
      panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true)
    }
    panel.beginSheetModal(for: self) { response in
      result(response == .OK ? panel.url?.path : nil)
    }
  }
}

// Reminders as notifications from Notification Centre, asked permission for
// the first time one is shown. Clicking one brings the window up and tells the
// app which task it was for; they show while Eclipse is in front too.
class ReminderNotifications: NSObject, UNUserNotificationCenterDelegate {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?

  init(channel: FlutterMethodChannel, window: NSWindow) {
    self.channel = channel
    self.window = window
    super.init()
    UNUserNotificationCenter.current().delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "show", let self, let arguments = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.show(
        key: arguments["key"] as? String ?? "",
        title: arguments["title"] as? String ?? "",
        body: arguments["body"] as? String ?? "")
      result(nil)
    }
  }

  private func show(key: String, title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      content.userInfo = ["key": key]
      center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let key = response.notification.request.content.userInfo["key"] as? String
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      self.window?.makeKeyAndOrderFront(nil)
      if let key {
        self.channel.invokeMethod("clicked", arguments: ["key": key])
      }
    }
    completionHandler()
  }
}
