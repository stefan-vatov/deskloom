import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "RestoreReport.js" as RestoreReport

Panel {
  id: root

  moduleName: "thethracian.deskloom"
  ipcTarget: "thethracian.deskloom"
  manageIpc: false

  property bool helperInstalled: false
  property bool busy: false
  property string busyOwner: ""
  property bool installingHelper: false
  property bool installerTimedOut: false
  property bool installerFinished: false
  property string installerAttemptId: ""
  property bool installerLaunched: false
  property string installerResultAttempt: ""
  property int consentGeneration: 0
  property string pendingSaveName: ""
  property string pendingSaveRevision: ""
  property bool listDispatched: false
  property bool operationDispatched: false
  property bool bootDispatched: false
  property bool startupDispatched: false
  property bool recoveryDispatched: false
  property string listErrorText: ""
  property string operationErrorText: ""
  property string bootRestoreErrorText: ""
  property string startupRecoveryErrorText: ""
  property string recoveryErrorText: ""

  // Authoritative dispatch: the pinned helper writes "dispatch: started" on
  // stderr when it acquires its operation lock. Execution deadlines arm only
  // then, so queue time behind another operation is never charged as a hang.
  function noteHelperLine(channel, line) {
    if (line === "") return
    if (line.indexOf("dispatch: started") === 0) {
      if (channel === "list") { listDispatched = true; listTimeout.restart() }
      else if (channel === "operation") { operationDispatched = true; operationTimeout.restart() }
      else if (channel === "boot") { bootDispatched = true; bootRestoreTimeout.restart() }
      else if (channel === "startup") { startupDispatched = true; startupRecoveryTimeout.restart() }
      else if (channel === "recovery") { recoveryDispatched = true; recoveryTimeout.restart() }
      return
    }
    if (channel === "operation") operationErrorText += line + "\n"
    else if (channel === "boot") bootRestoreErrorText += line + "\n"
    else if (channel === "startup") startupRecoveryErrorText += line + "\n"
    else if (channel === "recovery") recoveryErrorText += line + "\n"
    else listErrorText += line + "\n"
  }
  function logConsent(transition) {
    consentGeneration += 1
    console.log("consent generation " + consentGeneration + ": " + transition)
  }
  property int installerPolls: 0
  property bool settingsOpen: false
  property string statusText: ""
  property string saveName: "work"
  property string pendingDeleteName: ""
  property string pendingReplaceRevision: ""
  property string pendingReplaceName: ""
  property string pendingDeleteRevision: ""
  property string operationKind: ""
  property string operationName: ""
  property var snapshots: []
  property bool snapshotsLoaded: false
  property bool snapshotListFailed: false
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

  readonly property string pluginVersion: "0.4.0-dev.5"
  readonly property string helperVersion: "0.4.0-dev.2"
  readonly property string helperSourceCommit: "1be72d8291f0b6af6212b180687eb3a8c037612a"
  readonly property string reportScreenName: root.QsWindow.window && root.QsWindow.window.screen
    ? String(root.QsWindow.window.screen.name) : ""
  readonly property bool startOnLogin: setting("startOnLogin", false) === true
  readonly property string defaultPreset: String(setting("defaultPreset", "") || "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent

  function reportingStatus() {
    var report = restoreReportPopup.report
    return JSON.stringify({
      version: root.pluginVersion,
      helperVersion: root.helperVersion,
      sourceCommit: root.helperSourceCommit,
      componentUrl: String(Qt.resolvedUrl("Panel.qml")),
      monitor: root.reportScreenName,
      helperInstalled: root.helperInstalled,
      busy: root.busy,
      panelOpen: root.opened,
      popupVisible: popup.visible,
      popupMapped: popup.backingWindowVisible,
      nameInputFocused: nameInput.activeFocus,
      snapshotCount: root.snapshots.length,
      snapshotsLoaded: root.snapshotsLoaded,
      snapshotListFailed: root.snapshotListFailed,
      hasReport: report !== null,
      reportOpen: restoreReportPopup.open,
      reportAvailable: report !== null && report.available,
      counts: report !== null ? report.counts : null
    })
  }

  IpcHandler {
    enabled: root.reportScreenName !== ""
    target: "thethracian.deskloom." + encodeURIComponent(root.reportScreenName)
    function status(): string { return root.reportingStatus() }
  }

  function presentRestoreReport(output, error, exitCode, name, timedOut) {
    var model = RestoreReport.parse(
      timedOut ? "" : output,
      timedOut ? 1 : exitCode,
      timedOut ? (error || "Restore timed out; completed window outcomes are unavailable.") : error,
      name
    )
    root.statusText = model.summaryText
    root.close()
    restoreReportPopup.present(model)
  }

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
    // Provenance before behavior: the marker and digest are verified without
    // executing anything; only digest-proven bytes are run for version/help.
    return "test -f \"$HOME/.local/bin/.hyprloom.sha256\""
      + " && [ \"$(cat -- \"$HOME/.local/bin/.hyprloom.sha256\")\" = \""
      + root.helperSourceCommit
      + " $(sha256sum -- \"$HOME/.local/bin/hyprloom\" | cut -d' ' -f1)\" ]"
      + " && test -x \"$HOME/.local/bin/hyprloom\""
      + " && [ \"$(\"$HOME/.local/bin/hyprloom\" --version 2>/dev/null)\" = \"hyprloom "
      + root.helperVersion
      + "\" ]"
      + " && \"$HOME/.local/bin/hyprloom\" --help >/dev/null 2>&1"
  }

  function helperProcessCommand(args) {
    var command = [
      "bash", "-c", "exec \"$HOME/.local/bin/hyprloom\" \"$@\"", "deskloom"
    ]
    for (var index = 0; index < args.length; index++)
      command.push(String(args[index]))
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
    listProcess.command = root.helperProcessCommand(["list", "--json"])
    listProcess.running = true
    listDispatched = false
    listErrorText = ""
  }

  function acquireBusy(owner) {
    // The busy flag is shared across all workflows. A second workflow must
    // never silently steal another owner's claim: refusal is visible and the
    // contender stays fully functional instead of erasing the owner's
    // release. An empty owner is legacy/unowned and may be claimed outright.
    if (busyOwner && busyOwner !== owner) return false
    busyOwner = owner
    busy = true
    return true
  }

  function releaseBusy(owner) {
    // Only the owning workflow may release the shared busy flag; an empty
    // owner is legacy/unowned and releases unconditionally.
    if (busyOwner === owner || !busyOwner) {
      busyOwner = ""
      busy = false
    }
  }

  function snapshotActionsReady() {
    return root.helperInstalled
      && !root.busy
      && !listProcess.running
      && !startupRecoveryProcess.running
      && !bootRestoreProcess.running
      && !bootHelperProbe.running
  }

  function startStartupRecovery() {
    if (!root.helperInstalled || root.startupRecoveryAttempted || startupRecoveryProcess.running)
      return
    if (!acquireBusy("startup-recovery")) return
    root.startupRecoveryAttempted = true
    root.startupRecoveryTimedOut = false
    root.statusText = "Checking for interrupted replacement…"
    startupRecoveryProcess.command = root.helperProcessCommand(["recover"])
    startupRecoveryProcess.running = true
    startupDispatched = false
    startupRecoveryTimeout.stop()
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
        function merge(item, entries, index) {
          if (typeof item === "string") {
            if (item !== root.moduleName) return false
            entries[index] = entry
            return true
          }
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
              if (merge(entries[index], entries, index)) found = true
          }
        }
        if (!found && Array.isArray(config.plugins)) {
          for (var plugin = 0; plugin < config.plugins.length; plugin++)
            if (merge(config.plugins[plugin], config.plugins, plugin)) found = true
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
    if (busy || installingHelper || operationProcess.running || recoveryProcess.running) {
      bootRestoreAttempted = true
      statusText = "Automatic restore skipped: the panel is busy."
      return
    }
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
    if (!acquireBusy("boot-restore")) {
      // Another workflow owns the panel: never steal its claim and never
      // restore the preset underneath it. Say so and skip this boot attempt.
      statusText = "Another operation is running; the default preset was not restored."
      return
    }
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
        + "if [ -L \"$lock_root\" ] || { [ -e \"$lock_root\" ] && [ ! -d \"$lock_root\" ]; }; then exit 1; fi; "
        + "lock_dir=\"$lock_root/deskloom\"; "
        + "if [ -L \"$lock_dir\" ] || { [ -e \"$lock_dir\" ] && [ ! -d \"$lock_dir\" ]; }; then exit 1; fi; "
        + "mkdir -p \"$lock_dir\"; chmod 700 \"$lock_dir\"; "
        + "test -O \"$lock_dir\"; lock_file=\"$lock_dir/boot.lock\"; "
        + "if [ -L \"$lock_file\" ] || { [ -e \"$lock_file\" ] && [ ! -f \"$lock_file\" ]; }; then exit 1; fi; "
        + "exec 9>\"$lock_file\"; "
        + "flock -n 9 || exit 75; "
        + "claim_file=\"$lock_dir/boot-claim\"; "
        + "if [ -L \"$claim_file\" ] || { [ -e \"$claim_file\" ] && [ ! -f \"$claim_file\" ]; }; then exit 1; fi; "
        + "session_id=\"${XDG_SESSION_ID:-}\"; "
        + "boot_id=\"\"; "
        + "if [ -r /proc/sys/kernel/random/boot_id ]; then IFS= read -r boot_id < /proc/sys/kernel/random/boot_id || true; fi; "
        + "instance_id=\"${HYPRLAND_INSTANCE_SIGNATURE:-${WAYLAND_DISPLAY:-deskloom}}\"; "
        + "if [ -n \"$boot_id\" ]; then claim_key=\"$boot_id:${session_id:-$instance_id}\"; "
        + "else claim_key=\"${session_id:-$instance_id}\"; fi; "
        + "if [ -f \"$claim_file\" ]; then previous=\"\"; previous_status=\"\"; "
        + "{ IFS= read -r previous || true; IFS= read -r previous_status || true; } < \"$claim_file\"; "
        + "if [ \"$previous\" = \"$claim_key\" ] && { [ \"$previous_status\" = complete ] || [ \"$previous_status\" = attempted ]; }; then exit 76; fi; fi; "
        + "temporary=$(mktemp \"$lock_dir/.boot-claim.XXXXXX\"); "
        + "printf \"%s\\n%s\\n\" \"$claim_key\" in-progress > \"$temporary\"; chmod 600 \"$temporary\"; "
        + "mv -f \"$temporary\" \"$claim_file\"; "
        + "child_pid=\"\"; "
        + "cleanup() { status=$?; "
        + "if [ -n \"$child_pid\" ]; then kill -TERM \"$child_pid\" 2>/dev/null || true; "
        + "wait \"$child_pid\" 2>/dev/null || true; fi; "
        + "if [ -n \"$child_pid\" ]; then rm -f -- \"$claim_file\" || true; fi; "
        + "trap - EXIT TERM INT; exit \"$status\"; }; "
        + "trap cleanup EXIT TERM INT; "
        + "\"$HOME/.local/bin/hyprloom\" restore \"$1\" --reconcile --report-json 9>&- & child_pid=$!; "
        + "if wait \"$child_pid\"; then restore_status=0; else restore_status=$?; fi; "
        + "child_pid=\"\"; "
        + "claim_status=attempted; completed=$(mktemp \"$lock_dir/.boot-claim.XXXXXX\"); "
        + "if [ \"$restore_status\" -eq 0 ]; then claim_status=complete; fi; "
        + "printf \"%s\\n%s\\n\" \"$claim_key\" \"$claim_status\" > \"$completed\"; chmod 600 \"$completed\"; "
        + "mv -f \"$completed\" \"$claim_file\"; exit \"$restore_status\"",
      "deskloom", root.bootRestorePreset
    ]
    bootRestoreTimedOut = false
    bootRestoreProcess.running = true
    bootDispatched = false
    bootRestoreErrorText = ""
  }

  function openHelperInstaller() {
    if (busy) {
      console.log("installer launch rejected: an operation is already running")
      return
    }
    if (helperInstalled) {
      console.log("installer launch rejected: hyprloom is already installed")
      return
    }
    installerLaunched = false
    installerTimedOut = false
    installerFinished = false
    installerAttemptId = String(Date.now())
    installerPolls = 0
    installingHelper = true
    acquireBusy("installer")
    statusText = "Opening the installer terminal…"
    var installCommand = "bash -c 'set -eu; umask 077; "
      + "lock_root=\"${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}\"; "
      + "if [ -L \"$lock_root\" ] || { [ -e \"$lock_root\" ] && [ ! -d \"$lock_root\" ]; }; then exit 1; fi; "
      + "lock_dir=\"$lock_root/deskloom\"; "
      + "if [ -L \"$lock_dir\" ] || { [ -e \"$lock_dir\" ] && [ ! -d \"$lock_dir\" ]; }; then exit 1; fi; "
      + "mkdir -p \"$lock_dir\"; chmod 700 \"$lock_dir\"; test -O \"$lock_dir\"; "
      + "lock_file=\"$lock_dir/helper-install.lock\"; "
      + "if [ -L \"$lock_file\" ] || { [ -e \"$lock_file\" ] && [ ! -f \"$lock_file\" ]; }; then exit 1; fi; "
      + "exec 9>\"$lock_file\"; flock -n 9 || exit 75; "
      + "result_file=\"$lock_dir/helper-install-result-$1\"; "
      + "if [ -L \"$result_file\" ] || { [ -e \"$result_file\" ] && [ ! -f \"$result_file\" ]; }; then exit 1; fi; "
      + "rm -f \"$result_file\"; "
      + "installer=\"$HOME/.config/omarchy/plugins/thethracian.deskloom/install-helper.sh\"; "
      + "if [ ! -x \"$installer\" ]; then code=1; result=failure; "
      + "elif \"$installer\"; then code=0; result=success; "
      + "else code=$?; result=failure; fi; "
      + "temporary=$(mktemp \"$lock_dir/.helper-install-result.XXXXXX\"); "
      + "printf \"%s\\n\" \"$result\" > \"$temporary\"; chmod 600 \"$temporary\"; "
      + "mv -f \"$temporary\" \"$result_file\"; exit \"$code\"' deskloom "
      + installerAttemptId
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      installCommand
    ])
    installerLaunched = true
    installPoll.start()
    installTimeout.start()
  }

  function checkInstallerResult() {
    if (!root.installerLaunched) return
    if (!root.installingHelper || installerResultProbe.running) return
    installerResultProbe.command = [
      "bash", "-c",
      "set -eu; lock_root=\"${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}\"; "
        + "if [ -L \"$lock_root\" ] || { [ -e \"$lock_root\" ] && [ ! -d \"$lock_root\" ]; }; then exit 1; fi; "
        + "lock_dir=\"$lock_root/deskloom\"; "
        + "if [ -L \"$lock_dir\" ] || { [ -e \"$lock_dir\" ] && [ ! -d \"$lock_dir\" ]; }; then exit 1; fi; "
        + "mkdir -p \"$lock_dir\"; chmod 700 \"$lock_dir\"; test -O \"$lock_dir\"; "
        + "result_file=\"$lock_dir/helper-install-result-$1\"; "
        + "if [ -L \"$result_file\" ] || { [ -e \"$result_file\" ] && [ ! -f \"$result_file\" ]; }; then exit 1; fi; "
        + "if [ -f \"$result_file\" ]; then cat \"$result_file\"; fi",
      "deskloom", installerAttemptId
    ]
    installerResultAttempt = installerAttemptId
    installerResultProbe.running = true
  }

  function checkInstallerLock() {
    if (!root.installerLaunched) return
    if (installerLockProbe.running) return
    installerLockProbe.command = [
      "bash", "-c",
      "set -eu; lock_root=\"${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}\"; "
        + "if [ -L \"$lock_root\" ] || { [ -e \"$lock_root\" ] && [ ! -d \"$lock_root\" ]; }; then exit 1; fi; "
        + "lock_dir=\"$lock_root/deskloom\"; "
        + "if [ -L \"$lock_dir\" ] || { [ -e \"$lock_dir\" ] && [ ! -d \"$lock_dir\" ]; }; then exit 1; fi; "
        + "mkdir -p \"$lock_dir\"; chmod 700 \"$lock_dir\"; test -O \"$lock_dir\"; "
        + "lock_file=\"$lock_dir/helper-install.lock\"; "
        + "if [ -L \"$lock_file\" ] || { [ -e \"$lock_file\" ] && [ ! -f \"$lock_file\" ]; }; then exit 1; fi; "
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
      // A visible input that maps onto a differently-named existing snapshot
      // is a hidden collision: disclose it and require a second Save click.
      var overwriteTarget = snapshots.find(function (s) {
        return s.name === operationArgument && s.name !== name
      })
      if (overwriteTarget) {
        if (pendingSaveName !== name) {
          pendingSaveName = name
          pendingSaveRevision = overwriteTarget.revision ?? ""
          statusText = "'" + name + "' will overwrite the existing snapshot '" + operationArgument
            + "'. Click Save again to overwrite it."
          logConsent("armed-collision-overwrite")
          return
        }
        logConsent("confirmed-collision-overwrite")
        pendingSaveName = ""
      }
    }

    // Destructive confirmation is a one-use consent capability.  Consuming
    // both tokens here, at the accepted launch boundary, means a failed,
    // timed-out, recovered, or intervening attempt can never be re-fired by
    // a stale token after a view reopen.  The confirmed revision travels
    // with the command: hyprloom refuses the mutation if the snapshot no
    // longer matches what the user confirmed.
    var armedReplaceRevision = pendingReplaceRevision
    var armedDeleteRevision = pendingDeleteRevision
    var armedSaveRevision = pendingSaveRevision
    if (kind === "replace" || kind === "delete") {
      if (revisionOf(operationArgument) !== armedReplaceRevision
        && revisionOf(operationArgument) !== armedDeleteRevision) {
        logConsent("invalidated-revision-changed")
        pendingReplaceName = ""
        pendingDeleteName = ""
        pendingReplaceRevision = ""
        pendingDeleteRevision = ""
        statusText = "The snapshot changed since you confirmed; confirm again."
        return
      }
      logConsent("consumed-" + kind)
    }
    pendingDeleteName = ""
    pendingReplaceName = ""
    pendingDeleteRevision = ""
    pendingReplaceRevision = ""
    pendingSaveRevision = ""

    operationKind = kind
    operationName = operationArgument
    operationTimedOut = false
    if (!acquireBusy("operation")) {
      statusText = "Another operation is running."
      return
    }
    statusText = "Working…"

    if (kind === "save") {
      var saveArgs = ["save", operationArgument, "--force"]
      if (armedSaveRevision !== "") saveArgs.push("--if-revision", armedSaveRevision)
      operationProcess.command = root.helperProcessCommand(saveArgs)
    } else if (kind === "restore") {
      restoreReportPopup.dismiss()
      operationProcess.command = root.helperProcessCommand(["restore", name, "--reconcile", "--report-json"])
    } else if (kind === "replace") {
      // hyprloom loads and validates the target, captures a safety backup,
      // closes windows, and reconciles in one helper process.  This keeps
      // Replace from destroying the current desktop after a stale preflight.
      restoreReportPopup.dismiss()
      var replaceArgs = ["replace", name, "--report-json"]
      if (armedReplaceRevision !== "") replaceArgs.push("--if-revision", armedReplaceRevision)
      operationProcess.command = root.helperProcessCommand(replaceArgs)
    } else if (kind === "delete") {
      var deleteArgs = ["delete", name]
      if (armedDeleteRevision !== "") deleteArgs.push("--if-revision", armedDeleteRevision)
      operationProcess.command = root.helperProcessCommand(deleteArgs)
    } else {
      busy = false
      return
    }

    operationProcess.running = true
    operationDispatched = false
    operationErrorText = ""
  }

  function parseInventory(output) {
    // Consumes hyprloom's versioned machine inventory. Any structural
    // problem rejects the whole response: the prior model and its selection
    // survive, and the failure is visible instead of masquerading as an
    // empty collection.
    var next = []
    var document = null
    var ok = true
    try { document = JSON.parse(String(output || "")) } catch (e) { ok = false }
    if (ok && (document === null || typeof document !== "object"
        || document.protocol !== "deskloom.inventory" || document.schema_version !== 1
        || !Array.isArray(document.sessions))) ok = false
    if (ok) {
      for (var i = 0; i < document.sessions.length && ok; i++) {
        var row = document.sessions[i]
        if (row === null || typeof row !== "object" || typeof row.name !== "string" || row.name === ""
          || typeof row.windows !== "number" || typeof row.created !== "string") { ok = false; break }
        next.push({ name: row.name, windows: row.windows, created: row.created,
          automatic: row.automatic === true,
          revision: typeof row.revision === "string" ? row.revision : "" })
      }
    }
    if (ok) {
      for (var a = 0; a < next.length && ok; a++)
        for (var b = a + 1; b < next.length; b++)
          if (next[a].name === next[b].name
            || (next[a].revision !== "" && next[a].revision === next[b].revision)) {
            ok = false
            root.statusText = "Snapshot list rejected: duplicate entries."
          }
    }
    if (!ok) {
      root.snapshotListFailed = true
      root.snapshotsLoaded = true
      if (!root.busy && root.statusText === "") root.statusText = "Could not parse the snapshot list."
      return
    }
    snapshots = next
    root.snapshotsLoaded = true
    root.snapshotListFailed = false
    if (pendingReplaceName !== "" || pendingDeleteName !== "") {
      var replaceRow = pendingReplaceName === "" ? null
        : next.find(function(snapshot) { return snapshot.name === pendingReplaceName })
      var deleteRow = pendingDeleteName === "" ? null
        : next.find(function(snapshot) { return snapshot.name === pendingDeleteName })
      if (pendingReplaceName !== "" && (replaceRow === undefined || replaceRow.revision !== pendingReplaceRevision)) {
        pendingReplaceName = ""
        statusText = "The snapshot changed while the list refreshed; confirm again."
        logConsent("invalidated-revision-changed")
      }
      if (pendingDeleteName !== "" && (deleteRow === undefined || deleteRow.revision !== pendingDeleteRevision)) {
        pendingDeleteName = ""
        logConsent("invalidated-revision-changed")
      }
    }
    if (root.defaultPreset !== ""
      && !next.some(function(snapshot) { return snapshot.name === root.defaultPreset })) {
      root.persistSettings({ defaultPreset: "" })
      if (!root.busy) root.statusText = "Default preset cleared because its snapshot no longer exists."
    }
  }

  function operationSummary(preferError) {
    var output = String(operationOutput.text || "").trim()
    var error = String(operationErrorText || "").trim()
    var source = preferError && error !== "" ? error : (output !== "" ? output : error)
    if (preferError && source !== "") return source
    var firstLine = source.split("\n")[0].trim()
    return firstLine !== "" ? firstLine : "Done"
  }

  function emptySnapshotMessage() {
    if (root.snapshots.length !== 0) return ""
    if (root.snapshotListFailed) return "Could not load snapshots. Try Refresh snapshots."
    if (!root.snapshotsLoaded) return "Loading snapshots…"
    return "No snapshots yet. Save the workspace you are in now."
  }

  function removeSnapshot(name) {
    var target = String(name || "")
    var remaining = []
    for (var index = 0; index < root.snapshots.length; index++) {
      if (root.snapshots[index].name !== target) remaining.push(root.snapshots[index])
    }
    root.snapshots = remaining
  }

  function requestDelete(name) {
    var target = String(name || "")
    if (target === "") return

    if (root.pendingDeleteName !== target) {
      if (!root.snapshotActionsReady()) return
      root.pendingDeleteName = target
      root.pendingDeleteRevision = revisionOf(target)
      root.pendingReplaceName = ""
      root.pendingReplaceRevision = ""
      root.statusText = "Click Confirm to delete '" + target + "'."
      logConsent("armed-delete")
      return
    }

    if (!root.snapshotActionsReady()) {
      root.statusText = "Still refreshing snapshots; click Confirm again when ready."
      return
    }

    // Defer the process start until the delegate has finished applying the
    // confirmation-state binding.  This keeps the second click reliable even
    // when the popup has to resize to show the status message.
    Qt.callLater(function() {
      if (root.pendingDeleteName === target && root.snapshotActionsReady())
        root.runOperation("delete", target)
    })
  }

  function revisionOf(name) {
    var row = null
    for (var index = 0; index < snapshots.length; index++)
      if (snapshots[index].name === name) { row = snapshots[index]; break }
    return row && typeof row.revision === "string" ? row.revision : ""
  }

  function requestReplace(name) {
    var target = String(name || "")
    if (target === "") return

    if (root.pendingReplaceName !== target) {
      if (!root.snapshotActionsReady()) return
      root.pendingReplaceName = target
      root.pendingReplaceRevision = revisionOf(target)
      root.pendingDeleteName = ""
      root.pendingDeleteRevision = ""
      root.statusText = "Click Replace again to close current windows."
      logConsent("armed-replace")
      return
    }

    if (!root.snapshotActionsReady()) {
      root.statusText = "Still refreshing snapshots; click Replace again when ready."
      return
    }

    // Same deferred-start contract as the delete flow above.
    Qt.callLater(function() {
      if (root.pendingReplaceName === target && root.snapshotActionsReady())
        root.runOperation("replace", target)
    })
  }

  function startTimedOutReplaceRecovery() {
    busyOwner = "recovery"
    root.recoveryTimedOut = false
    recoveryProcess.command = root.helperProcessCommand(["recover"])
    recoveryProcess.running = true
    recoveryDispatched = false
    recoveryErrorText = ""
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
      if (!root.installerLaunched) return
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
      if (root.installerResultAttempt !== root.installerAttemptId) {
        console.log("installer result dropped as stale: verdict belongs to a superseded attempt")
        return
      }
      var result = String(installerResultOutput.text || "").trim()
      if (result === "failure") {
        root.installerFinished = true
        root.installingHelper = false
        root.busy = false
        root.statusText = "Installation failed. Try again."
        installPoll.stop()
        installTimeout.stop()
        console.log("installer status: " + root.statusText)
      } else if (result === "success") {
        root.installerFinished = true
        root.installerTimedOut = false
        root.statusText = "Installer finished; checking hyprloom…"
        console.log("installer status: " + root.statusText + " (result " + result + ")")
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
      if (!root.installerLaunched) return
      if (!root.installingHelper || root.installerPolls < 5) return
      if (String(installerLockOutput.text || "").trim() === "free") {
        root.installingHelper = false
        root.busy = false
        root.statusText = "Installer stopped before hyprloom was ready. Try again."
        installPoll.stop()
        installTimeout.stop()
        console.log("installer lock free detected: " + root.statusText)
      }
    }
  }

  Timer {
    id: installTimeout
    interval: 180000
    repeat: false
    onTriggered: {
      if (!root.installingHelper) return
      // The build terminal is detached. Keep the UI serialized until its
      // user-scoped lock is free, even when compilation outlasts this timer.
      root.installerTimedOut = true
      root.busy = true
      root.statusText = "Installation is still running…"
      console.log("installer timed out: switching to lock-only observation")
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
      root.snapshotListFailed = true
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
          releaseBusy("installer")
          root.statusText = "hyprloom is ready."
          console.log("installer status: " + root.statusText)
          installPoll.stop()
          installTimeout.stop()
        }
        root.refreshList()
      } else {
        root.snapshots = []
        if (root.installingHelper && root.installerFinished) {
          root.installingHelper = false
          releaseBusy("installer")
          root.statusText = "Installer finished but hyprloom is not available. Try again."
          console.log("installer status: " + root.statusText)
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
        if (busyOwner === "boot-restore") {
          releaseBusy("boot-restore")
          statusText = "Default preset skipped: hyprloom is not installed."
        }
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
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: line => root.noteHelperLine("startup", line)
    }
    onExited: function(exitCode) {
      startupRecoveryTimeout.stop()
      var timedOut = root.startupRecoveryTimedOut
      root.startupRecoveryTimedOut = false
      releaseBusy("startup-recovery")

      if (timedOut) {
        root.statusText = "Startup recovery timed out; continuing carefully."
      } else if (exitCode !== 0) {
        // Keep the complete helper diagnostic: the tail can carry the safety
        // snapshot name and the manual remediation steps.
        var error = String(startupRecoveryErrorText || "").trim()
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
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: line => root.noteHelperLine("boot", line)
    }
    onExited: function(exitCode) {
      bootRestoreTimeout.stop()
      if (root.bootRestoreTimedOut) {
        root.bootRestoreTimedOut = false
        releaseBusy("boot-restore")
        root.statusText = "Default preset restore stopped after timing out."
        root.presentRestoreReport("", root.statusText, 1, root.bootRestorePreset, true)
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
          releaseBusy("boot-restore")
        root.statusText = "Automatic restore skipped: startup lock was busy."
        }
      } else if (exitCode === 76) {
        releaseBusy("boot-restore")
        root.statusText = "Default preset already restored this session."
      } else if (exitCode === 0) {
        releaseBusy("boot-restore")
        root.presentRestoreReport(bootRestoreOutput.text, bootRestoreErrorText, exitCode, root.bootRestorePreset, false)
        root.refreshList()
      } else {
        var output = String(bootRestoreOutput.text || "")
        var model = RestoreReport.parse(output, exitCode, bootRestoreErrorText, root.bootRestorePreset)
        var onlySafeSkips = model.available && model.counts.skipped > 0 && model.counts.failed === 0
        if (onlySafeSkips) {
          root.presentRestoreReport(output, bootRestoreErrorText, exitCode, root.bootRestorePreset, false)
          root.refreshList()
          return
        }
        if (root.bootRestoreRetries < 3) {
          root.bootRestoreRetries += 1
          root.busy = true
          root.statusText = "Default preset restore failed; retrying…"
          bootRestoreRetryTimer.interval = 1000 * root.bootRestoreRetries
          bootRestoreRetryTimer.restart()
        } else {
          root.presentRestoreReport(output, bootRestoreErrorText, exitCode, root.bootRestorePreset, false)
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
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: line => root.noteHelperLine("list", line)
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
        root.parseInventory(listOutput.text)
      } else {
        root.snapshotListFailed = true
        var error = String(listErrorText || "").trim()
        root.statusText = "Could not refresh snapshots"
          + (error === "" ? "." : ": " + error)
      }
      if (root.refreshPending)
        Qt.callLater(function() { if (root.helperInstalled) root.refreshList() })
    }
  }

  Process {
    id: operationProcess
    objectName: "operationProcess"
    stdout: StdioCollector {
      id: operationOutput
      waitForEnd: true
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: line => root.noteHelperLine("operation", line)
    }
    onExited: function(exitCode) {
      var completedKind = root.operationKind
      var completedName = root.operationName
      operationTimeout.stop()
      if (root.recoveryRunning) {
        root.operationTimedOut = false
        root.startTimedOutReplaceRecovery()
        return
      }
      if (root.operationTimedOut) {
        root.operationTimedOut = false
        releaseBusy("operation")
        root.statusText = "Operation stopped after timing out. Try again."
        if (completedKind === "restore")
          root.presentRestoreReport("", root.statusText, 1, completedName, true)
        root.pendingDeleteName = ""
        root.pendingReplaceName = ""
        root.operationKind = ""
        root.operationName = ""
        root.refreshList()
        return
      }
      releaseBusy("operation")
      var isRestore = completedKind === "restore" || completedKind === "replace"
      if (isRestore)
        root.presentRestoreReport(operationOutput.text, operationErrorText, exitCode, completedName, false)
      if (exitCode === 0) {
        if (completedKind === "delete") {
          root.removeSnapshot(completedName)
          if (root.defaultPreset === completedName)
            root.persistSettings({ defaultPreset: "" })
        }
        if (!isRestore) root.statusText = root.operationSummary(false)
        root.pendingDeleteName = ""
        root.pendingReplaceName = ""
        root.operationKind = ""
        root.operationName = ""
        root.refreshList()
      } else {
        // Terminal failure releases the operation identity and any consent
        // state; a new attempt requires a fresh confirmation.
        root.pendingDeleteName = ""
        root.pendingReplaceName = ""
        root.pendingDeleteRevision = ""
        root.pendingReplaceRevision = ""
        root.operationKind = ""
        root.operationName = ""
        if (!isRestore) root.statusText = "Operation failed: " + root.operationSummary(true)
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
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: line => root.noteHelperLine("recovery", line)
    }
    onExited: function(exitCode) {
      recoveryTimeout.stop()
      var timedOut = root.recoveryTimedOut
      root.recoveryTimedOut = false
      root.recoveryRunning = false
      releaseBusy("recovery")

      if (timedOut) {
        root.statusText = "Desktop recovery timed out; try Restore again."
      } else if (exitCode === 0) {
        root.statusText = "Replace timed out; desktop recovery completed."
      } else {
        // Keep the complete helper diagnostic for the report surface.
        var error = String(recoveryErrorText || "").trim()
        root.statusText = "Desktop recovery failed"
          + (error === "" ? ". Try Restore again." : ": " + error)
      }
      root.pendingDeleteName = ""
      root.pendingReplaceName = ""
      root.pendingDeleteRevision = ""
      root.pendingReplaceRevision = ""
      root.presentRestoreReport("", root.statusText, 1, root.operationName, true)
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

  RestoreReportPopup {
    id: restoreReportPopup
    objectName: "restoreReportPopup"
    anchorItem: root
    bar: root.bar
  }

  PopupCard {
    id: popup
    objectName: "snapshotPopup"
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    // Use Qt's native grab for keyboard input and outside-click dismissal.
    // PopupCard's competing Hyprland grab would close this popup on opening.
    grabFocus: true
    triggerMode: "hover"
    onVisibleChanged: if (!visible && root.opened) root.close()
    contentWidth: popup.fittedContentWidth(Style.space(390))
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight)

    Column {
      id: contentColumn
      anchors.fill: parent
      spacing: Style.space(10)
      Keys.onEscapePressed: root.close()

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

      Flickable {
        id: statusScroller
        objectName: "statusScroller"
        width: parent.width
        height: Math.min(contentHeight, Style.space(120))
        contentWidth: width
        contentHeight: statusMessage.contentHeight
        visible: root.statusText !== ""
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        TextEdit {
          id: statusMessage
          objectName: "statusMessage"
          width: Math.max(0, statusScroller.width - Style.space(12))
          height: contentHeight
          text: root.statusText
          textFormat: TextEdit.PlainText
          wrapMode: TextEdit.Wrap
          readOnly: true
          selectByMouse: true
          selectionColor: root.accent
          color: root.statusText.indexOf("failed") >= 0 ? root.urgent : root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          onTextChanged: statusScroller.contentY = 0
        }
      }

      Button {
        text: "Last restore"
        objectName: "lastRestoreButton"
        visible: restoreReportPopup.report !== null
        foreground: root.foreground
        fontFamily: root.bar.fontFamily
        fontSize: Style.font.caption
        bordered: true
        tooltipText: "Show the last restore's per-window results"
        onClicked: {
          root.close()
          restoreReportPopup.reopen()
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: !root.helperInstalled

        Text {
          width: parent.width
          text: "Deskloom uses Hyprloom for workspace and window management. Build it from source with Cargo in a visible terminal; Rust/Cargo, Git and a C toolchain are required."
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          width: parent.width
          text: root.busy ? "Building Hyprloom…" : "Build and install Hyprloom"
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
              objectName: "snapshotNameInput"
              focus: true
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
              onVisibleChanged: if (visible && root.opened) forceActiveFocus()
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
        text: root.emptySnapshotMessage()
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
                enabled: root.snapshotActionsReady()
                tooltipText: "Restore without closing current windows"
                onClicked: root.runOperation("restore", modelData.name)
              }

              Button {
                objectName: "replaceButton-" + modelData.name
                text: root.pendingReplaceName === modelData.name ? "Sure?" : "Replace"
                foreground: root.pendingReplaceName === modelData.name ? root.urgent : root.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(5)
                enabled: root.snapshotActionsReady()
                tooltipText: "Close current windows, then restore this snapshot"
                onClicked: root.requestReplace(modelData.name)
              }

              Button {
                objectName: "deleteButton-" + modelData.name
                text: root.pendingDeleteName === modelData.name ? "Confirm" : "Delete"
                foreground: root.pendingDeleteName === modelData.name ? root.urgent : root.dim
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(5)
                enabled: root.snapshotActionsReady()
                tooltipText: "Delete this saved snapshot"
                onClicked: root.requestDelete(modelData.name)
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
      restoreReportPopup.dismiss()
      root.checkHelper()
      Qt.callLater(function() {
        if (root.opened && root.helperInstalled) root.refreshList()
      })
    }
  }
}
