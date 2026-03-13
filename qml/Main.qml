import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import G5Audio 1.0

Kirigami.ApplicationWindow {
    id: root

        title: "PPC Stream Receiver"
    width: 800
    height: 480
    minimumWidth: 500
    minimumHeight: 440

    // ── Colours (dark theme) ──────────────────────────────────────────────────
    readonly property color bgCard: Qt.rgba(1, 1, 1, 0.04)
    readonly property color borderSubtle: Qt.rgba(1, 1, 1, 0.08)
    readonly property color accentColor: "#5599ff"
    readonly property color greenOk: "#44cc77"
    readonly property color redBad: "#ff5544"

    pageStack.initialPage: Kirigami.Page {
        id: mainPage
    title: "PPC Stream Receiver"

        // Disable default padding so we can fill the space
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

                        // Glow
                        Rectangle {
                            anchors.centerIn: parent
                            width: 20; height: 20; radius: 10
                            color: "transparent"
                            border.width: backend.isConnected ? 2 : 0
                            border.color: Qt.rgba(0.27, 0.8, 0.47, 0.35)
                        }
                    }

                    Controls.Label {
                        text: "Host:"
                    }
                    Controls.TextField {
                        id: hostField
                        text: "192.168.2.102"
                        Layout.fillWidth: true
                        Layout.minimumWidth: 100
                        enabled: !backend.isConnected
                    }

                    Controls.Label {
                        text: "Port:"
                    }
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
            //  Audio Visualiser
            // ══════════════════════════════════════════════════════════════════
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
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
                                else
                                    return "Actual:   —"
                            }
                            font.family: "monospace"
                            font.pointSize: 9
                            color: {
                                if (!backend.isConnected)
                                    return Kirigami.Theme.disabledTextColor
                                var ratio = backend.actualKbps / backend.nominalKbps
                                if (ratio > 0.95 && ratio < 1.05)
                                    return greenOk
                                else
                                    return redBad
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
                                source: volumeSlider.value === 0 ? "audio-volume-muted"
                                    : volumeSlider.value < 33 ? "audio-volume-low"
                                    : volumeSlider.value < 66 ? "audio-volume-medium"
                                    : "audio-volume-high"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
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

    Component.onDestruction: {
        if (backend)
            backend.disconnectFromServer()
    }
}
