import Cocoa
import FlutterMacOS

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

    super.awakeFromNib()
  }

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
