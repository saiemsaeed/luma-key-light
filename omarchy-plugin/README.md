# Luma Key Light for Omarchy

An Omarchy Shell bar widget for controlling an Elgato Key Light without opening the full Luma window.

## Controls

- **Left-click:** open the control panel
- **Middle-click:** toggle the light
- **Right-click:** open Luma
- Panel controls: power, brightness, color temperature, scenes, and identify

The widget talks directly to the light over the local network. It does not require Luma to remain running.

## Install from the Luma repository

```sh
./scripts/install-omarchy-plugin.sh
```

The installer validates the plugin, copies it to `~/.config/omarchy/plugins/io.github.saiemsaeed.luma`, rescans plugins, and enables it in the right section of the bar.

## Configuration

Use the Omarchy bar settings UI to change:

- Light hostname or IP
- Device API port
- Refresh interval

The default hostname matches Luma's default device hostname.
