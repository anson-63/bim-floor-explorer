// ignore_for_file: duplicate_ignore, avoid_print

import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:arcgis_maps/arcgis_maps.dart';
import 'package:arcgis_maps_toolkit/arcgis_maps_toolkit.dart';

const String _portalUriValue = String.fromEnvironment(
  'ARCGIS_PORTAL_URI',
  defaultValue: '',
);
const String _clientIdValue = String.fromEnvironment(
  'ARCGIS_CLIENT_ID',
  defaultValue: '',
);
const String _onlineWebSceneItemIdValue = String.fromEnvironment(
  'ARCGIS_WEB_SCENE_ITEM_ID',
  defaultValue: '',
);

void main() {
  // ✅ Diagnostic: catch any uncaught Flutter framework errors
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    print("💥 FLUTTER CRASH: ${details.exception}");
    print("💥 STACK:\n${details.stack}");
  };

  // ✅ Diagnostic: catch any uncaught platform / async errors
  PlatformDispatcher.instance.onError = (error, stack) {
    print("💥 PLATFORM CRASH: $error");
    print("💥 STACK:\n$stack");
    return true;
  };

  runApp(MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: Colors.white,
      listTileTheme: const ListTileThemeData(
        textColor: Colors.black,
        iconColor: Colors.black87,
        subtitleTextStyle: TextStyle(color: Colors.black54),
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        textColor: Colors.black,
        collapsedTextColor: Colors.black,
        iconColor: Colors.black,
        collapsedIconColor: Colors.black,
      ),
      textTheme: const TextTheme(
        bodySmall: TextStyle(color: Colors.black),
        bodyMedium: TextStyle(color: Colors.black),
        bodyLarge: TextStyle(color: Colors.black),
        titleSmall: TextStyle(color: Colors.black),
        titleMedium: TextStyle(color: Colors.black),
        titleLarge: TextStyle(color: Colors.black),
        labelLarge: TextStyle(color: Colors.black),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.deepPurple;
          }
          return Colors.white;
        }),
        checkColor: WidgetStateProperty.all(Colors.white),
      ),
    ),
    home: const MainApp(),
  ));
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});
  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  @override
  Widget build(BuildContext context) {
    if (_portalUriValue.isEmpty || _clientIdValue.isEmpty) {
      return const DynamicContentsPaneWidget();
    }

    final oauthConfig = OAuthUserConfiguration(
      portalUri: Uri.parse(_portalUriValue),
      clientId: _clientIdValue,
      redirectUri: Uri.parse('first://auth'),
    );

    return Authenticator(
      oAuthUserConfigurations: [oauthConfig],
      child: const DynamicContentsPaneWidget(),
    );
  }
}

class DynamicContentsPaneWidget extends StatefulWidget {
  const DynamicContentsPaneWidget({super.key});
  @override
  State<DynamicContentsPaneWidget> createState() =>
      _DynamicContentsPaneWidgetState();
}

extension EnvelopeContains on Envelope {
  bool containsPoint(ArcGISPoint point) {
    return point.x >= xMin &&
        point.x <= xMax &&
        point.y >= yMin &&
        point.y <= yMax;
  }
}

class _DynamicContentsPaneWidgetState extends State<DynamicContentsPaneWidget>
    with WidgetsBindingObserver {
  // ─────────────────────────────────────────────────────────────────────────
  // State
  // ─────────────────────────────────────────────────────────────────────────
  dynamic _sceneViewController;
  MobileScenePackage? _activeMspk;

  List<PortalItem> _availableMspkItems = [];  // Items from portal query
  PortalItem? _selectedMspkItem;               // User's choice
  bool _isQueryingPortal = false;
  String? _portalQueryError;
  final String _mspkSearchTag = 'local mobile app';

  bool _isNativeTransitioning = false;
  Timer? _stabilityTimer;

  bool _isOfflineMode = true;
  bool _isLoadingResourceMetadata = false;
  bool _isSceneReadyToRender = false;
  bool _hasAutoOpenedDrawer = false;
  bool _hasInternet = true;

  // ✅ Disposal guard — set TRUE on dispose, checked everywhere
  bool _isDisposed = false;

  // ✅ Bind guard — prevents overlapping _bindSceneToLiveController calls
  bool _isBinding = false;
  int _bindGeneration = 0;

  // ✅ Pipeline mutex — serializes _loadResourceStructure calls
  Completer<void>? _pipelineLock;

  int _currentFloor = 999;
  List<int> floors = [];
  int _minFloor = 0;
  int _maxFloor = 1;
  String? _activeBuilding;
  List<String> _buildingNames = [];

  ArcGISScene? _configuredScene;
  FeatureLayer? _selectedFeatureLayer;
  List<Layer> _operationalLayers = [];
  List<ElevationSource> _elevationSources = [];
  final Map<String, bool> _layerVisibilityMap = {};
  final Map<int, bool> _elevationVisibilityMap = {};
  Viewpoint? _pendingViewpoint;

  bool _cameraApplied = false;
  Timer? _viewpointDebounceTimer;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  int _pipelineGeneration = 0;

  final List<StreamSubscription<dynamic>> _sceneSubscriptions = [];
  final List<StreamSubscription<dynamic>> _layerSubscriptions = [];

  // Portal item IDs
  final String _onlineWebSceneItemId = _onlineWebSceneItemIdValue;

  // ─────────────────────────────────────────────────────────────────────────
  // Safety helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Safe setState wrapper that checks disposal before calling.
  void _safeSetState(VoidCallback fn) {
    if (_isDisposed || !mounted) return;
    setState(fn);
  }

  /// Safe wrapper around any native call that could crash if controller is gone.
  T? _safeCall<T>(T Function() fn, {String label = 'native call'}) {
    if (_isDisposed) return null;
    try {
      return fn();
    } catch (e) {
      print("⚠️ [SafeCall] $label failed: $e");
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Connectivity
  // ─────────────────────────────────────────────────────────────────────────
  Future<bool> checkInternet() async {
    print("🌍 [Connectivity] Starting probe (google.com)...");
    final sw = Stopwatch()..start();
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      sw.stop();
      print("🌍 [Connectivity] DNS done in ${sw.elapsedMilliseconds}ms");
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        print("✅ [Connectivity] ONLINE: ${result[0].address}");
        return true;
      }
    } on SocketException catch (e) {
      sw.stop();
      print(
          "❌ [Connectivity] OFFLINE after ${sw.elapsedMilliseconds}ms: ${e.message}");
      return false;
    } on TimeoutException {
      sw.stop();
      print(
          "❌ [Connectivity] OFFLINE — DNS timed out after ${sw.elapsedMilliseconds}ms");
      return false;
    }
    return false;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Asset copy helper
  // ─────────────────────────────────────────────────────────────────────────
  Future<String> copyMspkFromAssets(String assetPath, String filename) async {
    print("📦 [Asset Copy] '$assetPath' -> '$filename'");
    final byteData = await rootBundle.load(assetPath);
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/$filename';
    final file = File(filePath);
    await file.writeAsBytes(byteData.buffer.asUint8List());
    print("📦 [Asset Copy] Done. Size: "
        "${(await file.length() / (1024 * 1024)).toStringAsFixed(2)} MB");
    return filePath;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // AOT download helper
  // ─────────────────────────────────────────────────────────────────────────
  Future<File> _downloadPortalItemToAotCache(
      PortalItem mspkPortalItem, String localPath) async {
    print("📥 [AOT Sync] Fetching item: ${mspkPortalItem.itemId}");
    final sw = Stopwatch()..start();
    final dataStream = await mspkPortalItem.fetchData();
    print("📥 [AOT Sync] Fetch done in ${sw.elapsedMilliseconds}ms. "
        "Bytes: ${dataStream.length}");
    final localFile = File(localPath);
    final writeStart = sw.elapsedMilliseconds;
    await localFile.writeAsBytes(dataStream);
    print(
        "💾 [AOT Sync] Write took ${sw.elapsedMilliseconds - writeStart}ms");
    sw.stop();
    final sizeMb = (await localFile.length()) / (1024 * 1024);
    print("💾 [AOT Sync] Saved ${sizeMb.toStringAsFixed(2)} MB "
        "in ${sw.elapsedMilliseconds}ms total");
    return localFile;
  }

  Future<void> _loadWithTimeout(
    Future<void> future,
    String label, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final sw = Stopwatch()..start();
    print("⏱️ [Load] Starting $label with timeout ${timeout.inSeconds}s");
    try {
      await future.timeout(timeout);
      sw.stop();
      print("✅ [Load] $label completed in ${sw.elapsedMilliseconds}ms");
    } on TimeoutException catch (_) {
      sw.stop();
      print("⏰ [Load] $label timed out after ${sw.elapsedMilliseconds}ms");
      rethrow;
    }
  }

  void _logElevationSources(String stage, Iterable<ElevationSource> sources) {
    final sourceList = sources.toList();
    print("⛰️ [Elevation] $stage | count=${sourceList.length}");
    if (sourceList.isEmpty) {
      print("⛰️ [Elevation] $stage | no elevation sources present.");
      return;
    }

    for (var index = 0; index < sourceList.length; index++) {
      final src = sourceList[index];
      print(
          "   ⛰️ [Elevation] #$index name='${src.name}' type=${src.runtimeType} id=${src.hashCode}");
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Camera helpers
  // ─────────────────────────────────────────────────────────────────────────

  Camera _buildTiltedCameraForExtent(Envelope extent,
      {double pitch = 45.0}) {
    final center = extent.center;
    final diagonal =
        sqrt(extent.width * extent.width + extent.height * extent.height);
    final viewDistance = diagonal * 1.5;

    final zMax = extent.zMax;
    final lookAtZ = (zMax != null && zMax.isFinite) ? zMax : 0.0;

    return Camera.withLookAtPoint(
      lookAtPoint: ArcGISPoint(
        x: center.x,
        y: center.y,
        z: lookAtZ,
        spatialReference: extent.spatialReference,
      ),
      distance: viewDistance,
      heading: 0,
      pitch: pitch,
      roll: 0,
    );
  }

  Camera? _findShawAuditoriumCamera() {
    final candidates = [
      'Shaw Auditorium',
      'ShawAuditorium',
      'Shaw_Auditorium',
      'Auditorium',
      'Shaw'
    ];

    Layer? shawLayer;
    String? matchedName;

    for (final layer in _operationalLayers) {
      for (final c in candidates) {
        if (layer.name == c) {
          shawLayer = layer;
          matchedName = c;
          break;
        }
      }
      if (shawLayer != null) break;

      final lname = layer.name.toLowerCase();
      if (lname.contains('shaw') || lname.contains('auditorium')) {
        shawLayer = layer;
        matchedName = layer.name;
        break;
      }
    }

    if (shawLayer == null) {
      print("🎯 [Init] Shaw Auditorium not found in operational layers.");
      return null;
    }

    final extent = shawLayer.fullExtent;
    if (extent == null || extent.isEmpty || extent.width <= 0) {
      print("🎯 [Init] '$matchedName' has no usable extent.");
      return null;
    }

    print("🎯 [Init] Found Shaw target: '$matchedName'");

    _layerVisibilityMap[shawLayer.id] = true;
    shawLayer.isVisible = true;

    return _buildTiltedCameraForExtent(extent, pitch: 45.0);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(_isSceneReadyToRender
            ? (_isOfflineMode
                ? "3D View (Offline Workspace)"
                : "3D View (Online Live)")
            : "ArcGIS Project Launcher",
            style: const TextStyle(color: Colors.black),  
          ),
          backgroundColor: Colors.white,                   // ✅ ADD — explicit bg
          foregroundColor: Colors.black,
        actions: [
          // ✅ Connectivity indicator — tap to re-check
          IconButton(
            icon: Icon(
              _hasInternet ? Icons.wifi : Icons.wifi_off,
              color: _hasInternet ? Colors.green : Colors.red,
            ),
            tooltip: _hasInternet
                ? "Internet available"
                : "No internet — online mode disabled",
            onPressed: () async {
              final isOnline = await checkInternet();
              if (_isDisposed || !mounted) return;
              _safeSetState(() => _hasInternet = isOnline);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(isOnline
                      ? "✅ Internet available"
                      : "❌ No internet",
                      style: const TextStyle(color: Colors.black),  
                    ),
                  backgroundColor: isOnline ? Colors.green : Colors.red,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
          if (_isSceneReadyToRender)
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.layers),
                tooltip: "Layer Selection",
                onPressed: () => Scaffold.of(context).openEndDrawer(),
              ),
            ),
          if (_isSceneReadyToRender)
            IconButton(
              icon: const Icon(Icons.exit_to_app),
              tooltip: "Return to Selection Tree",
              onPressed: () async{
                print("🔙 [UI] Exiting scene view.");
                _markNativeTransitioning();
                _pipelineGeneration++;
                _cancelAllSceneSubscriptions();
                _cancelLayerSubscriptions();
                _safeSetState(() {
                  _isSceneReadyToRender = false;
                  _activeMspk = null;
                  // ✅ Just clear the scene reference, don't replace controller
                  _safeCall(
                    () => _sceneViewController?.arcGISScene = null,
                    label: 'clear scene on exit',
                  );
                  _sceneViewController = null;
                  _hasAutoOpenedDrawer = false;
                  _cameraApplied = false;
                  _activeBuilding = null;
                  _configuredScene = null;
                  _operationalLayers.clear();
                  _elevationSources.clear();
                  _layerVisibilityMap.clear();
                  _elevationVisibilityMap.clear();
                  _buildingNames.clear();
                  floors.clear();
                  _selectedFeatureLayer = null;
                  _pendingViewpoint = null;
                });

                await Future.delayed(const Duration(milliseconds: 300));
                if (_isDisposed) return;
                _loadResourceStructure();
              },
            ),
        ],
      ),
      endDrawer: _isSceneReadyToRender
          ? _LiveLayerDrawer(
              operationalLayers: _operationalLayers,
              visibilityMap: _layerVisibilityMap,
              onChanged: () {
                for (var layer in _operationalLayers) {
                  layer.isVisible = _layerVisibilityMap[layer.id] ?? false;
                }
              },
              onFlyTo: (layer) {
                final extent = layer.fullExtent;
                if (extent != null && !extent.isEmpty) {
                  _layerVisibilityMap[layer.id] = true;
                  layer.isVisible = true;
                  final camera =
                      _buildTiltedCameraForExtent(extent, pitch: 45.0);
                  _safeCall(
                    () => _sceneViewController?.setViewpointCameraAnimated(
                      camera: camera,
                      duration: 1.5,
                    ),
                    label: 'fly-to from drawer',
                  );
                }
              },
            )
          : null,
          body: Stack(
          children: [
            // ✅ Wrap body in IgnorePointer when transitioning
            IgnorePointer(
              ignoring: _isNativeTransitioning,
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 14,
                ),
                child: _isSceneReadyToRender 
                    ? _buildSceneBody() 
                    : _buildLauncherBody(),
              ),
            ),
            
            // ✅ Show overlay during transition
            if (_isNativeTransitioning)
              Container(
                color: Colors.black.withOpacity(0.3),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 16),
                      Text(
                        "Preparing scene...",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
    );
  }

  /// Gets floor layers ONLY for the active building
  List<ArcGISSceneLayer> get _floorLayers {
    final result = <ArcGISSceneLayer>[];

    for (final layer in _operationalLayers) {
      if (layer is GroupLayer) {
        final matchGroup =
            _activeBuilding == null || layer.name == _activeBuilding;

        if (matchGroup) {
          for (final subLayer in layer.layers) {
            if (subLayer is ArcGISSceneLayer) {
              final match = RegExp(r'^(.+)_(\d+)F$').firstMatch(subLayer.name);
              if (match != null) {
                result.add(subLayer);
              }
            }
          }
        }
      }
    }

    return result;
  }

  Widget _floorNav() {
    return Card(
      color: Colors.white,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 2.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_activeBuilding != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: Text(
                  _activeBuilding!,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            IconButton(
              icon: Icon(Icons.arrow_upward,
                  color: _currentFloor <= _maxFloor
                      ? Colors.blue
                      : Colors.white),
              onPressed: () {
                if (_currentFloor < _maxFloor) {
                  _showFloor(_currentFloor + 1);
                } else if (_currentFloor == _maxFloor || _currentFloor == 999) {
                  _showFloor(999);
                }
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                _currentFloor == 0
                    ? "G"
                    : _currentFloor == 999
                        ? "All"
                        : "$_currentFloor",
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              icon: Icon(Icons.arrow_downward,
                  color: _currentFloor > _minFloor
                      ? Colors.blue
                      : Colors.white),
              onPressed: () {
                if (_currentFloor == 999) {
                  _showFloor(_maxFloor);
                } else if (_currentFloor > _minFloor) {
                  _showFloor(_currentFloor - 1);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSceneBody() {
    print(
        "🏗️ [BuildSceneBody] isOffline=$_isOfflineMode controller=${_sceneViewController?.runtimeType}");
      ArcGISLocalSceneViewController? _localController;
      ArcGISSceneViewController? _onlineController;
    return Stack(
      children: [
        _isOfflineMode
            ? ArcGISLocalSceneView(
                controllerProvider: () {
                  _localController ??= ArcGISLocalSceneView.createController();
                  _sceneViewController = _localController;
                  return _localController!;
                },
                onLocalSceneViewReady: () async {
                  print("🖥️ [onSceneViewReady] Local GPU ready.");
                  await Future.delayed(const Duration(milliseconds: 50));
                  if (_isDisposed) return;
                  _bindSceneToLiveController();
                },
                onTap: onTap,
              )
            : ArcGISSceneView(
                controllerProvider: () {
                  if (_sceneViewController is! ArcGISSceneViewController) {
                    _sceneViewController = ArcGISSceneView.createController();
                  }
                  return _sceneViewController as ArcGISSceneViewController;
                },
                onSceneViewReady: () async {
                  print("🖥️ [onSceneViewReady] Global GPU ready.");
                  _bindSceneToLiveController();
                },
                onTap: onTap,
              ),
        Positioned(
          right: 16,
          bottom: 100,
          child: SafeArea(
            child: _floorNav(),
          ),
        ),
      ],
    );
  }

  Widget _buildLauncherBody() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Select Data Resource Source:",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black)),
          const SizedBox(height: 8),
          Card(
            elevation: 2,
            child: SwitchListTile(
              title: Text(_isOfflineMode
                  ? "Local Storage Resource"
                  : "Cloud Portal Resource",
                style: const TextStyle(color: Colors.black),    
                ),
              subtitle: Text(
                _isOfflineMode
                    ? (_hasInternet
                        ? "Bundled BIM scene archive"
                        : "📡 No internet — online mode disabled")
                    : "Live hosted layer servers",
                style: const TextStyle(color: Colors.black),  
              ),
              value: _isOfflineMode,
              activeThumbColor: Colors.orange,
              inactiveThumbColor: Colors.green,
              // ✅ Disable toggle when no internet (locked in offline)
              onChanged: !_hasInternet
                  ? null
                  : (val) async{
                      print(
                          "🔀 [UI] Mode -> ${val ? 'OFFLINE' : 'ONLINE'}");
                      _markNativeTransitioning();
                      _pipelineGeneration++;
                      _cancelAllSceneSubscriptions();
                      _cancelLayerSubscriptions();
                      _safeSetState(() {
                        _isOfflineMode = val;
                        _configuredScene = null;
                        _isSceneReadyToRender = false;
                        _activeMspk = null;
                        _safeCall(
                          () => _sceneViewController?.arcGISScene = null,
                          label: 'clear scene on mode switch',
                        );
                        // ✅ null out, let controllerProvider re-create
                        _sceneViewController = null;
                        _hasAutoOpenedDrawer = false;
                        _cameraApplied = false;
                        _activeBuilding = null;
                      });

                      await Future.delayed(const Duration(milliseconds: 500));
                      if (_isDisposed) return;
                      _loadResourceStructure();
                    },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              label: const Text("Clear Local Cache",
                  style: TextStyle(color: Colors.red)),
              onPressed: () async {
                final messenger = ScaffoldMessenger.maybeOf(context);
                final docDir = await getApplicationDocumentsDirectory();
                
                // Delete ALL cached MSPK files
                final cachedFiles = await _findCachedMspks(docDir);
                for (final f in cachedFiles) {
                  try {
                    await f.delete();
                    print("🗑️ [Cache] Deleted ${f.path}");
                  } catch (e) {
                    print("⚠️ [Cache] Could not delete ${f.path}: $e");
                  }
                }
                
                // Also delete the fallback
                final fallback = File('${docDir.path}/fallback_aot_cache.mspk');
                if (await fallback.exists()) await fallback.delete();
                
                if (!mounted) return;
                
                // Reset selection state and reload
                _safeSetState(() {
                  _selectedMspkItem = null;
                  _availableMspkItems.clear();
                  _configuredScene = null;
                  _operationalLayers.clear();
                });
                
                _loadResourceStructure();
                
                messenger?.showSnackBar(
                  const SnackBar(content: Text("Cache cleared.")),
                );
              },
            ),
          ),
          const Divider(height: 30, thickness: 1.5),
          const Text("Contents Pane (Drawing Order):",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black)),
          const SizedBox(height: 10),

          // ─── Loading state ───
          if (_isLoadingResourceMetadata || _isQueryingPortal)
            const Expanded(child: Center(child: CircularProgressIndicator()))

          // ─── Offline mode + Internet + Has portal MSPKs → Show picker ───
          else if (_isOfflineMode && _availableMspkItems.isNotEmpty && _configuredScene == null)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8.0),
                    child: Text(
                      "Select a Mobile Scene Package to render:",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _availableMspkItems.length,
                      itemBuilder: (context, index) {
                        final item = _availableMspkItems[index];
                        final isSelected = _selectedMspkItem?.itemId == item.itemId;
                        return Card(
                          color: isSelected ? Colors.deepPurple[50] : Colors.white,
                          child: ListTile(
                            leading: const Icon(Icons.map, color: Colors.deepPurple),
                            title: Text(
                              item.title,
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              item.snippet ?? 'No description',
                              style: const TextStyle(color: Colors.black54),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: isSelected
                                ? const Icon(Icons.check_circle, color: Colors.green)
                                : const Icon(Icons.chevron_right, color: Colors.grey),
                            onTap: () => _selectMspkItem(item),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            )

          // ─── No scene loaded yet ───
          else if (_configuredScene == null)
            Expanded(
              child: Center(
                child: Text(
                  _isOfflineMode && _availableMspkItems.isEmpty
                      ? (_hasInternet
                          ? "No MSPKs found on portal with tag '$_mspkSearchTag'."
                          : "📡 Offline — using local data")
                      : "Loading...",
                  style: const TextStyle(color: Colors.black),
                  textAlign: TextAlign.center,
                ),
              ),
            )

          // ─── Scene loaded → Show layer checkboxes ───
          else
            Expanded(
              child: ListView(
                children: [
                  if (_operationalLayers.isNotEmpty)
                    ExpansionTile(
                      title: const Text("Operational Layers",
                          style: TextStyle(color: Colors.black)),
                      leading: const Icon(Icons.category),
                      initiallyExpanded: true,
                      children: _operationalLayers.map((layer) {
                        final displayName =
                            layer.name.isEmpty ? "Unnamed Layer" : layer.name;
                        return CheckboxListTile(
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(displayName,
                              style: const TextStyle(color: Colors.black)),
                          subtitle: Text(
                            "Status: ${enumLabel(layer.loadStatus).toUpperCase()}",
                            style: TextStyle(
                                color: layer.loadStatus == LoadStatus.loaded
                                    ? Colors.green
                                    : Colors.orange),
                          ),
                          value: _layerVisibilityMap[layer.id] ?? false,
                          onChanged: (bool? checked) {
                            print("☑️ [UI] '$displayName' -> "
                                "${checked == true ? 'ON' : 'OFF'}");
                            _safeSetState(() {
                              _layerVisibilityMap[layer.id] = checked ?? false;
                            });
                          },
                          secondary: IconButton(
                            icon: const Icon(Icons.gps_fixed,
                                color: Colors.blue, size: 20),
                            tooltip: "Fly to layer",
                            onPressed: () async {
                              if (layer.loadStatus != LoadStatus.loaded) return;
                              final extent = layer.fullExtent;
                              if (extent == null || extent.isEmpty || extent.width <= 0) return;

                              _safeSetState(() {
                                _layerVisibilityMap[layer.id] = true;
                                layer.isVisible = true;
                              });

                              final camera = _buildTiltedCameraForExtent(extent, pitch: 45.0);
                              _safeCall(
                                () => _sceneViewController?.setViewpointCameraAnimated(
                                  camera: camera,
                                  duration: 1.5,
                                ),
                                label: 'fly-to from launcher',
                              );
                            },
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _configuredScene == null
                  ? null
                  : _renderFinalConfiguredScene,
              icon: const Icon(Icons.play_arrow),
              label: const Text("Render Tailored Viewport",
                style: const TextStyle(color: Colors.black),  
              ),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            ),
          ),
        ],
      ),
    );
  }

  // ─── onTap: identify popup ─────────────────────────────────────────────
  Future<void> onTap(Offset offset) async {
    if (_isDisposed) return;

    for (final layer in _operationalLayers) {
      if (layer is FeatureLayer) {
        layer.clearSelection();
      }
    }
    _selectedFeatureLayer = null;

    final results = await _safeCall<Future<dynamic>>(
      () => _sceneViewController?.identifyLayers(
        screenPoint: offset,
        tolerance: 22.0,
        returnPopupsOnly: false,
      ),
      label: 'identifyLayers',
    );
    if (results == null) return;

    final awaited = await results;
    if (_isDisposed || awaited == null) return;

    for (final result in awaited) {
      if (result.popups.isNotEmpty && result.geoElements.isNotEmpty) {
        final feature =
            result.geoElements.whereType<ArcGISFeature>().first;
        if (result.layerContent is FeatureLayer) {
          _selectedFeatureLayer = result.layerContent as FeatureLayer;
          _selectedFeatureLayer!.selectFeature(feature);
        }
        final popup = result.popups.first;
        showPopup(popup);
        return;
      }
    }
  }

  void showPopup(Popup popup) {
    if (_isDisposed || !mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: PopupView(
          popup: popup,
          onClose: () {
            Navigator.of(context).pop();
            _selectedFeatureLayer?.clearSelection();
            _selectedFeatureLayer = null;
          },
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════
  // _loadResourceStructure — pipeline (serialized via _pipelineLock)
  // ════════════════════════════════════════════════════════════════
  Future<void> _loadResourceStructure() async {
    if (_isDisposed) return;

    // ✅ Serialize: wait for any previous pipeline to fully finish
    if (_pipelineLock != null) {
      print("⏳ [Pipeline] Waiting for previous pipeline to complete...");
      try {
        await _pipelineLock!.future;
      } catch (_) {}
    }

    if (_isDisposed) return;
    _pipelineLock = Completer<void>();

    try {
      await _runPipelineBody();
    } finally {
      _pipelineLock?.complete();
      _pipelineLock = null;
    }
  }

  Future<void> _runPipelineBody() async {
    final myGeneration = ++_pipelineGeneration;
    bool isCancelled() => _isDisposed || myGeneration != _pipelineGeneration;
    _cancelLayerSubscriptions();

    final isOnline = await checkInternet();
    if (isCancelled()) return;

    _safeSetState(() {
      _hasInternet = isOnline;
      if (!isOnline && !_isOfflineMode) {
        print("⚠️ No internet — auto-switching to OFFLINE mode");
        _isOfflineMode = true;
      }
    });

    print("════════════════════════════════════════════");
    print("🚀 [Pipeline #$myGeneration] mode: ${_isOfflineMode ? 'OFFLINE' : 'ONLINE'}");
    print("════════════════════════════════════════════");
    final pipelineSw = Stopwatch()..start();

    _safeSetState(() {
      _isLoadingResourceMetadata = true;
      _operationalLayers.clear();
      _elevationSources.clear();
      _layerVisibilityMap.clear();
      _elevationVisibilityMap.clear();
      floors.clear();
      _availableMspkItems.clear();
      _selectedMspkItem = null;
    });

    try {
      // ── OFFLINE MODE ─────────────────────────────────────────────────
      if (_isOfflineMode) {
        // If online, query portal for MSPK items
        if (isOnline) {
          final items = await _queryAvailableMspks();
          if (isCancelled()) return;

          if (items.isNotEmpty) {
            // Don't auto-load — wait for user to pick
            _safeSetState(() {
              _isLoadingResourceMetadata = false;
            });
            print("📋 [Pipeline] ${items.length} MSPKs available — waiting for user pick");
            pipelineSw.stop();
            print("✅ [Pipeline #$myGeneration] DONE in ${pipelineSw.elapsedMilliseconds}ms (awaiting pick)");
            return;
          }
          print("⚠️ [Pipeline] No portal MSPKs found — falling back to cache/bundled");
        }

        // No internet OR empty result → load from cache or bundled
        final docDir = await getApplicationDocumentsDirectory();
        final cachedFiles = await _findCachedMspks(docDir);

        String mspkPathToUse;
        if (cachedFiles.isNotEmpty) {
          // Use first cached file (most recent download)
          mspkPathToUse = cachedFiles.first.path;
          print("📦 [Offline] Using cached MSPK: $mspkPathToUse");
        } else {
          mspkPathToUse = await copyMspkFromAssets(
              'asset/your_bim_scene.mspk', 'fallback_aot_cache.mspk');
          print("📦 [Offline] Using bundled asset (no cache available)");
        }
        if (isCancelled()) return;

        await _loadMspkFromPath(mspkPathToUse);
      }
      // ── ONLINE MODE ──────────────────────────────────────────────────
      else {
        if (_portalUriValue.isEmpty || _onlineWebSceneItemId.isEmpty) {
          _safeSetState(() {
            _isLoadingResourceMetadata = false;
            _portalQueryError = 'Online mode is not configured.';
          });
          return;
        }
        final portal = Portal(
          Uri.parse(_portalUriValue),
          connection: PortalConnection.authenticated,
        );
        final sceneItem = PortalItem.withPortalAndItemId(
          portal: portal,
          itemId: _onlineWebSceneItemId,
        );
        final targetScene = ArcGISScene.withItem(sceneItem);
        await _loadWithTimeout(targetScene.load(), 'Online ArcGISScene.load()');

        if (isCancelled()) return;

        _safeSetState(() {
          _activeMspk = null;
          _configuredScene = targetScene;
          _operationalLayers = targetScene.operationalLayers.toList();

          for (var layer in _operationalLayers) {
            _layerVisibilityMap[layer.id] = false;
            layer.isVisible = false;

            _layerSubscriptions.add(
              layer.onLoadStatusChanged.listen((status) {
                if (isCancelled()) return;
                print("🔄 '${layer.name}' -> ${enumLabel(status)}");
              }),
            );
          }

          _elevationSources = targetScene.baseSurface.elevationSources.toList();
          for (var src in _elevationSources) {
            _elevationVisibilityMap[src.hashCode] = true;
          }
          _isLoadingResourceMetadata = false;
        });
      }

      pipelineSw.stop();
      print("✅ [Pipeline #$myGeneration] DONE in ${pipelineSw.elapsedMilliseconds}ms");
    } catch (e, stack) {
      if (isCancelled()) return;
      pipelineSw.stop();
      print("❌ [Pipeline #$myGeneration] FAILED: $e");
      print("❌ Stack:\n$stack");
      _safeSetState(() => _isLoadingResourceMetadata = false);
    }
  }

  /// Finds all cached MSPK files in [docDir], sorted by modification time (newest first).
  Future<List<File>> _findCachedMspks(Directory docDir) async {
    final files = docDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.mspk'))
        .toList();
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Render preparation
  // ─────────────────────────────────────────────────────────────────────────
  void _renderFinalConfiguredScene({Viewpoint? targetViewpoint}) {
    if (_isDisposed) return;
    print(
        "🎨 [Render] Invoked. targetViewpoint: ${targetViewpoint != null}");

    if (_configuredScene == null) {
      print("⚠️ [Render] ABORTED — scene is null.");
      return;
    }

    _markNativeTransitioning();
    for (var layer in _operationalLayers) {
      final visible = _layerVisibilityMap[layer.id] ?? false;
      layer.isVisible = visible;
      print("   👁️ [Render] '${layer.name}' visible=$visible");
    }

    _configuredScene!.baseSurface.elevationSources.clear();
    int elevCount = 0;
    for (var src in _elevationSources) {
      if (_elevationVisibilityMap[src.hashCode] ?? false) {
        _configuredScene!.baseSurface.elevationSources.add(src);
        elevCount++;
      }
    }
    print("⛰️ [Render] $elevCount elevation source(s) attached.");

    _pendingViewpoint = targetViewpoint;

    if (_isSceneReadyToRender) {
      print("♻️ [Render] Scene already live — applying visibility only.");
      if (targetViewpoint != null) {
        _safeCall(
          () => _sceneViewController?.setViewpoint(targetViewpoint),
          label: 'setViewpoint on live render',
        );
        _pendingViewpoint = null;
      }
      _safeSetState(() {});
      return;
    }

    _cameraApplied = false;
    _safeSetState(() => _isSceneReadyToRender = true);
    print("✅ [Render] Flag raised. Waiting for onSceneViewReady...");
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Controller binding — idempotent, single source of truth
  // ─────────────────────────────────────────────────────────────────────────
  void _bindSceneToLiveController() {
    if (_isDisposed) return;
    if (_configuredScene == null || _sceneViewController == null) return;

    if (_isOfflineMode &&
      _sceneViewController is! ArcGISLocalSceneViewController) {
    print("⚠️ [Bind] Controller type mismatch (expected Local) — skipping");
    return;
  }
  if (!_isOfflineMode &&
      _sceneViewController is! ArcGISSceneViewController) {
    print("⚠️ [Bind] Controller type mismatch (expected Online) — skipping");
    return;
  }
    // ✅ Idempotency guard — refuse overlapping binds
    if (_isBinding) {
      print("⚠️ [Bind] Already in progress — skipping duplicate call");
      return;
    }
    _isBinding = true;
    final myBind = ++_bindGeneration;

    try {
      _cancelAllSceneSubscriptions();
      _cameraApplied = false;

      print("🔗 [Bind #$myBind] Called.");
      print(
          "🔗 [Bind] Scene SR: ${_configuredScene!.spatialReference?.wkid}");
      print(
          "🔗 [Bind] Layers: ${_configuredScene!.operationalLayers.length}");
      print(
          "🔗 [Bind] Elevation: ${_configuredScene!.baseSurface.elevationSources.length}");

      for (var layer in _configuredScene!.operationalLayers) {
        print(
            "   🔗 '${layer.name}' visible=${layer.isVisible} status=${layer.loadStatus}");
        if (layer is ArcGISSceneLayer) print("   🔗 URI: ${layer.uri}");
      }

      if (_isOfflineMode) {
        _configuredScene!.baseSurface.navigationConstraint =
            NavigationConstraint.stayAbove;
      }

      // ✅ Safe scene attach
      final attached = _safeCall(
        () {
          _sceneViewController.arcGISScene = _configuredScene;
          return true;
        },
        label: 'attach scene',
      );
      if (attached != true) {
        print("❌ [Bind] Binding failed.");
        return;
      }

      print("🔗 [Bind] Scene attached.");

      // ── Layer loading watch ─────────────────────────────────────────────
      for (final layer in _operationalLayers) {
        if (layer.loadStatus == LoadStatus.loading) {
          print("⏳ [Layer Watch] '${layer.name}' is already loading.");
          _sceneSubscriptions.add(
            Stream.fromFuture(
              Future<void>.delayed(const Duration(seconds: 20)),
            ).listen((_) {
              if (_isDisposed || !mounted) return;
              if (layer.loadStatus == LoadStatus.loading) {
                print("⏰ [Layer Watch] '${layer.name}' still loading after 20s.");
              }
            }),
          );
        } else if (layer.loadStatus == LoadStatus.notLoaded) {
          final genPipeline = _pipelineGeneration;
          final genBind = _bindGeneration;
          unawaited(() async {
            try {
              await _loadWithTimeout(
                  layer.load(), "Layer.load('${layer.name}')");
            } catch (e) {
              print("🚨 [Layer Load] '${layer.name}' failed: $e");
            }
          }());
        }
      }

      // ── Camera placement: Shaw first, then fallback ─────────────────────
      final shawCamera = _findShawAuditoriumCamera();
      if (shawCamera != null) {
        print(
            "🔗 [Bind] Going straight to Shaw Auditorium (skipping authored viewpoint).");
        _safeCall(
          () => _sceneViewController?.setViewpointCamera(shawCamera),
          label: 'set Shaw camera',
        );
      } else if (_configuredScene!.initialViewpoint != null) {
        print("🔗 [Bind] Forcing SR sync with initialViewpoint...");
        _safeCall(
          () => _sceneViewController
              ?.setViewpoint(_configuredScene!.initialViewpoint!),
          label: 'set initial viewpoint',
        );
      }

      // ── Detect buildings ────────────────────────────────────────────────
      _detectBuildings();

      // ── onDrawStatusChanged ─────────────────────────────────────────────
      _sceneSubscriptions.add(
        _sceneViewController.onDrawStatusChanged.listen((drawStatus) {
          if (_isDisposed) return;
          if (myBind != _bindGeneration) return;
          if (drawStatus == DrawStatus.completed && !_cameraApplied) {
            _cameraApplied = true;
            print("✅ Camera applied");
            _applyCamera();
            _markNativeStable();
          }
        }),
      );

      // ── onViewpointChanged ──────────────────────────────────────────────
      _sceneSubscriptions.add(
        _sceneViewController.onViewpointChanged.listen((_) {
          if (_isDisposed) return;
          if (myBind != _bindGeneration) return;
          _viewpointDebounceTimer?.cancel();
          _viewpointDebounceTimer =
              Timer(const Duration(milliseconds: 500), () {
            if (_isDisposed) return;
            if (myBind != _bindGeneration) return;
            _updateActiveBuildingFromCamera();
          });
        }),
      );

      // ── onSpatialReferenceChanged ───────────────────────────────────────
      _sceneSubscriptions.add(
        _sceneViewController.onSpatialReferenceChanged.listen((_) {
          if (_isDisposed) return;
          print("🌐 [SR Swap] Active coordinate bounds mutated!");
          print(
              "   👉 WKID: ${_sceneViewController?.spatialReference?.wkid}");
        }),
      );
    } finally {
      _isBinding = false;
    }
  }

  /// Queries the portal for MSPK items tagged with [_mspkSearchTag].
  /// Returns empty list on failure or no results.
  Future<List<PortalItem>> _queryAvailableMspks() async {
    if (!_hasInternet) {
      print("📡 [PortalQuery] Skipped — no internet");
      return [];
    }
    if (_portalUriValue.isEmpty) {
      print("📡 [PortalQuery] Skipped — portal URI not configured");
      return [];
    }

    print("🔍 [PortalQuery] Searching for MSPKs tagged '$_mspkSearchTag'...");
    _safeSetState(() {
      _isQueryingPortal = true;
      _portalQueryError = null;
    });

    try {
      final portal = Portal(
        Uri.parse(_portalUriValue),
        connection: PortalConnection.authenticated,
      );
      await portal.load();

      // Build query: type=Mobile Scene Package AND tag matches
      final params = PortalQueryParameters(
        query: 'type:"Mobile Scene Package" AND tags:"$_mspkSearchTag"',
      );
      params.limit = 50;

      final result = await portal.findItems(parameters: params);
      final items = result.results;

      print("✅ [PortalQuery] Found ${items.length} MSPK item(s)");
      for (final item in items) {
        print("   📦 ${item.title} (id=${item.itemId})");
      }

      _safeSetState(() {
        _availableMspkItems = items;
        _isQueryingPortal = false;
      });

      return items;
    } catch (e) {
      print("❌ [PortalQuery] Failed: $e");
      _safeSetState(() {
        _isQueryingPortal = false;
        _portalQueryError = e.toString();
        _availableMspkItems = [];
      });
      return [];
    }
  }

  /// User picks an MSPK from the list. Downloads it (if needed) and triggers
  /// the pipeline to render it.
  Future<void> _selectMspkItem(PortalItem item) async {
    if (_isDisposed) return;
    print("👆 [User] Selected MSPK: ${item.title}");

    // ✅ Clear picker immediately — show loading spinner instead
    _safeSetState(() {
      _selectedMspkItem = item;
      _availableMspkItems = [];        // ← ADD THIS
      _isLoadingResourceMetadata = true; // ← ADD THIS
    });

    final docDir = await getApplicationDocumentsDirectory();
    final cachePath = '${docDir.path}/mspk_${item.itemId}.mspk';
    final cacheFile = File(cachePath);

    bool needsDownload = !await cacheFile.exists();
    if (!needsDownload) {
      final ageDays = DateTime.now()
          .difference(await cacheFile.lastModified())
          .inDays;
      needsDownload = ageDays >= 0;
    }

    if (needsDownload && _hasInternet) {
      // ✅ Extend transitioning timeout to cover download duration
      _markNativeTransitioning(maxDuration: const Duration(minutes: 5));
      try {
        await _downloadPortalItemToAotCache(item, cachePath);
      } catch (e) {
        print("❌ [Download] Failed: $e");
        _markNativeStable();
        _safeSetState(() => _isLoadingResourceMetadata = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Download failed: $e",
                  style: const TextStyle(color: Colors.black)),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      _markNativeStable();
    }

    if (_isDisposed) return;
    await _loadMspkFromPath(cachePath);
  }

  /// Loads an MSPK from a specific file path and commits it to the pipeline.
  Future<void> _loadMspkFromPath(String mspkPath) async {
    if (_isDisposed) return;
    final myGeneration = ++_pipelineGeneration;
    bool isCancelled() => _isDisposed || myGeneration != _pipelineGeneration;

    _cancelLayerSubscriptions();
    _safeSetState(() {
      _isLoadingResourceMetadata = true;
      _operationalLayers.clear();
      _elevationSources.clear();
      _layerVisibilityMap.clear();
      _elevationVisibilityMap.clear();
      floors.clear();
    });

    try {
      final localMspk = MobileScenePackage.withFileUri(Uri.file(mspkPath));
      await _loadWithTimeout(localMspk.load(), 'MobileScenePackage.load()');

      if (isCancelled()) return;
      if (localMspk.scenes.isEmpty) {
        throw Exception("MSPK contains no valid 3D scenes.");
      }

      final targetScene = localMspk.scenes.first;
      await _loadWithTimeout(targetScene.load(), 'Scene.load()');

      if (isCancelled()) return;

      _safeSetState(() {
        _activeMspk = localMspk;
        _configuredScene = targetScene;
        _operationalLayers = targetScene.operationalLayers.toList();

        for (var layer in _operationalLayers) {
          _layerVisibilityMap[layer.id] = false;
          layer.isVisible = false;

          _layerSubscriptions.add(
            layer.onLoadStatusChanged.listen((status) {
              if (isCancelled()) return;
              print("🔄 '${layer.name}' -> ${enumLabel(status)}");
            }),
          );
        }

        _elevationSources = targetScene.baseSurface.elevationSources.toList();
        for (var src in _elevationSources) {
          _elevationVisibilityMap[src.hashCode] = true;
        }
        _isLoadingResourceMetadata = false;
      });

      print("✅ [LoadMspk] Loaded ${targetScene.operationalLayers.length} layers");
    } catch (e, stack) {
      print("❌ [LoadMspk] Failed: $e");
      print(stack);
      _safeSetState(() => _isLoadingResourceMetadata = false);
    }
  }

  //floor separation
  void _showFloor(int floorNumber) {
    if (_isDisposed) return;
    if (_activeBuilding == null) return;

    final buildingPattern = RegExp(
        '^${RegExp.escape(_activeBuilding!)}'
        r'_(\d+)F$');

    if (floorNumber == 999) {
      for (final layer in _floorLayers) {
        layer.isVisible = true;
        layer.opacity = 1.0;
      }
      print("🏢 Showing all floors of '$_activeBuilding'");
      _safeSetState(() => _currentFloor = 999);
      return;
    }

    for (final layer in _floorLayers) {
      final match = buildingPattern.firstMatch(layer.name);
      final layerFloor = match != null ? int.parse(match.group(1)!) : -1;

      layer.isVisible = (layerFloor <= floorNumber);
      layer.opacity = (layerFloor < floorNumber) ? 0.1 : 1.0;

      print("🏗️ ${layer.name} -> ${layer.isVisible ? 'VISIBLE' : 'HIDDEN'} "
          "(opacity: ${layer.opacity})");
    }

    _safeSetState(() => _currentFloor = floorNumber);
  }

  void _detectBuildings() {
    _buildingNames.clear();

    for (final layer in _operationalLayers) {
      if (layer is GroupLayer) {
        final hasFloors = layer.layers.any((sub) {
          if (sub is ArcGISSceneLayer) {
            return RegExp(r'^.+_(\d+)F$').hasMatch(sub.name);
          }
          return false;
        });

        if (hasFloors) {
          _buildingNames.add(layer.name);
          print("🏢 [Building Detected] '${layer.name}'");
        }
      }
    }

    print("🏢 [Buildings] Found ${_buildingNames.length}: $_buildingNames");
  }

  Future<void> _updateActiveBuildingFromCamera() async {
    if (_isDisposed) return;
    if (_buildingNames.isEmpty) return;
    if (_sceneViewController == null) return;

    final viewpoint = _safeCall<Viewpoint?>(
      () => _sceneViewController?.getCurrentViewpoint(
        ViewpointType.centerAndScale,
      ),
      label: 'getCurrentViewpoint',
    );
    if (viewpoint == null) return;

    final cameraTarget = viewpoint.targetGeometry;
    ArcGISPoint? centerPoint;

    if (cameraTarget is ArcGISPoint) {
      centerPoint = cameraTarget;
    } else if (cameraTarget is Envelope) {
      centerPoint = cameraTarget.center;
    }
    if (centerPoint == null) return;

    print(
        "🎯 [Detection] Camera target: (${centerPoint.x.toStringAsFixed(2)}, "
        "${centerPoint.y.toStringAsFixed(2)})");

    String? bestBuilding;
    double bestScore = double.infinity;
    bool foundContaining = false;

    for (final layer in _operationalLayers) {
      if (layer is GroupLayer && _buildingNames.contains(layer.name)) {
        final extent = layer.fullExtent;
        if (extent == null) continue;

        final buildingCenter = extent.center;
        final dx = centerPoint.x - buildingCenter.x;
        final dy = centerPoint.y - buildingCenter.y;
        final dist = sqrt(dx * dx + dy * dy);

        print("   📏 '${layer.name}': "
            "center=(${buildingCenter.x.toStringAsFixed(2)}, "
            "${buildingCenter.y.toStringAsFixed(2)}) "
            "distance=${dist.toStringAsFixed(2)}m "
            "contains=${extent.containsPoint(centerPoint)}");

        if (extent.containsPoint(centerPoint)) {
          if (!foundContaining || dist < bestScore) {
            bestBuilding = layer.name;
            bestScore = dist;
            foundContaining = true;
          }
        } else if (!foundContaining && dist < bestScore) {
          bestBuilding = layer.name;
          bestScore = dist;
        }
      }
    }

    const double maxSwitchDistance = 500.0;
    if (!foundContaining && bestScore > maxSwitchDistance) {
      print(
          "🎯 [Detection] Best match '$bestBuilding' is ${bestScore.toStringAsFixed(0)}m away "
          "— too far to switch (threshold: ${maxSwitchDistance}m).");
      return;
    }

    if (bestBuilding != null && bestBuilding != _activeBuilding) {
      print("🏢 [Camera Switch] $_activeBuilding → $bestBuilding "
          "(${foundContaining ? 'INSIDE extent' : 'closest by ${bestScore.toStringAsFixed(0)}m'})");
      _activeBuilding = bestBuilding;
      _rebuildFloorList();
      _safeSetState(() {
        _currentFloor = 999;
      });
    }
  }

  void _rebuildFloorList() {
    floors.clear();

    print("🏢 [Rebuild] Building floor list for: '$_activeBuilding'");

    if (_activeBuilding == null) {
      _minFloor = 0;
      _maxFloor = 1;
      print("🏢 [Rebuild] No active building — cleared floors.");
      return;
    }

    for (final layer in _floorLayers) {
      final match = RegExp(r'^(.+)_(\d+)F$').firstMatch(layer.name);
      if (match != null && match.group(1) == _activeBuilding) {
        final floorNum = int.parse(match.group(2)!);
        if (!floors.contains(floorNum)) {
          floors.add(floorNum);
          print("   ➕ Floor $floorNum from '${layer.name}'");
        }
      }
    }

    floors.sort();
    if (floors.isNotEmpty) {
      _minFloor = floors.reduce(min);
      _maxFloor = floors.reduce(max);
    } else {
      _minFloor = 0;
      _maxFloor = 1;
    }

    print("🏢 [Rebuild] Building '$_activeBuilding' → floors=$floors "
        "(min=$_minFloor, max=$_maxFloor)");
  }

  void _cancelAllSceneSubscriptions() {
    _viewpointDebounceTimer?.cancel();
    _viewpointDebounceTimer = null;
    print(
        "🧹 [Cleanup] Cancelling ${_sceneSubscriptions.length} controller subscriptions.");
    for (final sub in _sceneSubscriptions) {
      try {
        sub.cancel();
      } catch (e) {
        print("⚠️ [Cleanup] Failed to cancel scene sub: $e");
      }
    }
    _sceneSubscriptions.clear();
  }

  void _cancelLayerSubscriptions() {
    print(
        "🧹 [Cleanup] Cancelling ${_layerSubscriptions.length} layer subscriptions.");
    for (final sub in _layerSubscriptions) {
      try {
        sub.cancel();
      } catch (e) {
        print("⚠️ [Cleanup] Failed to cancel layer sub: $e");
      }
    }
    _layerSubscriptions.clear();
  }

  void _scheduleInitialBuildingDetection() {
    final genBind = _bindGeneration;
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (_isDisposed) return;
      if (genBind != _bindGeneration) return;
      print(
          "🎯 [Initial] Running first building detection after camera settle.");
      _updateActiveBuildingFromCamera();
    });
  }

  /// Marks the native scene view as transitioning (disposing or building).
  /// All user interactions are blocked until [_markNativeStable] is called
  /// or until [maxDuration] elapses as a safety timeout.
  void _markNativeTransitioning({Duration maxDuration = const Duration(seconds: 10)}) {
    _stabilityTimer?.cancel();
    _safeSetState(() => _isNativeTransitioning = true);
    print("🔒 [Stability] Native transition started — UI locked");
    
    // Safety timeout in case stable callback never fires
    _stabilityTimer = Timer(maxDuration, () {
      if (_isDisposed) return;
      if (_isNativeTransitioning) {
        print("⏰ [Stability] Timeout — force-unlocking UI");
        _safeSetState(() => _isNativeTransitioning = false);
      }
    });
  }

  /// Marks the native scene view as stable. Re-enables UI interactions.
  void _markNativeStable() {
    _stabilityTimer?.cancel();
    if (!_isNativeTransitioning) return;
    _safeSetState(() => _isNativeTransitioning = false);
  print("🔓 [Stability] Native stable — UI unlocked");
}

  // ─────────────────────────────────────────────────────────────────────────
  // Camera application — post-bind
  // ─────────────────────────────────────────────────────────────────────────
  void _applyCamera() {
    if (_isDisposed) return;
    print("📍 [Camera] Resolving camera (post-bind refinement)...");

    if (_pendingViewpoint != null) {
      print("📍 [Camera] Applying pending viewpoint: "
          "${_pendingViewpoint!.targetGeometry}");
      _safeCall(
        () => _sceneViewController?.setViewpoint(_pendingViewpoint!),
        label: 'apply pending viewpoint',
      );
      _pendingViewpoint = null;
      _scheduleInitialBuildingDetection();
      return;
    }

    // Shaw camera already applied in _bindSceneToLiveController.
    _scheduleInitialBuildingDetection();
  }

  String enumLabel(Object? value) {
    if (value == null) return 'null';
    return value.toString().split('.').last;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isDisposed) return;
      _loadResourceStructure();
    });
  }


  @override
  void dispose() {
    // ✅ Set disposed FIRST, before cancelling anything,
    //    so any callback fired during cancel sees the flag.
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _cancelAllSceneSubscriptions();
    _cancelLayerSubscriptions();
    _viewpointDebounceTimer?.cancel();
    _viewpointDebounceTimer = null;
    _stabilityTimer?.cancel();  // ✅ ADD
    _stabilityTimer = null;
    // ❌ DO NOT touch _sceneViewController.arcGISScene here — let it GC naturally
    _sceneViewController = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print("📱 [Lifecycle] App state: ${state.name}");
    // Optionally re-check connectivity on resume
    if (state == AppLifecycleState.resumed && !_isDisposed) {
      checkInternet().then((v) {
        if (_isDisposed) return;
        _safeSetState(() => _hasInternet = v);
      });
    }
  }
}

class _LiveLayerDrawer extends StatefulWidget {
  final List<Layer> operationalLayers;
  final Map<String, bool> visibilityMap;
  final VoidCallback onChanged;
  final void Function(Layer) onFlyTo;

  const _LiveLayerDrawer({
    required this.operationalLayers,
    required this.visibilityMap,
    required this.onChanged,
    required this.onFlyTo,
  });

  @override
  State<_LiveLayerDrawer> createState() => _LiveLayerDrawerState();
}

class _LiveLayerDrawerState extends State<_LiveLayerDrawer> {
  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Live Layer Status",
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  )),
              const Divider(),
              Expanded(
                child: ListView(
                  children: widget.operationalLayers.map((layer) {
                    final name = layer.name.isEmpty ? "Unnamed" : layer.name;

                    // ✅ Read current visibility directly from the layer
                    final isVisible = layer.isVisible;

                    return CheckboxListTile(
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(name,
                          style: const TextStyle(color: Colors.black)),
                      subtitle: Text(
                        "Status: ${layer.loadStatus.toString().split('.').last}",
                        style: TextStyle(
                          color: layer.loadStatus == LoadStatus.loaded
                              ? Colors.green
                              : Colors.orange,
                        ),
                      ),
                      value: isVisible,
                      onChanged: (checked) {
                        final newValue = checked ?? false;

                        setState(() {
                          // Update both the map and the actual layer
                          widget.visibilityMap[layer.id] = newValue;
                          layer.isVisible = newValue;
                        });

                        widget.onChanged(); // notify parent if needed
                      },
                      secondary: IconButton(
                        icon: const Icon(Icons.gps_fixed, color: Colors.blue),
                        onPressed: () => widget.onFlyTo(layer),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}