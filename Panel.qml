import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "thethracian.deskloom"
  ipcTarget: "thethracian.deskloom"
  manageIpc: false

  property bool helperInstalled: false
  property bool busy: false
  property bool installingHelper: false
  property bool installerTimedOut: false
  property bool installerFinished: false
  property string installerAttemptId: ""
  property int installerPolls: 0
  property bool settingsOpen: false
  property string statusText: ""
  property string saveName: "work"
  property string pendingDeleteName: ""
  property string pendingReplaceName: ""
  property string operationKind: ""
  property string operationName: ""
  property var snapshots: []
  property bool bootRestoreAttempted: false
  property bool bootSettingsReady: false
  property int bootSettingsPolls: 0
  property string bootRestorePreset: ""
  property int bootRestoreRetries: 0
  property bool bootRestoreTimedOut: false
  property bool listTimedOut: false
  property bool refreshPending: false
  property bool operationTimedOut: false
  property bool recoveryRunning: false
  property bool recoveryTimedOut: false
  property bool startupRecoveryAttempted: false
  property bool startupRecoveryTimedOut: false

  readonly property string helperVersion: "0.3.6"
  readonly property string helperSourceCommit: "3c0dc714a5874cbe32fba256df9f61fb1df496d7"
  readonly property bool startOnLogin: setting("startOnLogin", false) === true
  readonly property string defaultPreset: String(setting("defaultPreset", "") || "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent

  function settingsAreReady() {
    var values = root.settings
    return values !== null && typeof values === "object"
      && ("startOnLogin" in values || "defaultPreset" in values)
  }

  onSettingsChanged: {
    if (root.settingsAreReady()) bootSettingsReady = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function helperReadyCheck() {
    return "test -x \"$HOME/.local/bin/hyprloom\""
      + " && [ \"$(\"$HOME/.local/bin/hyprloom\" --version 2>/dev/null)\" = \"hyprloom "
      + root.helperVersion
      + "\" ]"
      + " && \"$HOME/.local/bin/hyprloom\" --help >/dev/null 2>&1"
      + " && test -f \"$HOME/.local/bin/.hyprloom.sha256\""
      + " && [ \"$(cat -- \"$HOME/.local/bin/.hyprloom.sha256\")\" = \""
      + root.helperSourceCommit
      + " $(sha256sum -- \"$HOME/.local/bin/hyprloom\" | cut -d' ' -f1)\" ]"
  }

  function helperProcessCommand(arguments) {
    var command = [
      "bash", "-c", "exec \"$HOME/.local/bin/hyprloom\" \"$@\"", "deskloom"
    ]
    for (var index = 0; index < arguments.length; index++)
      command.push(String(arguments[index]))
    return command
  }

  function checkHelper() {
    if (helperCheck.running) return
    helperCheck.command = [
      "bash", "-c",
      root.helperReadyCheck() + " && printf ready || printf missing"
    ]
    helperCheck.running = true
  }

  function refreshList() {
    if (!helperInstalled) return
    if (!startupRecoveryAttempted) {
      refreshPending = true
      startStartupRecovery()
      return
    }
    if (startupRecoveryProcess.running) {
      refreshPending = true
      return
    }
    if (listProcess.running) {
      refreshPending = true
      return
    }
    refreshPending = false
    listTimedOut = false
    listProcess.command = root.helperProcessCommand(["list"])
    listProcess.running = true
    listTimeout.restart()
  }

  function startStartupRecovery() {
    if (!root.helperInstalled || root.startupRecoveryAttempted || startupRecoveryProcess.running)
      return
    root.startupRecoveryAttempted = true
    root.startupRecoveryTimedOut = false
    root.busy = true
    root.statusText = "Checking for interrupted replacement…"
    startupRecoveryProcess.command = root.helperProcessCommand(["recover"])
    startupRecoveryProcess.running = true
    startupRecoveryTimeout.restart()
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    var current = root.settings || ({})
    for (var existing in current) if (existing !== "id") entry[existing] = current[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    var shell = root.bar && root.bar.shell ? root.bar.shell : null
    if (shell && typeof shell.mutateShellConfig === "function") {
      shell.mutateShellConfig(function(config) {
        var sections = ["left", "center", "right"]
        var found = false
        function merge(item) {
          if (!item || String(item.id || "") !== root.moduleName) return false
          for (var setting in values) if (setting !== "id") item[setting] = values[setting]
          return true
        }
        var layout = config.bar && config.bar.layout ? config.bar.layout : null
        if (layout) {
          for (var section = 0; section < sections.length; section++) {
            var entries = layout[sections[section]]
            if (!Array.isArray(entries)) continue
            for (var index = 0; index < entries.length; index++)
              if (merge(entries[index])) found = true
          }
        }
        if (!found && Array.isArray(config.plugins)) {
          for (var plugin = 0; plugin < config.plugins.length; plugin++)
            if (merge(config.plugins[plugin])) found = true
        }
      })
    } else if (shell && typeof shell.updateEntryInline === "function") {
      shell.updateEntryInline(root.moduleName, entry)
    }
  }

  function setDefaultPreset(name) {
    persistSettings({ defaultPreset: String(name || "") })
    statusText = name ? "Default preset set to '" + name + "'." : "Default preset cleared."
  }

  function restoreDefaultAtBoot() {
    if (bootRestoreAttempted) return
    if (!bootSettingsReady) {
      // The bar injects widget settings after the QML component is created.
      // Give that hand-off a bounded grace period, then use the manifest
      // defaults even if this install has no custom settings entry yet.
      if (bootSettingsPolls < 5) {
        bootSettingsPolls += 1
        bootRestoreTimer.interval = 1000
        bootRestoreTimer.restart()
        return
      }
      bootSettingsReady = true
    }

    if (root.helperInstalled) {
      if (root.startupRecoveryProcessRunning()) {
        bootRestoreTimer.interval = 1000
        bootRestoreTimer.restart()
        return
      }
    } else if (helperCheck.running) {
      bootRestoreTimer.interval = 1000
      bootRestoreTimer.restart()
      return
    }
    bootRestoreAttempted = true

    if (!root.startOnLogin || root.defaultPreset === "") return

    bootRestorePreset = root.defaultPreset
    bootRestoreRetries = 0
    busy = true
    statusText = "Restoring default preset…"
    bootHelperProbe.running = true
  }

  function startupRecoveryProcessRunning() {
    if (!root.startupRecoveryAttempted) {
      root.startStartupRecovery()
      return true
    }
    return startupRecoveryProcess.running
  }

  function launchBootRestore() {
    // Bar widgets are instantiated once per monitor.  A user should get one
    // boot restore, not one restore per monitor, so serialize the operation
    // with a user-scoped lock and a per-login claim.
    bootRestoreProcess.command = [
      "bash", "-c",
      "set -eu; umask 077; "
        + "lock_root=\"${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}\"; "
        + "if [ -L \"$lock_root\" ] || [ -e \"$lock_root\" ] && [ ! -d \"$lock_root\" ]; then exit 1; fi; "
        + "lock_dir=\"$lock_root/deskloom\"; "
        + "if [ -L \"$lock_dir\" ] || [ -e \"$lock_dir\" ] && [ ! -d \"$lock_dir\" ]; then exit 1; fi; "
        + "mkdir -p \"$lock_dir\"; chmod 700 \"$lock_dir\"; "
        + "test -O \"$lock_dir\"; lock_file=\"$lock_dir/boot.lock\"; "
        + "if [ -L \"$lock_file\" ] || [ -e \"$lock_file\" ] && [ ! -f \"$lock_file\" ]; then exit 1; fi; "
        + "exec 9>\"$lock_file\"; "
        + "flock -n 9 || exit 75; "
        + "claim_file=\"$lock_dir/boot-claim\"; "
        + "if [ -L \"$claim_file\" ] || [ -e \"$claim_file\" ] && [ ! -f \"$claim_file\" ]; then exit 1; fi; "
        + "session_id=\"${XDG_SESSION_ID:-}\"; "
        + "boot_id=\"\"; "
        + "if [ -r /proc/sys/kernel/random/boot_id ]; then IFS= read -r boot_id < /proc/sys/kernel/random/boot_id || true; fi; "
        + "instance_id=\"${HYPRLAND_INSTANCE_SIGNATURE:-${WAYLAND_DISPLAY:-deskloom}}\"; "
        + "if [ -n \"$boot_id\" ]; then claim_key=\"$boot_id:${session_id:-$instance_id}\"; "
        + "else claim_key=\"${session_id:-$instance_id}\"; fi; "
        + "if [ -f \"$claim_file\" ]; then previous=\"\"; previous_status=\"\"; "
        + "{ IFS= read -r previous || true; IFS= read -r previous_status || true; } < \"$claim_file\"; "
        + "if [ \"$previous\" = \"$claim_key\" ] && [ \"$previous_status\" = complete ]; then exit 76; fi; fi; "
        + "temporary=$(mktemp \"$lock_dir/.boot-claim.XXXXXX\"); "
        + "printf \"%s\\n%s\\n\" \"$claim_key\" in-progress > \"$temporary\"; chmod 600 \"$temporary\"; "
        + "mv -f \"$temporary\" \"$claim_file\"; "
        + "child_pid=\"\"; "
        + "cleanup() { status=$?; "
        + "if [ -n \"$child_pid\" ]; then kill -TERM \"$child_pid\" 2>/dev/null || true; "
        + "wait \"$child_pid\" 2>/dev/null || true; fi; "
        + "if [ \"$status\" -ne 0 ]; then rm -f -- \"$claim_file\" || true; fi; "
        + "trap - EXIT TERM INT; exit \"$status\"; }; "
        + "trap cleanup EXIT TERM INT; "
        + "\"$HOME/.local/bin/hyprloom\" restore \"$1\" --reconcile & child_pid=$!; "
        + "if wait \"$child_pid\"; then restore_status=0; else restore_status=$?; fi; "
        + "child_pid=\"\"; "
        + "if [ \"$restore_status\" -eq 0 ]; then completed=$(mktemp \"$lock_dir/.boot-claim.XXXXXX\"); "
        + "printf \"%s\\n%s\\n\" \"$claim_key\" complete > \"$completed\"; chmod 600 \"$completed\"; "
        + "mv -f \"$completed\" \"$claim_file\"; fi; exit \"$restore_status\"",
      "deskloom", root.bootRestorePreset
    ]
    bootRestoreTimedOut = false
    bootRestoreProcess.running = true
    bootRestoreTimeout.restart()
  }

  function openHelperInstaller() {
    if (busy || helperInstalled) return
    installerTimedOut = false
    installerFinished = false
    installerAttemptId = String(Date.now())
    installerPolls = 0
    installingHelper = true
    busy = true
    statusText = "Opening the installer terminal…"
    var installCommand = "bash -c 'set -eu; umask 077; "
      + "lock_root=\"${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}\"; "
      + "if [ -L \"$lock_root\" ] || [ -e \"$lock_root\" ] && [ ! -d \"$lock_root\" ]; then exit 1; fi; "
      + "lock_dir=\"$lock_root/deskloom\"; "
      + "if [ -L \"$lock_dir\" ] || [ -e \"$lock_dir\" ] && [ ! -d \"$lock_dir\" ]; then exit 1; fi; "
      + "mkdir -p \"$lock_dir\"; chmod 700 \"$lock_dir\"; test -O \"$lock_dir\"; "
      + "lock_file=\"$lock_dir/aur-install.lock\"; "
      + "if [ -L \"$lock_file\" ] || [ -e \"$lock_file\" ] && [ ! -f \"$lock_file\" ]; then exit 1; fi; "
      + "exec 9>\"$lock_file\"; flock -n 9 || exit 75; "
      + "result_file=\"$lock_dir/aur-install-result-$1\"; "
      + "if [ -L \"$result_file\" ] || [ -e \"$result_file\" ] && [ ! -f \"$result_file\" ]; then exit 1; fi; "
      + "rm -f \"$result_file\"; "
      + "installer=\"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/thethracian.deskloom/install-helper.sh\"; "
      + "if [ ! -x \"$installer\" ]; then code=1; result=failure; "
      + "elif \"$installer\"; then code=0; result=success; "
      + "else code=$?; result=failure; fi; "
      + "temporary=$(mktemp \"$lock_dir/.aur-install-result.XXXXXX\"); "
      + "printf \"%s\\n\" \"$result\" > \"$temporary\"; chmod 600 \"$temporary\"; "
      + "mv -f \"$temporary\" \"$result_file\"; exit \"$code\"' deskloom "
      + installerAttemptId
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      installCommand
    ])
    installPoll.start()
    installTimeout.start()
  }

  function checkInstallerResult() {
    if (!root.installingHelper || installerResultProbe.running) return
    installerResultProbe.command = [
      "bash", "-c",
      "set -eu; lock_root=\"${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}\"; "
        + "if [ -L \"$lock_root\" ] || [ -e \"$lock_root\" ] && [ ! -d \"$lock_root\" ]; then exit 1; fi; "
        + "lock_dir=\"$lock_root/deskloom\"; "
        + "if [ -L \"$lock_dir\" ] || [ -e \"$lock_dir\" ] && [ ! -d \"$lock_dir\" ]; then exit 1; fi; "
        + "mkdir -p \"$lock_dir\"; chmod 700 \"$lock_dir\"; test -O \"$lock_dir\"; "
        + "result_file=\"$lock_dir/aur-install-result-$1\"; "
        + "if [ -L \"$result_file\" ] || [ -e \"$result_file\" ] && [ ! -f \"$result_file\" ]; then exit 1; fi; "
        + "if [ -f \"$result_file\" ]; then cat \"$result_file\"; fi",
      "deskloom", installerAttemptId
    ]
    installerResultProbe.running = true
  }

  function checkInstallerLock() {
    if (installerLockProbe.running) return
    installerLockProbe.command = [
      "bash", "-c",
      "set -eu; lock_root=\"${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}\"; "
        + "if [ -L \"$lock_root\" ] || [ -e \"$lock_root\" ] && [ ! -d \"$lock_root\" ]; then exit 1; fi; "
        + "lock_dir=\"$lock_root/deskloom\"; "
        + "if [ -L \"$lock_dir\" ] || [ -e \"$lock_dir\" ] && [ ! -d \"$lock_dir\" ]; then exit 1; fi; "
        + "mkdir -p \"$lock_dir\"; chmod 700 \"$lock_dir\"; test -O \"$lock_dir\"; "
        + "lock_file=\"$lock_dir/aur-install.lock\"; "
        + "if [ -L \"$lock_file\" ] || [ -e \"$lock_file\" ] && [ ! -f \"$lock_file\" ]; then exit 1; fi; "
        + "exec 9>\"$lock_file\"; "
        + "if flock -n 9; then printf free; else printf busy; fi"
    ]
    installerLockProbe.running = true
  }

  function normalizeName(value) {
    var clean = String(value || "").trim().toLowerCase()
    clean = clean.replace(/[^a-z0-9._-]+/g, "-")
    clean = clean.replace(/^-+|-+$/g, "")
    return clean
  }

  function isValidSaveName(value) {
    var clean = root.normalizeName(value)
    return clean !== ""
      && clean !== "."
      && clean !== ".."
      && clean.length <= 128
      && clean.indexOf("autosave-") !== 0
  }

  function runOperation(kind, name) {
    if (busy) return
    if (!helperInstalled) return

    var operationArgument = String(name || "")
    if (kind === "save") {
      operationArgument = normalizeName(name)
      if (!isValidSaveName(name)) {
        statusText = "Use a unique name; '.', '..', autosave names, and names over 128 characters are reserved."
        return
      }
    }

    operationKind = kind
    operationName = operationArgument
    operationTimedOut = false
    busy = true
    statusText = "Working…"

    if (kind === "save") {
      operationProcess.command = root.helperProcessCommand(["save", operationArgument, "--force"])
    } else if (kind === "restore") {
      operationProcess.command = root.helperProcessCommand(["restore", name, "--reconcile"])
    } else if (kind === "replace") {
      // hyprloom loads and validates the target, captures a safety backup,
      // closes windows, and reconciles in one helper process.  This keeps
      // Replace from destroying the current desktop after a stale preflight.
      operationProcess.command = root.helperProcessCommand(["replace", name])
    } else if (kind === "delete") {
      operationProcess.command = root.helperProcessCommand(["delete", name])
    } else {
      busy = false
      return
    }

    operationProcess.running = true
    operationTimeout.restart()
  }

  function parseList(output) {
    var next = []
    var text = String(output || "")
    var lines = text.split("\n")
    var rowPattern = /^\s*(.*?)\s+—\s+(\d+)\s+windows?\s+\(([^)]+)\)(.*)$/
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var match = line.match(rowPattern)
      if (!match) continue
      next.push({
        name: match[1].trim(),
        windows: Number(match[2]),
        created: match[3].trim(),
        automatic: match[4].indexOf("[auto]") !== -1
      })
    }
    snapshots = next
    var complete = text.indexOf("Saved sessions:") !== -1 || text.indexOf("No saved sessions.") !== -1
    if (complete && root.defaultPreset !== ""
        && !next.some(function(snapshot) { return snapshot.name === root.defaultPreset })) {
      root.persistSettings({ defaultPreset: "" })
      if (!root.busy) root.statusText = "Default preset cleared because its snapshot no longer exists."
    }
  }

  function operationSummary(preferError) {
    var output = String(operationOutput.text || "").trim()
    var error = String(operationError.text || "").trim()
    var source = preferError && error !== "" ? error : (output !== "" ? output : error)
    var firstLine = source.split("\n")[0].trim()
    return firstLine !== "" ? firstLine : "Done"
  }

  function startTimedOutReplaceRecovery() {
    root.recoveryTimedOut = false
    recoveryProcess.command = root.helperProcessCommand(["recover"])
    recoveryProcess.running = true
    recoveryTimeout.restart()
  }

  Component.onCompleted: {
    if (root.settingsAreReady()) bootSettingsReady = true
    checkHelper()
  }

  Timer {
    id: bootRestoreTimer
    interval: 4000
    repeat: false
    running: true
    onTriggered: root.restoreDefaultAtBoot()
  }

  Timer {
    id: installPoll
    interval: 1000
    repeat: true
    onTriggered: {
      root.checkHelper()
      if (root.installingHelper) {
        root.installerPolls += 1
        root.checkInstallerResult()
        if (root.installerPolls >= 5) root.checkInstallerLock()
      }
    }
  }

  Process {
    id: installerResultProbe
    stdout: StdioCollector {
      id: installerResultOutput
      waitForEnd: true
    }
    onExited: function() {
      if (!root.installingHelper) return
      var result = String(installerResultOutput.text || "").trim()
      if (result === "failure") {
        root.installerFinished = true
        root.installingHelper = false
        root.busy = false
        root.statusText = "Installation failed. Try again."
        installPoll.stop()
        installTimeout.stop()
      } else if (result === "success") {
        root.installerFinished = true
        root.installerTimedOut = false
        root.statusText = "Installer finished; checking hyprloom…"
        root.checkHelper()
      }
    }
  }

  Process {
    id: installerLockProbe
    stdout: StdioCollector {
      id: installerLockOutput
      waitForEnd: true
    }
    onExited: function() {
      if (!root.installingHelper || root.installerPolls < 5) return
      if (String(installerLockOutput.text || "").trim() === "free") {
        root.installingHelper = false
        root.busy = false
        root.statusText = "Installer stopped before hyprloom was ready. Try again."
        installPoll.stop()
        installTimeout.stop()
      }
    }
  }

  Timer {
    id: installTimeout
    interval: 180000
    repeat: false
    onTriggered: {
      if (!root.installingHelper) return
      // The AUR terminal is deliberately detached, so the panel cannot kill
      // or await it directly.  Keep the UI serialized until its user-scoped
      // lock is free; a second click must never start a concurrent pacman job.
      root.installerTimedOut = true
      root.busy = true
      root.statusText = "Installation is still running…"
      root.checkInstallerLock()
    }
  }

  Timer {
    id: bootRestoreTimeout
    interval: 180000
    repeat: false
    onTriggered: {
      if (!bootRestoreProcess.running) return
      root.bootRestoreTimedOut = true
      bootRestoreProcess.running = false
      root.busy = true
      root.statusText = "Default preset restore is still stopping…"
    }
  }

  Timer {
    id: bootRestoreRetryTimer
    interval: 1500
    repeat: false
    onTriggered: {
      if (root.bootRestorePreset !== "") root.launchBootRestore()
    }
  }

  Timer {
    id: listTimeout
    interval: 30000
    repeat: false
    onTriggered: {
      if (!listProcess.running) return
      root.listTimedOut = true
      listProcess.running = false
      root.statusText = "Refreshing snapshots timed out."
    }
  }

  Timer {
    id: startupRecoveryTimeout
    interval: 180000
    repeat: false
    onTriggered: {
      if (!startupRecoveryProcess.running) return
      root.startupRecoveryTimedOut = true
      startupRecoveryProcess.running = false
      root.busy = true
      root.statusText = "Startup recovery is still stopping…"
    }
  }

  Timer {
    id: operationTimeout
    interval: 180000
    repeat: false
    onTriggered: {
      if (!operationProcess.running) return
      root.operationTimedOut = true
      root.busy = true
      if (root.operationKind === "replace") {
        // Replace may already have closed part of the desktop and left its
        // transaction marker behind.  Stop the helper, then invoke the
        // helper's recovery-only path before releasing the UI lock.
        root.recoveryRunning = true
        operationProcess.running = false
        root.statusText = "Replace timed out; recovering desktop…"
      } else {
        operationProcess.running = false
        root.statusText = "Operation is still stopping…"
      }
    }
  }

  Process {
    id: helperCheck
    stdout: StdioCollector {
      id: helperOutput
      waitForEnd: true
    }
    onExited: function() {
      root.helperInstalled = String(helperOutput.text || "").trim() === "ready"
      if (root.helperInstalled) {
        if (root.installingHelper) {
          root.installingHelper = false
          root.installerTimedOut = false
          root.busy = false
          root.statusText = "hyprloom is ready."
          installPoll.stop()
          installTimeout.stop()
        }
        root.refreshList()
      } else {
        root.snapshots = []
        if (root.installingHelper && root.installerFinished) {
          root.installingHelper = false
          root.busy = false
          root.statusText = "Installer finished but hyprloom is not available. Try again."
          installPoll.stop()
          installTimeout.stop()
        } else if (!root.installingHelper && !root.busy) {
          root.statusText = "hyprloom is not installed."
        }
      }
    }
  }

  Process {
    id: bootHelperProbe
    command: [
      "bash", "-c",
      root.helperReadyCheck()
    ]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.busy = false
        root.statusText = "Default preset skipped: hyprloom is not installed."
        return
      }
      root.helperInstalled = true
      if (root.startupRecoveryProcessRunning()) {
        root.bootRestoreAttempted = false
        bootRestoreTimer.interval = 1000
        bootRestoreTimer.restart()
      } else {
        root.launchBootRestore()
      }
    }
  }

  Process {
    id: startupRecoveryProcess
    stdout: StdioCollector {
      id: startupRecoveryOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: startupRecoveryError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      startupRecoveryTimeout.stop()
      var timedOut = root.startupRecoveryTimedOut
      root.startupRecoveryTimedOut = false
      root.busy = false

      if (timedOut) {
        root.statusText = "Startup recovery timed out; continuing carefully."
      } else if (exitCode !== 0) {
        var error = String(startupRecoveryError.text || "").trim().split("\n")[0]
        root.statusText = "Startup recovery failed"
          + (error === "" ? ". Continuing carefully." : ": " + error)
      }

      if (root.refreshPending)
        Qt.callLater(function() { if (root.helperInstalled) root.refreshList() })
    }
  }

  Process {
    id: bootRestoreProcess
    stdout: StdioCollector {
      id: bootRestoreOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: bootRestoreError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      bootRestoreTimeout.stop()
      if (root.bootRestoreTimedOut) {
        root.bootRestoreTimedOut = false
        root.busy = false
        root.statusText = "Default preset restore stopped after timing out."
        return
      }
      root.busy = false
      if (exitCode === 75) {
        if (root.bootRestoreRetries < 3) {
          root.bootRestoreRetries += 1
          root.busy = true
          root.statusText = "Default preset restore is busy; retrying…"
          bootRestoreRetryTimer.interval = 1000 * root.bootRestoreRetries
          bootRestoreRetryTimer.restart()
        } else {
          root.statusText = "Default preset restore is already running."
        }
      } else if (exitCode === 76) {
        root.statusText = "Default preset already restored this session."
      } else if (exitCode === 0) {
        root.statusText = "Default preset reconciled: '" + root.bootRestorePreset + "'."
        root.refreshList()
      } else {
        var output = String(bootRestoreOutput.text || "")
        var onlySafeSkips = output.indexOf("SKIP:") >= 0
          && output.indexOf("FAIL:") < 0
        if (onlySafeSkips) {
          root.statusText = "Default preset partially applied; some windows were skipped safely."
          root.refreshList()
          return
        }
        var error = String(bootRestoreError.text || "").trim().split("\n")[0]
        if (root.bootRestoreRetries < 3) {
          root.bootRestoreRetries += 1
          root.busy = true
          root.statusText = "Default preset restore failed; retrying…"
          bootRestoreRetryTimer.interval = 1000 * root.bootRestoreRetries
          bootRestoreRetryTimer.restart()
        } else {
          root.statusText = "Default preset restore failed"
            + (error === "" ? "." : ": " + error)
        }
      }
    }
  }

  Process {
    id: listProcess
    stdout: StdioCollector {
      id: listOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: listError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      listTimeout.stop()
      if (root.listTimedOut) {
        root.listTimedOut = false
        if (root.refreshPending && root.helperInstalled)
          Qt.callLater(function() { root.refreshList() })
        else
          root.refreshPending = false
        return
      }
      if (!root.helperInstalled) {
        root.snapshots = []
        root.refreshPending = false
        return
      }
      if (exitCode === 0) {
        root.parseList(listOutput.text)
      } else {
        var error = String(listError.text || "").trim().split("\n")[0]
        root.statusText = "Could not refresh snapshots"
          + (error === "" ? "." : ": " + error)
      }
      if (root.refreshPending)
        Qt.callLater(function() { if (root.helperInstalled) root.refreshList() })
    }
  }

  Process {
    id: operationProcess
    stdout: StdioCollector {
      id: operationOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: operationError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      operationTimeout.stop()
      if (root.recoveryRunning) {
        root.operationTimedOut = false
        root.startTimedOutReplaceRecovery()
        return
      }
      if (root.operationTimedOut) {
        root.operationTimedOut = false
        root.busy = false
        root.statusText = "Operation stopped after timing out. Try again."
        root.pendingDeleteName = ""
        root.pendingReplaceName = ""
        root.operationKind = ""
        root.operationName = ""
        root.refreshList()
        return
      }
      root.busy = false
      if (exitCode === 0) {
        if (root.operationKind === "delete" && root.defaultPreset === root.operationName)
          root.persistSettings({ defaultPreset: "" })
        root.statusText = root.operationSummary(false)
        root.pendingDeleteName = ""
        root.pendingReplaceName = ""
        root.operationKind = ""
        root.operationName = ""
        root.refreshList()
      } else {
        root.statusText = "Operation failed: " + root.operationSummary(true)
      }
    }
  }

  Timer {
    id: recoveryTimeout
    interval: 180000
    repeat: false
    onTriggered: {
      if (!recoveryProcess.running) return
      root.recoveryTimedOut = true
      recoveryProcess.running = false
      root.busy = true
      root.statusText = "Desktop recovery is still stopping…"
    }
  }

  Process {
    id: recoveryProcess
    stdout: StdioCollector {
      id: recoveryOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: recoveryError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      recoveryTimeout.stop()
      var timedOut = root.recoveryTimedOut
      root.recoveryTimedOut = false
      root.recoveryRunning = false
      root.busy = false

      if (timedOut) {
        root.statusText = "Desktop recovery timed out; try Restore again."
      } else if (exitCode === 0) {
        root.statusText = "Replace timed out; desktop recovery completed."
      } else {
        var error = String(recoveryError.text || "").trim().split("\n")[0]
        root.statusText = "Desktop recovery failed"
          + (error === "" ? ". Try Restore again." : ": " + error)
      }
      root.pendingDeleteName = ""
      root.pendingReplaceName = ""
      root.operationKind = ""
      root.operationName = ""
      root.refreshList()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "⧉"
    active: root.opened
    tooltipText: "Deskloom workspace snapshots"
    onPressed: root.toggle()
  }

  PopupCard {
    id: popup
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: popup.fittedContentWidth(Style.space(390))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight)

    Column {
      id: contentColumn
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Column {
          width: parent.width - countBadge.width - settingsButton.width - Style.space(16)
          spacing: Style.space(2)

          Text {
            text: "Deskloom"
            color: root.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            text: root.helperInstalled
              ? "Named workspace snapshots"
              : "Needs the hyprloom helper"
            color: root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Button {
          id: settingsButton
          text: root.settingsOpen ? "Snapshots" : "Settings"
          foreground: root.foreground
          fontFamily: root.bar.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(5)
          bordered: true
          onClicked: {
            root.settingsOpen = !root.settingsOpen
            root.pendingDeleteName = ""
            root.pendingReplaceName = ""
            if (!root.settingsOpen) root.refreshList()
          }
        }

        BorderSurface {
          id: countBadge
          width: Style.space(34)
          height: Style.space(28)
          radius: Style.cornerRadius
          color: Style.selectedFillFor(root.foreground, root.accent)
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

          Text {
            anchors.centerIn: parent
            text: root.snapshots.length
            color: root.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }
      }

      Text {
        width: parent.width
        text: root.statusText
        color: root.statusText.indexOf("failed") >= 0 ? root.urgent : root.dim
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        visible: text !== ""
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: !root.helperInstalled

        Text {
          width: parent.width
          text: "Deskloom uses hyprloom to capture window positions, workspaces, monitors, and app launch commands."
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          width: parent.width
          text: root.busy ? "Installing…" : "Install hyprloom from AUR"
          foreground: root.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          enabled: !root.busy
          onClicked: root.openHelperInstaller()
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.helperInstalled && !root.settingsOpen

        Text {
          text: "SAVE SNAPSHOT"
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          BorderSurface {
            width: parent.width - saveButton.width - Style.space(6)
            height: saveButton.height
            color: root.surface
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
            radius: Style.cornerRadius

            TextInput {
              id: nameInput
              anchors.fill: parent
              anchors.leftMargin: Style.space(9)
              anchors.rightMargin: Style.space(9)
              verticalAlignment: TextInput.AlignVCenter
              color: root.foreground
              selectionColor: root.accent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              text: root.saveName
              onTextChanged: root.saveName = text
              Keys.onReturnPressed: root.runOperation("save", text)
            }
          }

          Button {
            id: saveButton
            text: "Save"
            foreground: root.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            enabled: !root.busy && root.isValidSaveName(root.saveName)
            onClicked: root.runOperation("save", root.saveName)
          }
        }
      }

      PanelSeparator { foreground: root.foreground; visible: root.helperInstalled && !root.settingsOpen }

      Text {
        text: "SAVED SNAPSHOTS"
        color: root.dim
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        visible: root.helperInstalled && !root.settingsOpen
      }

      Text {
        width: parent.width
        text: root.snapshots.length === 0 ? "No snapshots yet. Save the workspace you are in now." : ""
        color: root.dim
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
        visible: root.helperInstalled && !root.settingsOpen && root.snapshots.length === 0
      }

      ListView {
        id: snapshotList
        width: parent.width
        height: Math.min(contentHeight, Style.space(300))
        model: root.snapshots
        spacing: Style.space(6)
        clip: true
        interactive: contentHeight > height
        visible: root.helperInstalled && !root.settingsOpen

        delegate: Item {
          required property var modelData
          width: snapshotList.width
          height: Style.space(58)

          BorderSurface {
            anchors.fill: parent
            color: root.surface
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
            radius: Style.cornerRadius
          }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(9)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(5)

            Column {
              width: parent.width - actionRow.width - Style.space(5)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: modelData.name
                color: root.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: modelData.windows + " window" + (modelData.windows === 1 ? "" : "s")
                  + "  ·  " + modelData.created + (modelData.automatic ? "  ·  auto" : "")
                color: root.dim
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Row {
              id: actionRow
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Button {
                text: "Open"
                foreground: root.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(5)
                enabled: !root.busy
                tooltipText: "Restore without closing current windows"
                onClicked: root.runOperation("restore", modelData.name)
              }

              Button {
                text: root.pendingReplaceName === modelData.name ? "Sure?" : "Replace"
                foreground: root.pendingReplaceName === modelData.name ? root.urgent : root.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(5)
                enabled: !root.busy
                tooltipText: "Close current windows, then restore this snapshot"
                onClicked: {
                  if (root.pendingReplaceName === modelData.name)
                    root.runOperation("replace", modelData.name)
                  else {
                    root.pendingReplaceName = modelData.name
                    root.pendingDeleteName = ""
                    root.statusText = "Click Replace again to close current windows."
                  }
                }
              }

              Button {
                text: root.pendingDeleteName === modelData.name ? "Sure?" : "Delete"
                foreground: root.pendingDeleteName === modelData.name ? root.urgent : root.dim
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(5)
                enabled: !root.busy
                tooltipText: "Delete this saved snapshot"
                onClicked: {
                  if (root.pendingDeleteName === modelData.name)
                    root.runOperation("delete", modelData.name)
                  else {
                    root.pendingDeleteName = modelData.name
                    root.pendingReplaceName = ""
                    root.statusText = "Click Delete again to remove this snapshot."
                  }
                }
              }
            }
          }
        }
      }

      Column {
        id: settingsColumn
        width: parent.width
        spacing: Style.space(10)
        visible: root.settingsOpen

        Text {
          text: "SETTINGS"
          color: root.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Button {
          width: parent.width
          text: root.startOnLogin ? "✓  Start on login" : "□  Start on login"
          foreground: root.foreground
          fontFamily: root.bar.fontFamily
          leftAlign: true
          bordered: true
          active: root.startOnLogin
          enabled: !root.busy
          onClicked: root.persistSettings({ startOnLogin: !root.startOnLogin })
        }

        Text {
          width: parent.width
          text: "Restore the selected default preset a few seconds after Omarchy starts."
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.foreground }

        Text {
          text: "DEFAULT PRESET"
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Text {
          width: parent.width
          text: root.defaultPreset === ""
            ? "None selected"
            : "Current: " + root.defaultPreset
          color: root.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          text: root.helperInstalled
            ? (root.snapshots.length === 0 ? "Save a snapshot first." : "Choose which snapshot should open at login.")
            : "Install hyprloom first to choose a preset."
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        ListView {
          id: defaultPresetList
          width: parent.width
          height: Math.min(contentHeight, Style.space(220))
          model: root.snapshots
          spacing: Style.space(4)
          clip: true
          interactive: contentHeight > height

          delegate: Button {
            required property var modelData
            width: defaultPresetList.width
            text: modelData.name === root.defaultPreset ? "✓  " + modelData.name : "     " + modelData.name
            foreground: root.foreground
            fontFamily: root.bar.fontFamily
            leftAlign: true
            bordered: true
            active: modelData.name === root.defaultPreset
            enabled: !root.busy && root.helperInstalled
            onClicked: root.setDefaultPreset(modelData.name)
          }
        }

        Button {
          width: parent.width
          text: "Clear default preset"
          foreground: root.dim
          fontFamily: root.bar.fontFamily
          bordered: true
          enabled: !root.busy && root.defaultPreset !== ""
          onClicked: root.setDefaultPreset("")
        }

        PanelSeparator { foreground: root.foreground }

        Button {
          width: parent.width
          text: root.busy ? "Working…" : "Refresh snapshots"
          foreground: root.foreground
          fontFamily: root.bar.fontFamily
          enabled: !root.busy && root.helperInstalled
          bordered: true
          onClicked: root.refreshList()
        }

        Text {
          width: parent.width
          text: "Deskloom also refreshes automatically whenever this panel opens."
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.checkHelper()
      Qt.callLater(function() {
        if (root.opened && root.helperInstalled) root.refreshList()
      })
    }
  }
}
