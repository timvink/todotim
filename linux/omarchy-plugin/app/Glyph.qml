import QtQuick

// One icon from the Nerd Font (Font Awesome range) that Omarchy's monospace font carries.
Text {
  property var theme
  property real size: theme ? theme.icon : 14
  textFormat: Text.PlainText
  font.family: theme ? theme.font : "monospace"
  font.pixelSize: size
  color: theme ? theme.dim : "grey"
  verticalAlignment: Text.AlignVCenter
  horizontalAlignment: Text.AlignHCenter
}
