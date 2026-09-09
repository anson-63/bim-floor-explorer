# BIM 3D Viewer for Flutter

A Flutter app for browsing large 3D BIM and GIS datasets in ArcGIS, with support for offline Mobile Scene Packages (MSPK), online ArcGIS Portal content, layer visibility controls, and floor-aware building exploration.

The app is organized around a building-first scene model: each building acts as a group container, and each floor is treated as a separate layer set for navigation and inspection.

## Why this project exists

This app is designed for a common BIM review task: understanding a building in context instead of looking at a single flat 3D model. It expects each building to be grouped and each floor to be separated so users can:

- focus on one building at a time
- inspect floor-level content selectively
- hide or dim floors above and below the current view
- move through the dataset in a more readable and navigable way

## Overview

The app supports two major data paths:

- offline MSPK scenes from local cache or bundled assets
- online ArcGIS Web Scene / Portal resources when configured

Once a scene is loaded, the user can:

- switch between offline and online modes
- choose which operational layers are visible
- fly to specific layers or building extents
- detect the active building from the camera position
- move through building floors with a floor explorer
- render a tailored viewport for review and presentation

## Features

- offline-first data loading with local cache and bundled fallback support
- online ArcGIS Portal and Web Scene compatibility
- portal discovery for MSPK files tagged with `local mobile app`
- cached MSPK download and reuse for mobile/offline workflows
- live layer visibility management and status tracking
- building detection based on camera center and building extent
- floor-level view control for above/below-floor visibility rules
- tailored viewport rendering after scene configuration
- local cache reset from the launcher UI

## How it works

The application follows a simple but important runtime flow:

1. It starts in offline mode by default.
2. If internet access is available, it can query ArcGIS Portal for MSPK files tagged `local mobile app`.
3. The user selects a local or downloaded MSPK, or the app falls back to a bundled offline asset.
4. When online mode is configured, it loads a hosted ArcGIS Web Scene item from Portal.
5. The scene is bound to the ArcGIS runtime view and its operational layers are prepared for interaction.
6. The app identifies building groups and floor layers, then determines the current building from the camera position.
7. The floor explorer changes layer visibility and opacity to emphasize the current floor while lowering the context of adjacent floors.
8. Users can toggle layers and render the final tailored viewport for review.

## Required BIM preprocessing

This app expects a very specific ArcGIS scene structure before floor-based navigation can work reliably:

- each building is a separate `GroupLayer`
- each building group contains floor-specific child layers
- features are separated by elevation before import
- floors are assigned under the matching parent building
- child layer names follow a predictable naming pattern such as:

```text
BuildingName_1F
BuildingName_2F
BuildingName_3F
```

The intended structure is:

```text
Building Group Layer
  ├── Floor 1 layer
  ├── Floor 2 layer
  ├── Floor 3 layer
  └── ...
```

This is a core requirement for the app logic: it detects the active building from the group layer and then reads the floor names from the child scene layers to drive the navigation behavior.

## Project structure

- `app.dart` – main Flutter UI, ArcGIS scene loading logic, layer management, floor detection, and camera behavior
- `pubspec.yaml` – project dependencies and Flutter metadata
- `android/` – Android app configuration
- `ust_auditorium/` – project-specific folder in the workspace, currently empty in this repo snapshot
- `asset/` – expected bundled asset folder for fallback MSPK data, such as your packaged building scene

## Dependencies

This project uses:

- `flutter`
- `arcgis_maps`
- `arcgis_maps_toolkit`
- `path_provider`

## Setup

### 1) Install dependencies

```bash
flutter pub get
```

### 2) Prepare offline asset data

The app is designed to use a bundled MSPK fallback when no cached portal item is available. Add your own packaged scene asset to the project under a path such as:

```text
asset/your_bim_scene.mspk
```

If that file is not present, the app will still try to use cached or Portal-provided data, but the bundled offline fallback will not be available until your asset is added to the project.

### 3) Configure online ArcGIS access

Online features are enabled by passing values at build/run time with `--dart-define`:

```bash
flutter run \
  --dart-define=ARCGIS_PORTAL_URI="https://your-portal-url" \
  --dart-define=ARCGIS_CLIENT_ID="your-client-id" \
  --dart-define=ARCGIS_WEB_SCENE_ITEM_ID="your-web-scene-item-id"
```

If any of the required values are missing, the app stays in offline mode by default.

## Usage

### Offline mode

- Launch the app without online configuration and it will default to local/offline mode.
- The app checks for local MSPK cache files and uses them if available.
- If no cache exists, it tries to use a bundled fallback asset such as `asset/your_bim_scene.mspk`.
- When internet is available, it can also query the portal for MSPK items tagged `local mobile app`.

### Online mode

- Toggle the source selector from Local Storage to Cloud Portal when internet is available.
- The app loads the configured Web Scene item from the portal.
- Operational layers are listed and can be toggled from the drawer and launcher.

### Floor exploration

The current implementation expects the dataset to already be organized by building and by floor, using a structure like:

```text
BuildingName
  ├── BuildingName_1F
  ├── BuildingName_2F
  ├── BuildingName_3F
```

Then the app can:
- detect the active building from the current camera center,
- display the building name and current floor,
- hide floors above the current view,
- lower opacity for floors below the current floor,
- restore full visibility when viewing all floors.

This means the data pipeline must separate features by elevation and assign them to a parent building before loading into the app.

## Notes

- This app is focused on a mobile ArcGIS 3D BIM workflow rather than a generic template.
- The code includes a fallback offline pipeline and portal-based data lookup for real-world assets.
- The app expects valid ArcGIS Portal configuration for online content.
- The UI includes robust state resets and scene cleanup to reduce crashes during data switching, but real-world ArcGIS scene loading can still be sensitive to timing and asset validity.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Example build commands

```bash
flutter clean
flutter pub get
flutter build apk --release
```

For a release with portal configuration enabled:

```bash
flutter build apk --release \
  --dart-define=ARCGIS_PORTAL_URI="https://your-portal-url" \
  --dart-define=ARCGIS_CLIENT_ID="your-client-id" \
  --dart-define=ARCGIS_WEB_SCENE_ITEM_ID="your-web-scene-item-id"
```
