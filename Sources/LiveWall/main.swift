import AppKit
import Darwin

if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--smoke-test-steam-setup" {
    exit(SmokeTestRunner.runSteamSetup())
} else if CommandLine.arguments.count == 2,
          CommandLine.arguments[1] == "--smoke-test-audio-analyzer" {
    exit(SmokeTestRunner.runAudioAnalyzer())
} else if CommandLine.arguments.count == 4,
   CommandLine.arguments[1] == "--smoke-test-workshop-link" {
    exit(SmokeTestRunner.runWorkshopLink(
        rawLink: CommandLine.arguments[2],
        accountName: CommandLine.arguments[3]
    ))
} else if CommandLine.arguments.count == 3,
          CommandLine.arguments[1] == "--smoke-test-project" {
    exit(SmokeTestRunner.run(manifestPath: CommandLine.arguments[2]))
} else if CommandLine.arguments.count == 3,
          CommandLine.arguments[1] == "--smoke-test-interactive-project" {
    exit(SmokeTestRunner.run(
        manifestPath: CommandLine.arguments[2],
        interactive: true
    ))
} else if CommandLine.arguments.count == 3,
          CommandLine.arguments[1] == "--smoke-test-property-editor" {
    exit(SmokeTestRunner.runPropertyEditor(
        manifestPath: CommandLine.arguments[2]
    ))
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
