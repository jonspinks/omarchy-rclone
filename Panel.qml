import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Cloud Drives: a cloud in the bar, and a panel modelled on what the OneDrive
// and Google Drive desktop clients actually put in front of people -- per-drive
// health, a storage meter, and a one-click route out of the failure they are
// most likely to hit.
//
// All policy lives in scripts/rclone-status (run from this plugin), which emits
// one JSON object. This file renders that object and runs the remedies; it
// decides nothing about state itself. That split is what makes the hard part
// (see the script's header: latched auth, assert-vs-stopped, hung mounts)
// testable without a running shell.
//
// Nothing here is privileged. rclone mounts are systemd *user* units, so start,
// stop and restart need no sudo and no polkit -- a simplification over
// blacksheep.wireguard, which needs a scoped NOPASSWD rule for wg-quick.
Panel {
  id: root
  moduleName: "blacksheep.rclone"
  ipcTarget: "blacksheep.rclone"

  implicitWidth: button.implicitWidth
  implicitHeight: bar ? bar.barSize : 26

  property var status: ({})
  property bool busy: false
  property var notifiedKeys: ({})
  property string lastSignature: ""

  // The Repeater's model, updated only when something it renders has actually
  // changed. Binding it straight to status.remotes rebuilt every delegate --
  // and every MouseArea inside them -- on each 3s poll, which drops a click
  // that happens to land on the same tick.
  property var remotes: []

  function renderSignature(list) {
    return JSON.stringify((list || []).map(function(r) {
      var q = r.quota || {}
      var c = r.cache || {}
      return [r.name, r.state, r.stateText, r.faultText, r.fixAction, r.mounted,
              r.responsive, r.unitState, r.rc, q.ok, q.pct, q.consumed, q.total,
              q.trashed, q.stale, c.uploadsInProgress, c.uploadsQueued,
              c.erroredFiles, (r.bwlimit || {}).rate]
    }))
  }
  readonly property string aggregate: status.aggregate || "unknown"
  readonly property int faulted: status.faulted || 0
  readonly property bool rcOn: status.rc === true
  readonly property var disk: status.disk || null

  readonly property var faultKinds: ["auth", "clock", "blocked", "failed", "hung", "readonly", "full", "orphaned"]

  // Rows for remotes in rclone.conf that have no mount unit yet. They are
  // listed, but they are not drives: the helper leaves them out of the
  // aggregate, and the footnotes below skip them too.
  readonly property var drives: root.remotes.filter(function(r) { return r.state !== "unconfigured" })
  readonly property bool hasFault: faultKinds.indexOf(aggregate) >= 0

  // ---- presentation helpers -------------------------------------------------

  // "Not carrying data" -- a deliberately stopped drive and an expired sign-in
  // both get the struck cloud; only the latter is also badged, because stopping
  // a drive on purpose is not a fault and must never look like one.
  function disconnectedFor(state) {
    return state === "stopped" || state === "auth" || state === "unconfigured"
  }

  // There is no "downloading" state: rclone leaves core/stats' transferring[]
  // empty for a mount, so reads served from the VFS cache are invisible to us.
  // Claiming a download we cannot see would be the same overclaim as the
  // session-average speed this panel already refuses to show.
  function activityFor(state) {
    return state === "uploading" ? "up" : ""
  }

  function warnFor(state) {
    return root.faultKinds.indexOf(state) >= 0
  }

  function dimFor(state) {
    if (state === "stopped" || state === "unknown" || state === "starting"
        || state === "unconfigured") return 0.5
    return 1.0
  }

  function humanBytes(n) {
    var b = Number(n)
    if (!isFinite(b) || b < 0) return "—"
    if (b >= 1099511627776) return (b / 1099511627776).toFixed(1) + " TiB"
    if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GiB"
    if (b >= 1048576) return (b / 1048576).toFixed(1) + " MiB"
    if (b >= 1024) return Math.round(b / 1024) + " KiB"
    return b + " B"
  }

  // Single source for the quota sentence. It previously existed twice -- the
  // tooltip built its own from `used` while the caption used `consumed` -- so
  // hovering the icon and opening the panel reported the same drive 5,800x
  // apart, and the tooltip was the wrong one.
  function quotaLine(q, verbose) {
    if (!q || q.ok !== true || q.total === undefined) return ""
    var c = (q.consumed !== undefined && q.consumed !== null) ? q.consumed : q.used
    var line = root.humanBytes(c) + " of " + root.humanBytes(q.total)
    if (!verbose) return line
    line += " used"
    if (q.pct !== null && q.pct !== undefined) line += " (" + q.pct + "%)"
    if (q.trashed > 1048576) line += ", including " + root.humanBytes(q.trashed) + " in the bin"
    if (q.stale && q.ageSec) line += " — as of " + Math.round(q.ageSec / 60) + "m ago"
    return line
  }

  function headline() {
    if (!root.remotes.length) return "No drives configured"
    if (!root.drives.length) {
      var n = root.remotes.length
      return n === 1 ? "1 drive not set up" : n + " drives not set up"
    }
    if (root.aggregate === "orphaned") return "A drive's remote is missing"
    if (root.aggregate === "auth") return "Sign-in needed"
    if (root.aggregate === "clock") return "Clock is wrong"
    if (root.aggregate === "blocked") return "A drive cannot start"
    if (root.aggregate === "hung") return "A drive is not responding"
    if (root.aggregate === "readonly") return "A drive is read-only"
    if (root.aggregate === "full") return "Storage full"
    if (root.aggregate === "failed") return "A drive is failing"
    if (root.aggregate === "uploading") return "Uploading"
    if (root.aggregate === "throttled") return "Throttled by provider"
    if (root.aggregate === "starting") return "Starting"
    if (root.aggregate === "stopped") {
      // aggregate is the worst state, not a universal one: with one drive
      // mounted and one stopped it still reads "stopped", and the hero then
      // claimed every drive was off while the row below showed one running.
      var allStopped = root.remotes.every(function(r) { return r.state === "stopped" })
      if (allStopped) return root.remotes.length > 1 ? "All drives stopped" : "Stopped"
      return (root.status.mountedCount || 0) + " of " + root.status.total + " mounted"
    }
    if (root.status.mountedCount !== undefined && root.status.mountedCount < root.status.total)
      return root.status.mountedCount + " of " + root.status.total + " mounted"
    return root.remotes.length > 1 ? "All drives up to date" : "Up to date"
  }

  // PanelHero renders `detail` as a bordered pill on the title row. Keep it to a
  // badge; the sentence lives in the fault banner below.
  function heroBadge() {
    if (root.aggregate === "orphaned") return "REMOTE MISSING"
    if (root.aggregate === "auth") return "SIGN-IN NEEDED"
    if (root.aggregate === "blocked") return "CANNOT START"
    if (root.aggregate === "hung") return "NOT RESPONDING"
    if (root.aggregate === "readonly") return "READ-ONLY"
    if (root.aggregate === "full") return "STORAGE FULL"
    if (root.aggregate === "failed") return "MOUNT FAILING"
    return ""
  }

  function tooltip() {
    if (!root.remotes.length) return "Cloud Drives — nothing configured"
    var lines = []
    for (var i = 0; i < root.remotes.length; i++) {
      var r = root.remotes[i]
      var line = r.name + " — " + (r.stateText || "").toLowerCase()
      var q = root.quotaLine(r.quota, false)
      if (r.state === "ok" && q) line += " — " + q
      lines.push(line)
    }
    if (root.aggregate === "auth") lines.push("Click to sign in again")
    return lines.join("\n")
  }

  // ---- data -----------------------------------------------------------------

  function refresh() {
    if (statusProc.running) return
    statusProc.running = true
    watchdog.restart()
  }

  // Every subprocess the helper runs is already behind a timeout, but a
  // watchdog here is what guarantees the widget itself cannot be wedged by one
  // that is not: `refresh()` returns early while statusProc.running is true, so
  // a helper that never exits would silently freeze the bar on stale data and
  // disable the refresh button along with it.
  Timer {
    id: watchdog
    interval: 30000
    repeat: false
    onTriggered: if (statusProc.running) statusProc.running = false
  }

  Process {
    id: statusProc
    // Run from the plugin itself, as a fixed argv: `omarchy plugin update` then
    // updates the helper along with the panel, and no shell parses the path.
    command: [Quickshell.env("HOME") + "/.config/omarchy/plugins/blacksheep.rclone/scripts/rclone-status", "--poll"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var next = JSON.parse(String(text || "{}").trim() || "{}")
          root.status = next
          var sig = root.renderSignature(next.remotes)
          if (sig !== root.lastSignature) {
            root.lastSignature = sig
            root.remotes = next.remotes || []
          }
        } catch (e) {
          root.status = {}
          root.lastSignature = ""
          root.remotes = []
        }
        watchdog.stop()
        root.maybeNotify()
      }
    }
  }

  // The helper decides *whether* to interrupt: it requires a state to hold for
  // two consecutive polls and emits a transition only once. This delivers what
  // it decided, and forgets a fault once the drive leaves that state -- an
  // earlier version latched the key for the life of the shell, so a drive that
  // expired, was fixed, and expired again a week later notified only the first
  // time. The shell is long-lived; that is the normal case, not an edge one.
  function maybeNotify() {
    var list = root.status.notifications
    if (!list || !list.length) {
      // Nothing faulting: drop every latch so a recurrence can speak again.
      if (Object.keys(root.notifiedKeys).length) root.notifiedKeys = ({})
      return
    }
    var next = ({})
    for (var i = 0; i < list.length; i++) {
      var n = list[i]
      if (!n || !n.headline) continue
      var key = n.remote + ":" + n.state
      next[key] = true
      if (root.notifiedKeys[key]) continue

      var argv = ["omarchy", "notification", "send",
                  "--app-name", "Cloud Drives",
                  "-u", n.urgency || "normal",
                  n.headline, n.body || ""]
      if (n.fixAction === "reconnect")
        argv = argv.concat(["--exec", "omarchy-launch-floating-terminal-with-presentation",
                            root.reconnectCommand(n.remote)])
      notifyProc.command = argv
      notifyProc.running = true
    }
    root.notifiedKeys = next
  }

  Process { id: notifyProc }

  function unitFor(name) { return "rclone-mount@" + name + ".service" }

  // Stop FIRST. The unit restarts every ~10s while the token is dead, and each
  // start re-reads ~/.config/rclone/rclone.conf -- the same file `config
  // reconnect` rewrites. Reconnecting under a live restart loop is a
  // read-during-rewrite race on the only credential store on the machine.
  //
  // The whole chain runs in the visible terminal, so completion needs no
  // polling here: the browser OAuth takes 30-120s, far longer than any settle
  // timer would wait, and the ordinary poll picks the result up when it lands.
  function reconnectCommand(name) {
    var u = Util.shellQuote(root.unitFor(name))
    var r = Util.shellQuote(name + ":")
    return "systemctl --user stop " + u + "; " +
           "rclone config reconnect " + r + "; " +
           "systemctl --user reset-failed " + u + "; " +
           "systemctl --user start " + u + "; " +
           "echo; echo 'Done — you can close this window.'; read -n 1 -s"
  }

  function runAction(name, action) {
    if (root.busy) return
    var u = Util.shellQuote(root.unitFor(name))
    var argv = null

    if (action === "reconnect") {
      // Detaches into its own terminal; nothing to wait for.
      argv = ["omarchy-launch-floating-terminal-with-presentation", root.reconnectCommand(name)]
      actionProc.command = argv
      actionProc.running = true
      return
    }
    if (action === "start") argv = ["bash", "-lc", "systemctl --user reset-failed " + u + " 2>/dev/null; systemctl --user start " + u]
    else if (action === "stop") argv = ["bash", "-lc", "systemctl --user stop " + u]
    else if (action === "restart") argv = ["bash", "-lc", "systemctl --user reset-failed " + u + " 2>/dev/null; systemctl --user restart " + u]
    else if (action === "mkdir") argv = ["bash", "-lc", "mkdir -p " + Util.shellQuote(Quickshell.env("HOME") + "/" + name) + " && systemctl --user reset-failed " + u + " 2>/dev/null; systemctl --user start " + u]
    // mkdir -m 700: the unit mounts with --umask 077, and the directory
    // under the mount should not be the one place that is less private.
    else if (action === "setup") argv = ["bash", "-lc", "mkdir -p -m 700 " + Util.shellQuote(Quickshell.env("HOME") + "/" + name) + " && systemctl --user enable --now " + u]
    else if (action === "open") argv = ["xdg-open", Quickshell.env("HOME") + "/" + name]
    if (!argv) return

    root.busy = true
    actionProc.command = argv
    actionProc.running = true
  }

  Process {
    id: actionProc
    onExited: {
      root.busy = false
      settleTimer.restart()
    }
  }

  Timer { id: settleTimer; interval: 1500; repeat: false; onTriggered: root.refresh() }

  // Honest about the cost: the bar icon must stay true while the popup is shut,
  // but a statfs plus two journalctl reads per remote is not something to run
  // every two seconds on battery for a widget nobody is looking at.
  Timer {
    interval: root.opened ? 3000 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) refresh()

  // ---- bar ------------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.tooltip()

    iconComponent: Component {
      Item {
        RcloneIcon {
          anchors.centerIn: parent
          iconSize: Style.space(13)
          color: root.bar ? root.bar.barForeground : Color.foreground
          badgeColor: root.bar ? root.bar.urgent : Color.urgent
          disconnected: root.disconnectedFor(root.aggregate)
          activity: root.activityFor(root.aggregate)
          warning: root.warnFor(root.aggregate)
          opacity: root.dimFor(root.aggregate)
        }
      }
    }

    onPressed: function(b) { root.opened ? root.close() : root.open() }
  }

  // ---- panel ----------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          title: "Cloud Drives"
          meta: root.headline()
          detail: root.heroBadge()
          iconOpacity: root.dimFor(root.aggregate)
          iconComponent: Component {
            RcloneIcon {
              iconSize: Style.font.display
              color: root.bar ? root.bar.foreground : Color.foreground
              badgeColor: root.bar ? root.bar.urgent : Color.urgent
              disconnected: root.disconnectedFor(root.aggregate)
              activity: root.activityFor(root.aggregate)
              warning: root.warnFor(root.aggregate)
            }
          }
          trailingControl: Component {
            PanelActionButton {
              iconText: ""
              tooltipText: "Refresh now (r)"
              foreground: root.bar ? root.bar.foreground : Color.foreground
              onClicked: root.refresh()
            }
          }
        }

        PanelSeparator { width: parent.width }

        // The fault comes first, above the drive list, the way OneDrive
        // replaces its file list with the problem when there is one.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.faulted > 0

          Repeater {
            model: root.remotes
            delegate: Text {
              required property var modelData
              width: column.width
              visible: !!modelData.faultText
              text: modelData.faultText || ""
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              color: root.bar ? root.bar.urgent : Color.urgent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Repeater {
          model: root.remotes

          delegate: Column {
            id: remoteBlock
            required property var modelData
            required property int index
            readonly property var q: modelData.quota || {}
            readonly property bool quotaOk: q.ok === true && q.pct !== null && q.pct !== undefined

            width: column.width
            spacing: Style.space(6)

            PanelSeparator { width: parent.width; visible: remoteBlock.index > 0 }

            // header: icon, name, state
            Item {
              width: parent.width
              implicitHeight: Math.max(nameCol.implicitHeight, actions.implicitHeight)

              RcloneIcon {
                id: rowIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                iconSize: Style.font.icon
                color: root.bar ? root.bar.foreground : Color.foreground
                badgeColor: root.bar ? root.bar.urgent : Color.urgent
                disconnected: root.disconnectedFor(remoteBlock.modelData.state)
                activity: root.activityFor(remoteBlock.modelData.state)
                warning: root.warnFor(remoteBlock.modelData.state)
                opacity: root.dimFor(remoteBlock.modelData.state)
              }

              Column {
                id: nameCol
                anchors.left: rowIcon.right
                anchors.leftMargin: Style.space(10)
                anchors.right: actions.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: remoteBlock.modelData.name
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  width: parent.width
                  text: remoteBlock.modelData.stateText || ""
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  opacity: 0.6
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                id: actions
                // root.busy gates every click; say so, rather than letting a
                // press silently do nothing while an action is in flight.
                opacity: root.busy ? 0.4 : 1.0
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                // Exactly one remedy is offered, and it is the one that can work.
                // A restart button on a token-dead drive is a button we know is
                // useless, so `fixAction` gates which appears.
                PanelActionButton {
                  visible: remoteBlock.modelData.fixAction === "reconnect"
                  iconText: ""
                  tooltipText: "Sign in to " + remoteBlock.modelData.name + " again"
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  onClicked: root.runAction(remoteBlock.modelData.name, "reconnect")
                }

                PanelActionButton {
                  visible: remoteBlock.modelData.fixAction === "mkdir"
                  iconText: ""
                  tooltipText: "Create " + remoteBlock.modelData.path + " and start"
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  onClicked: root.runAction(remoteBlock.modelData.name, "mkdir")
                }

                PanelActionButton {
                  visible: remoteBlock.modelData.fixAction === "setup"
                  iconText: "\uf055"
                  tooltipText: "Set up: create " + remoteBlock.modelData.path + " and mount it at login"
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  onClicked: root.runAction(remoteBlock.modelData.name, "setup")
                }

                PanelActionButton {
                  visible: remoteBlock.modelData.fixAction === "restart"
                  iconText: ""
                  tooltipText: "Restart this mount"
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  onClicked: root.runAction(remoteBlock.modelData.name, "restart")
                }

                PanelActionButton {
                  visible: remoteBlock.modelData.fixAction === "start"
                  iconText: ""
                  tooltipText: "Start this mount"
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  onClicked: root.runAction(remoteBlock.modelData.name, "start")
                }

                PanelActionButton {
                  // Not merely mounted: *answering*. Opening a wedged mount puts
                  // the file manager into the same uninterruptible sleep the
                  // widget has just detected, so this hides rather than offering
                  // the one action guaranteed to hang.
                  visible: remoteBlock.modelData.mounted === true
                           && remoteBlock.modelData.responsive !== false
                  iconText: ""
                  tooltipText: "Open " + remoteBlock.modelData.path
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  onClicked: root.runAction(remoteBlock.modelData.name, "open")
                }

                PanelActionButton {
                  visible: remoteBlock.modelData.unitState === "active"
                  iconText: ""
                  tooltipText: "Stop this mount"
                  foreground: root.bar ? root.bar.foreground : Color.foreground
                  hoverColor: root.bar ? root.bar.urgent : Color.urgent
                  onClicked: root.runAction(remoteBlock.modelData.name, "stop")
                }
              }
            }

            // storage meter
            Column {
              width: parent.width
              spacing: Style.space(3)
              visible: remoteBlock.quotaOk

              Item {
                width: parent.width
                implicitHeight: Style.space(4)

                Rectangle {
                  anchors.fill: parent
                  radius: height / 2
                  color: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.18)
                }

                Rectangle {
                  height: parent.height
                  width: parent.width * Math.max(0, Math.min(1, (remoteBlock.q.pct || 0) / 100))
                  radius: height / 2
                  color: (remoteBlock.q.pct >= 90)
                    ? (root.bar ? root.bar.urgent : Color.urgent)
                    : (root.bar ? root.bar.foreground : Color.foreground)
                }
              }

              Text {
                width: parent.width
                text: root.quotaLine(remoteBlock.q, true)
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                opacity: 0.6
                color: root.bar ? root.bar.foreground : Color.foreground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // transfer activity — only when the rc socket is present
            Text {
              width: parent.width
              visible: !!remoteBlock.modelData.cache
                       && ((remoteBlock.modelData.cache.uploadsInProgress > 0)
                           || (remoteBlock.modelData.cache.uploadsQueued > 0))
              text: {
                var c = remoteBlock.modelData.cache || {}
                var bits = []
                if (c.uploadsInProgress) bits.push(c.uploadsInProgress + " uploading")
                if (c.uploadsQueued) bits.push(c.uploadsQueued + " queued")
                // No throughput here on purpose: rclone exposes only a
                // session-wide average for a mount, which read as a current
                // speed and sat contradicting the 1 MiB/s limit beside it.
                return bits.join(" · ")
              }
              textFormat: Text.PlainText
              opacity: 0.6
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: !!remoteBlock.modelData.cache && remoteBlock.modelData.cache.erroredFiles > 0
              // Guarded rather than relying on `visible`: QML evaluates every
              // binding regardless of visibility, so an unguarded dereference
              // here throws on any machine without the rc socket -- i.e. the
              // default one.
              text: (remoteBlock.modelData.cache ? remoteBlock.modelData.cache.erroredFiles : 0)
                    + " file(s) failed to upload"
              textFormat: Text.PlainText
              color: root.bar ? root.bar.urgent : Color.urgent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: !!remoteBlock.modelData.bwlimit && remoteBlock.modelData.bwlimit.rate !== "off"
              text: "Speed limit " + (remoteBlock.modelData.bwlimit ? remoteBlock.modelData.bwlimit.rate : "")
                    + " — until this mount restarts"
              textFormat: Text.PlainText
              opacity: 0.6
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { width: parent.width; visible: !!root.disk }

        // Free space on *this machine*, which both official clients track
        // separately from account storage. With --vfs-cache-mode full a full
        // disk means writes to the mount fail and queued uploads cannot stage.
        Text {
          width: parent.width
          visible: !!root.disk
          text: root.disk
            ? (root.humanBytes(root.disk.freeBytes) + " free on this computer"
               + (root.disk.critical ? " — too low to cache uploads safely"
                  : root.disk.low ? " — running low" : ""))
            : ""
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          opacity: (root.disk && (root.disk.low || root.disk.critical)) ? 1.0 : 0.6
          color: (root.disk && root.disk.critical)
            ? (root.bar ? root.bar.urgent : Color.urgent)
            : (root.bar ? root.bar.foreground : Color.foreground)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        // Say what is missing rather than letting an absent capability read as a
        // healthy drive with nothing going on.
        Text {
          width: parent.width
          // Keyed off "every drive", not "any drive": with one socket present
          // the global flag hid this note, and the drive *without* a socket
          // then read as healthy-and-idle rather than as not-reporting.
          visible: root.drives.length > 0 && root.drives.some(function(r) { return r.rc !== true })
          text: root.drives.every(function(r) { return r.rc !== true })
                ? "Transfer activity and cache details need rclone's control socket — see the plugin README."
                : "No transfer activity for " + root.drives.filter(function(r) { return r.rc !== true })
                    .map(function(r) { return r.name }).join(", ") + ": no control socket — see the plugin README."
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          opacity: 0.45
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.remotes.length === 0
          text: "No rclone remotes found. Add one with `rclone config`; it will appear here, ready to set up."
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          opacity: 0.6
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
