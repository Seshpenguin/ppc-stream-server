import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kirigami.delegates as KD
import G5Audio 1.0

Kirigami.ApplicationWindow {
    id: root

    title: "PPC Stream Receiver"
    width: 800
    height: 560
    minimumWidth: 520
    minimumHeight: 480

    // ── Colours (dark theme) ──────────────────────────────────────────────────
    readonly property color bgCard:       Qt.rgba(1, 1, 1, 0.04)
    readonly property color borderSubtle: Qt.rgba(1, 1, 1, 0.08)
    readonly property color accentColor:  "#5599ff"
    readonly property color greenOk:      "#44cc77"
    readonly property color redBad:       "#ff5544"

    pageStack.initialPage: Kirigami.Page {
        id: mainPage
        title: "PPC Stream Receiver"

        leftPadding: 0
        rightPadding: 0
        topPadding: 0
        bottomPadding: 0

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            // ══════════════════════════════════════════════════════════════════
            //  Connection card
            // ══════════════════════════════════════════════════════════════════
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: connectionRow.implicitHeight + Kirigami.Units.largeSpacing * 2
                color: bgCard
                radius: 8
                border.width: 1
                border.color: borderSubtle

                RowLayout {
                    id: connectionRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Kirigami.Units.largeSpacing
                    spacing: Kirigami.Units.mediumSpacing

                    // Status LED
                    Rectangle {
                        width: 14; height: 14; radius: 7
                        Layout.alignment: Qt.AlignVCenter
                        color: backend.isConnected ? greenOk : "#444"
                        border.width: 1
                        border.color: Qt.rgba(0, 0, 0, 0.3)
                        Rectangle {
                            anchors.centerIn: parent
                            width: 20; height: 20; radius: 10
                            color: "transparent"
                            border.width: backend.isConnected ? 2 : 0
                            border.color: Qt.rgba(0.27, 0.8, 0.47, 0.35)
                        }
                    }

                    Controls.Label { text: "Host:" }
                    Controls.TextField {
                        id: hostField
                        text: "192.168.2.102"
                        Layout.fillWidth: true
                        Layout.minimumWidth: 100
                        enabled: !backend.isConnected
                    }

                    Controls.Label { text: "Port:" }
                    Controls.SpinBox {
                        id: portSpin
                        from: 1; to: 65535; value: 7777
                        editable: true
                        enabled: !backend.isConnected
                    }

                    Controls.Label {
                        text: backend.statusMessage
                        color: backend.isConnected ? greenOk : Kirigami.Theme.disabledTextColor
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideRight
                    }

                    Controls.Button {
                        text: "Connect"
                        icon.name: "network-connect"
                        enabled: !backend.isConnected
                        onClicked: backend.connectToServer(hostField.text, portSpin.value)
                    }
                    Controls.Button {
                        text: "Disconnect"
                        icon.name: "network-disconnect"
                        enabled: backend.isConnected
                        onClicked: backend.disconnectFromServer()
                    }
                }
            }

            // ══════════════════════════════════════════════════════════════════
            //  Now Playing card  (shown only when iTunes has a track)
            // ══════════════════════════════════════════════════════════════════
            Rectangle {
                Layout.fillWidth: true
                visible: backend.isConnected && itunes.title !== ""
                implicitHeight: nowPlayingLayout.implicitHeight + Kirigami.Units.largeSpacing * 2
                color: bgCard
                radius: 8
                border.width: 1
                border.color: borderSubtle

                ColumnLayout {
                    id: nowPlayingLayout
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Kirigami.Units.largeSpacing
                    spacing: Kirigami.Units.smallSpacing

                    // ── Top row: artwork + controls ──────────────────────────
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        // Album art
                        Rectangle {
                            Layout.preferredWidth: nowPlayingLayout.width * 0.25
                            Layout.preferredHeight: nowPlayingLayout.width * 0.25
                            radius: 4
                            clip: true
                            color: Qt.rgba(1, 1, 1, 0.06)

                            Image {
                                anchors.fill: parent
                                source: itunes.artworkUrl
                                fillMode: Image.PreserveAspectCrop
                                smooth: true
                                cache: false
                            }

                            // Fallback icon when no artwork loaded
                            Kirigami.Icon {
                                anchors.centerIn: parent
                                width: 40; height: 40
                                source: "media-optical-audio"
                                visible: itunes.artworkUrl === ""
                            }
                        }

                        // Controls column
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            // Track title + state badge
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Controls.Label {
                                    text: itunes.title
                                    font.pointSize: 11
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                // Playback state badge
                                Rectangle {
                                    implicitWidth: stateLabel.implicitWidth + 12
                                    implicitHeight: stateLabel.implicitHeight + 4
                                    radius: 4
                                    color: {
                                        if (itunes.playbackState === "Playing") return Qt.rgba(0.27, 0.8, 0.47, 0.2)
                                        if (itunes.playbackState === "Paused")  return Qt.rgba(1,    0.7, 0.2,  0.2)
                                        return Qt.rgba(0.5, 0.5, 0.5, 0.2)
                                    }
                                    Controls.Label {
                                        id: stateLabel
                                        anchors.centerIn: parent
                                        text: itunes.playbackState
                                        font.pointSize: 8
                                        color: {
                                            if (itunes.playbackState === "Playing") return greenOk
                                            if (itunes.playbackState === "Paused")  return "#ffbb33"
                                            return Kirigami.Theme.disabledTextColor
                                        }
                                    }
                                }
                            }

                            // Artist / Album
                            Controls.Label {
                                text: itunes.artist + (itunes.album !== "" ? "  —  " + itunes.album : "")
                                font.pointSize: 9
                                color: Kirigami.Theme.disabledTextColor
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            // Progress bar (seek slider)
                            Controls.Slider {
                                id: progressSlider
                                Layout.fillWidth: true
                                from: 0
                                to: itunes.duration > 0 ? itunes.duration : 1
                                property real seekTarget: -1
                                value: pressed ? value
                                     : seekTarget >= 0 ? seekTarget
                                     : itunes.position
                                enabled: itunes.duration > 0
                                onMoved: {
                                    seekTarget = value
                                    itunes.seekTo(value)
                                }
                                Connections {
                                    target: itunes
                                    function onPositionChanged() {
                                        if (progressSlider.seekTarget >= 0
                                            && itunes.position >= progressSlider.seekTarget - 1) {
                                            progressSlider.seekTarget = -1
                                        }
                                    }
                                }
                            }

                            // Time labels + transport controls
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Controls.Label {
                                    text: _formatTime(itunes.position)
                                    font.pointSize: 8
                                    font.family: "monospace"
                                    color: Kirigami.Theme.disabledTextColor
                                }

                                Item { Layout.fillWidth: true }

                                Controls.ToolButton {
                                    icon.name: "media-skip-backward"
                                    onClicked: itunes.previous()
                                    enabled: backend.isConnected
                                }
                                Controls.ToolButton {
                                    icon.name: itunes.playbackState === "Playing"
                                               ? "media-playback-pause"
                                               : "media-playback-start"
                                    onClicked: itunes.playPause()
                                    enabled: backend.isConnected
                                }
                                Controls.ToolButton {
                                    icon.name: "media-playback-stop"
                                    onClicked: itunes.stopPlayback()
                                    enabled: backend.isConnected
                                }
                                Controls.ToolButton {
                                    icon.name: "media-skip-forward"
                                    onClicked: itunes.next()
                                    enabled: backend.isConnected
                                }
                                Controls.ToolButton {
                                    icon.name: itunes.repeatMode === "one"
                                               ? "media-repeat-track-amarok"
                                               : "media-repeat-all"
                                    checked: itunes.repeatMode !== "off"
                                    checkable: true
                                    enabled: backend.isConnected
                                    onClicked: itunes.cycleRepeat()
                                    Controls.ToolTip.text: {
                                        if (itunes.repeatMode === "off") return "Repeat: Off"
                                        if (itunes.repeatMode === "all") return "Repeat: All"
                                        return "Repeat: One"
                                    }
                                    Controls.ToolTip.visible: hovered
                                    Controls.ToolTip.delay: 500
                                }

                                Item { Layout.fillWidth: true }

                                Controls.Label {
                                    text: _formatTime(itunes.duration)
                                    font.pointSize: 8
                                    font.family: "monospace"
                                    color: Kirigami.Theme.disabledTextColor
                                }
                            }
                        }
                    }

                    // ── Playlist toggle ──────────────────────────────────────
                    Controls.ToolButton {
                        Layout.alignment: Qt.AlignHCenter
                        text: playlistContainer.visible ? "Hide Playlist" : "Show Playlist"
                        icon.name: "view-media-playlist"
                        onClicked: {
                            playlistContainer.visible = !playlistContainer.visible
                            if (playlistContainer.visible && root.height < 800)
                                root.height = 800
                        }
                        enabled: itunes.playlist.length > 0
                    }

                    // ── Collapsible playlist ─────────────────────────────────
                    Rectangle {
                        id: playlistContainer
                        visible: false
                        Layout.fillWidth: true
                        implicitHeight: playlistView.implicitHeight
                        color: "white"
                        radius: 4
                        border.width: 1
                        border.color: borderSubtle

                        ListView {
                            id: playlistView
                            anchors.fill: parent
                            implicitHeight: Math.min(contentHeight, 200)
                            clip: true
                            model: itunes.playlist
                            highlightFollowsCurrentItem: false
                            currentIndex: {
                                for (var i = 0; i < itunes.playlist.length; i++) {
                                    if (itunes.playlist[i].id === itunes.currentTrackId)
                                        return i
                                }
                                return -1
                            }
                            delegate: Controls.ItemDelegate {
                                width: playlistView.width
                                padding: 4
                                topPadding: 2
                                bottomPadding: 2
                                highlighted: index === playlistView.currentIndex
                                contentItem: KD.TitleSubtitle {
                                    title: modelData.title
                                    subtitle: modelData.artist + (modelData.album !== "" ? " — " + modelData.album : "")
                                    font.pointSize: 9
                                    subtitleFont.pointSize: 8
                                }
                                onClicked: itunes.playById(modelData.id)

                                Kirigami.Separator {
                                    anchors.bottom: parent.bottom
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                }
                            }

                            Controls.ScrollBar.vertical: Controls.ScrollBar {}
                        }
                    }
                }
            }

            // ══════════════════════════════════════════════════════════════════
            //  Audio Visualiser
            // ══════════════════════════════════════════════════════════════════
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.maximumHeight: 300
                color: bgCard
                radius: 8
                border.width: 1
                border.color: borderSubtle

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 1
                    spacing: 0

                    Controls.Label {
                        text: "  Audio Visualizer"
                        font.pointSize: 9
                        font.weight: Font.DemiBold
                        color: Kirigami.Theme.disabledTextColor
                        Layout.topMargin: 4
                        Layout.leftMargin: 4
                    }

                    AudioVisualizer {
                        id: visualizer
                        objectName: "visualizer"
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.margins: 4
                        connected: backend.isConnected
                    }
                }
            }

            // ══════════════════════════════════════════════════════════════════
            //  Bottom row: Stream info + Volume
            // ══════════════════════════════════════════════════════════════════
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                // ── Stream Info card ──────────────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: infoCol.implicitHeight + Kirigami.Units.largeSpacing * 2
                    color: bgCard
                    radius: 8
                    border.width: 1
                    border.color: borderSubtle

                    ColumnLayout {
                        id: infoCol
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.largeSpacing
                        spacing: 4

                        Controls.Label {
                            text: "Stream Info"
                            font.pointSize: 9
                            font.weight: Font.DemiBold
                            color: Kirigami.Theme.disabledTextColor
                        }
                        Controls.Label {
                            text: "Format:   " + backend.formatString
                            font.family: "monospace"
                            font.pointSize: 9
                        }
                        Controls.Label {
                            text: "Nominal:  " + backend.nominalKbps + " kbps"
                            font.family: "monospace"
                            font.pointSize: 9
                        }
                        Controls.Label {
                            text: {
                                if (backend.isConnected && backend.actualKbps > 0)
                                    return "Actual:   " + Math.round(backend.actualKbps) + " kbps"
                                return "Actual:   \u2014"
                            }
                            font.family: "monospace"
                            font.pointSize: 9
                            color: {
                                if (!backend.isConnected)
                                    return Kirigami.Theme.disabledTextColor
                                var ratio = backend.actualKbps / backend.nominalKbps
                                return (ratio > 0.95 && ratio < 1.05) ? greenOk : redBad
                            }
                        }
                    }
                }

                // ── Volume card ───────────────────────────────────────────────
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: volCol.implicitHeight + Kirigami.Units.largeSpacing * 2
                    color: bgCard
                    radius: 8
                    border.width: 1
                    border.color: borderSubtle

                    ColumnLayout {
                        id: volCol
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.largeSpacing
                        spacing: 4

                        Controls.Label {
                            text: "Volume"
                            font.pointSize: 9
                            font.weight: Font.DemiBold
                            color: Kirigami.Theme.disabledTextColor
                        }

                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing
                            Layout.fillWidth: true

                            Kirigami.Icon {
                                source: volumeSlider.value === 0   ? "audio-volume-muted"
                                      : volumeSlider.value < 33    ? "audio-volume-low"
                                      : volumeSlider.value < 66    ? "audio-volume-medium"
                                      : "audio-volume-high"
                                Layout.preferredWidth:  Kirigami.Units.iconSizes.smallMedium
                                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            }

                            Controls.Slider {
                                id: volumeSlider
                                from: 0; to: 100; value: 100; stepSize: 1
                                Layout.fillWidth: true
                                onValueChanged: backend.setVolume(value / 100.0)
                            }

                            Controls.Label {
                                text: Math.round(volumeSlider.value) + " %"
                                font.weight: Font.DemiBold
                                color: accentColor
                                Layout.preferredWidth: 40
                                horizontalAlignment: Text.AlignRight
                            }
                        }
                    }
                }
            }
        }
    }

    // ── helpers ───────────────────────────────────────────────────────────────
    function _formatTime(secs) {
        var s = Math.max(0, Math.floor(secs))
        var m = Math.floor(s / 60)
        s = s % 60
        return m + ":" + (s < 10 ? "0" : "") + s
    }

    Component.onDestruction: {
        if (backend) backend.disconnectFromServer()
    }
}
