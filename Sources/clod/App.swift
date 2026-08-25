import AppKit
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let model = UsageModel()
  var statusItem: NSStatusItem!

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    model.start()

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: nil)
    }

    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu

    observeModel()
  }

  private func observeModel() {
    withObservationTracking {
      statusItem.button?.title = model.menuBarTitle.isEmpty ? "" : " \(model.menuBarTitle)"
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observeModel() }
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    model.refreshIfStale()
    buildMenu(menu)
  }

  private func buildMenu(_ menu: NSMenu) {
    menu.removeAllItems()

    if let usage = model.usage {
      let now = Date()
      var sections: [[NSMenuItem]] = []

      if let fiveHour = usage.fiveHour {
        var rows = [disabled("5h: \(fiveHour.utilization.percent)")]
        if let resetsAt = fiveHour.resetsAt, resetsAt > now {
          rows.append(
            disabled(
              "Resets \(resetsAt.formatted(date: .omitted, time: .shortened)) (\(relative(until: resetsAt)))"
            ))
        }
        sections.append(rows)
      }

      if let sevenDay = usage.sevenDay {
        var rows = [disabled("7d: \(sevenDay.utilization.percent)")]
        if let resetsAt = sevenDay.resetsAt {
          rows.append(
            disabled("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))"))
        }
        sections.append(rows)
      }

      if let credits = usage.credits {
        sections.append([disabled("Credits: \(credits.used) of \(credits.limit)")])
      }

      for (index, rows) in sections.enumerated() {
        if index > 0 { menu.addItem(.separator()) }
        rows.forEach(menu.addItem)
      }
    } else if let error = model.error {
      menu.addItem(disabled(error))
    } else {
      menu.addItem(disabled("Loading..."))
    }

    menu.addItem(.separator())
    if CLIInstaller.isInstalled {
      menu.addItem(disabled("'clod' helper installed in ~/.local/bin"))
    } else {
      menu.addItem(
        NSMenuItem(
          title: "Install 'clod' CLI helper...", action: #selector(installCLI), keyEquivalent: ""))
    }

    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
    menu.addItem(NSMenuItem(title: "Quit clod", action: #selector(quit), keyEquivalent: "q"))
  }

  private func disabled(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  @objc private func refresh() { model.refreshNow() }
  @objc private func quit() { NSApplication.shared.terminate(nil) }

  @objc private func installCLI() {
    let alert = NSAlert()
    do {
      try CLIInstaller.install()
      alert.messageText = "Installed"
      alert.informativeText = "Run 'clod' in your terminal to show usage."
    } catch {
      alert.messageText = "Couldn't install"
      alert.informativeText = error.localizedDescription
      alert.alertStyle = .warning
    }
    alert.runModal()
  }

  private func relative(until date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSinceNow))
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    return hours > 0 ? "in \(hours)h \(minutes)m" : "in \(minutes)m"
  }
}

@main
enum Main {
  static func main() {
    if CommandLine.arguments.contains("--usage") || isatty(STDOUT_FILENO) != 0 {
      Task { @MainActor in
        do {
          let usage = try await UsageFetcher().fetch()
          let now = Date()
          if let fh = usage.fiveHour {
            print("5 hour usage: \(fh.utilization.percent)")
            if let resetsAt = fh.resetsAt, resetsAt > now {
              let minutes = Int(resetsAt.timeIntervalSince(now) / 60)
              print("resets at: \(resetsAt.formatted()) (in \(minutes) minutes)")
            }
          }
          if let sd = usage.sevenDay {
            print("7 day usage: \(sd.utilization.percent)")
            if let resetsAt = sd.resetsAt {
              print("resets at: \(resetsAt.formatted())")
            }
          }
          if let credits = usage.credits {
            print("credits: \(credits.used) of \(credits.limit)")
          }
        } catch {
          fputs("Error: \(error.localizedDescription)\n", stderr)
        }
        exit(0)
      }
      RunLoop.main.run()
      return
    }

    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
  }
}

extension Double {
  var percent: String { "\(Int(rounded()))%" }
}
