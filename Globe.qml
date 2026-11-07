import QtQuick
import "RadioModel.js" as RadioModel

Item {
  id: root

  property var countries: []
  property var stations: []
  property var selectedStation: null
  readonly property string selectedStationUuid: selectedStation ? String(selectedStation.uuid || "") : ""
  readonly property real stationHitRadius: 12
  property string activeCountryCode: ""

  property real centreLatitude: 18
  property real centreLongitude: -20
  property real globeScale: 1
  property real minimumScale: 0.72
  property real maximumScale: 24
  readonly property bool canZoomIn: (zoomAnimation.running ? zoomAnimation.to : globeScale) < maximumScale - 0.001
  readonly property bool canZoomOut: (zoomAnimation.running ? zoomAnimation.to : globeScale) > minimumScale + 0.001
  property real longitudeSensitivity: 0.22
  property real latitudeSensitivity: 0.18
  readonly property real kineticLaunchSpeed: 120
  readonly property real kineticMaximumSpeed: 2400
  readonly property real kineticDeceleration: 1800
  readonly property real kineticMaximumFrameTime: 0.1
  readonly property real kineticMaximumSampleAge: 100

  property color backgroundColor: "#090a0c"
  property color sphereColor: "#11151a"
  property color landColor: "#283039"
  property color gridColor: "#7d8791"
  property color outlineColor: "#9099a3"
  property color signalColor: "#d9dee3"
  property color accentColor: "#ff8a3d"
  property color textColor: "#f3f4f5"
  property string fontFamily: "monospace"

  property var hoveredStation: null
  property real hoverX: 0
  property real hoverY: 0
  property var highlightedStation: null
  property real highlightX: 0
  property real highlightY: 0
  property real kineticVelocityX: 0
  property real kineticVelocityY: 0
  property int kineticLaunchGeneration: 0
  property bool suppressNextTap: false
  property var preparedCountries: []
  property var states: []
  property var preparedStates: []
  property bool showLabels: true
  // While the globe moves, draw coarser outlines and skip label layout;
  // one full-quality frame follows when the motion ends.
  readonly property bool interacting: dragHandler.active || kineticAnimation.running
    || zoomAnimation.running
  onInteractingChanged: globeCanvas.requestPaint()
  // States and provinces fade in from this zoom level; labels a bit later.
  property real stateScale: 3.2
  property real stateLabelScale: 3.6
  readonly property bool wantsStates: globeScale >= stateScale
  property var labelWidths: ({})
  property var labelEntries: []
  readonly property int labelPoolSize: 240
  readonly property int labelMetricSize: 12
  property var preparedGrid: []
  property var preparedStations: []
  property var sphereGradient: null
  property string sphereGradientKey: ""

  signal stationActivated(var station)
  signal countryActivated(string code, string name)
  signal interactionStarted()
  signal pointerMoved()

  Accessible.name: "Interactive world radio globe"
  Accessible.description: "Drag or flick to rotate, use the mouse wheel to zoom, and select a station signal or country"
  Accessible.role: Accessible.Pane

  function radius() {
    return Math.min(width, height) * 0.44 * globeScale
  }

  function withAlpha(color, alpha) {
    return Qt.rgba(color.r, color.g, color.b, alpha)
  }

  function clearLandingHighlight() {
    highlightedStation = null
    highlightX = 0
    highlightY = 0
  }

  function stopKineticRotation(clearLanding) {
    kineticLaunchGeneration += 1
    kineticAnimation.running = false
    kineticVelocityX = 0
    kineticVelocityY = 0
    if (clearLanding === true) clearLandingHighlight()
  }

  function startKineticRotation(velocityX, velocityY) {
    var launch = RadioModel.kineticLaunchVelocity(
      velocityX, velocityY, kineticLaunchSpeed, kineticMaximumSpeed)
    if (!launch.active) return false

    kineticLaunchGeneration += 1
    clearLandingHighlight()
    hoveredStation = null
    kineticVelocityX = launch.x
    kineticVelocityY = launch.y
    kineticAnimation.running = true
    return true
  }

  function finishKineticRotation() {
    kineticAnimation.running = false
    kineticVelocityX = 0
    kineticVelocityY = 0
    hoveredStation = null
    var excludedUuid = selectedStation ? selectedStation.uuid : ""
    highlightedStation = RadioModel.nearestVisibleStation(
      stations, centreLatitude, centreLongitude, excludedUuid,
      width, height, globeScale)
  }

  function rotateByPointerDelta(deltaX, deltaY) {
    centreLongitude = RadioModel.wrapLongitude(
      centreLongitude - deltaX * longitudeSensitivity / globeScale)
    centreLatitude = RadioModel.clamp(
      centreLatitude + deltaY * latitudeSensitivity / globeScale, -78, 78)
  }

  function stationByUuid(uuid) {
    var wanted = String(uuid || "")
    var rows = Array.isArray(stations) ? stations : []
    for (var i = 0; i < rows.length; i++)
      if (String(rows[i] && rows[i].uuid || "") === wanted) return rows[i]
    return null
  }

  function refreshLandingHighlight() {
    if (!highlightedStation) return
    var replacement = stationByUuid(highlightedStation.uuid)
    if (!replacement) {
      clearLandingHighlight()
      return
    }
    highlightedStation = replacement
    updateHighlightPosition()
  }

  function updateHighlightPosition() {
    if (!highlightedStation) return
    var position = RadioModel.stationPosition(
      highlightedStation, width, height, globeScale, centreLatitude, centreLongitude)
    if (!position) {
      clearLandingHighlight()
      return
    }
    highlightX = position.x
    highlightY = position.y
  }

  NumberAnimation {
    id: zoomAnimation
    target: root
    property: "globeScale"
    duration: 180
    easing.type: Easing.OutCubic
  }

  function stopZoomAnimation() {
    zoomAnimation.stop()
  }

  function zoomBy(factor) {
    interactionStarted()
    stopKineticRotation(true)
    suppressNextTap = false
    hoveredStation = null
    var currentTarget = zoomAnimation.running ? zoomAnimation.to : globeScale
    var targetScale = RadioModel.clamp(
      currentTarget * factor, minimumScale, maximumScale)
    zoomAnimation.stop()
    if (Math.abs(targetScale - globeScale) < 0.001) return
    zoomAnimation.from = globeScale
    zoomAnimation.to = targetScale
    zoomAnimation.start()
  }

  function zoomIn(factor) {
    zoomBy(factor || 1.5)
  }

  function zoomOut(factor) {
    zoomBy(1 / (factor || 1.5))
  }

  function focusCoordinate(latitude, longitude) {
    var nextLatitude = Number(latitude)
    var nextLongitude = Number(longitude)
    if (!isFinite(nextLatitude) || !isFinite(nextLongitude)) return

    stopKineticRotation(true)
    stopZoomAnimation()
    centreLatitude = RadioModel.clamp(nextLatitude, -78, 78)
    centreLongitude = RadioModel.wrapLongitude(nextLongitude)
  }

  function focusCountry(code) {
    var coordinate = RadioModel.countryCentre(countries, code)
    if (coordinate) focusCoordinate(coordinate.latitude, coordinate.longitude)
  }

  function prepareCoordinates(coordinates, latitudeFirst) {
    var output = []
    if (!Array.isArray(coordinates)) return output
    for (var i = 0; i < coordinates.length; i++) {
      var latitude = Number(coordinates[i][latitudeFirst ? 0 : 1]) * Math.PI / 180
      var longitude = Number(coordinates[i][latitudeFirst ? 1 : 0]) * Math.PI / 180
      if (!isFinite(latitude) || !isFinite(longitude)) continue
      var cosLatitude = Math.cos(latitude)
      output.push(
        cosLatitude * Math.cos(longitude),
        cosLatitude * Math.sin(longitude),
        Math.sin(latitude))
    }
    return output
  }

  // Keep only points at least `minimumDot`-apart (angular distance on the
  // unit sphere). Used for the coarse level of detail when zoomed out.
  function decimateRing(world, minimumDot) {
    var count = Math.floor(world.length / 3)
    if (count < 4) return world
    var output = [world[0], world[1], world[2]]
    var lastX = world[0], lastY = world[1], lastZ = world[2]
    for (var i = 1; i < count - 1; i++) {
      var offset = i * 3
      var dot = lastX * world[offset] + lastY * world[offset + 1] + lastZ * world[offset + 2]
      if (dot > minimumDot) continue
      lastX = world[offset]
      lastY = world[offset + 1]
      lastZ = world[offset + 2]
      output.push(lastX, lastY, lastZ)
    }
    var end = (count - 1) * 3
    output.push(world[end], world[end + 1], world[end + 2])
    return output
  }

  // Bounding cap (centre direction + angular radius) for fast culling.
  function ringCap(world) {
    var count = Math.floor(world.length / 3)
    var sumX = 0, sumY = 0, sumZ = 0
    for (var i = 0; i < count; i++) {
      sumX += world[i * 3]
      sumY += world[i * 3 + 1]
      sumZ += world[i * 3 + 2]
    }
    var length = Math.sqrt(sumX * sumX + sumY * sumY + sumZ * sumZ)
    if (length < 1e-9) return { x: 1, y: 0, z: 0, cosRadius: -1, sinRadius: 1, chord: 2 }
    sumX /= length
    sumY /= length
    sumZ /= length
    var minimumDot = 1
    for (var j = 0; j < count; j++) {
      var dot = sumX * world[j * 3] + sumY * world[j * 3 + 1] + sumZ * world[j * 3 + 2]
      if (dot < minimumDot) minimumDot = dot
    }
    return capFrom(sumX, sumY, sumZ, minimumDot)
  }

  function capFrom(x, y, z, cosRadius) {
    return {
      x: x, y: y, z: z,
      cosRadius: cosRadius,
      sinRadius: Math.sqrt(Math.max(0, 1 - cosRadius * cosRadius)),
      chord: Math.sqrt(Math.max(0, 2 - 2 * cosRadius))
    }
  }

  // Cap enclosing all ring caps of a feature.
  function featureCap(rings) {
    var sumX = 0, sumY = 0, sumZ = 0
    for (var i = 0; i < rings.length; i++) {
      var weight = 1 - rings[i].cap.cosRadius + 1e-6
      sumX += rings[i].cap.x * weight
      sumY += rings[i].cap.y * weight
      sumZ += rings[i].cap.z * weight
    }
    var length = Math.sqrt(sumX * sumX + sumY * sumY + sumZ * sumZ)
    if (length < 1e-9) return capFrom(1, 0, 0, -1)
    sumX /= length
    sumY /= length
    sumZ /= length
    var radius = 0
    for (var j = 0; j < rings.length; j++) {
      var cap = rings[j].cap
      var dot = RadioModel.clamp(sumX * cap.x + sumY * cap.y + sumZ * cap.z, -1, 1)
      radius = Math.max(radius, Math.acos(dot) + Math.acos(RadioModel.clamp(cap.cosRadius, -1, 1)))
    }
    return capFrom(sumX, sumY, sumZ, radius >= Math.PI ? -1 : Math.cos(radius))
  }

  function labelVector(properties, cap) {
    var latitude = Number(properties && properties.labelLatitude)
    var longitude = Number(properties && properties.labelLongitude)
    if (!isFinite(latitude) || !isFinite(longitude)) return { x: cap.x, y: cap.y, z: cap.z }
    latitude *= Math.PI / 180
    longitude *= Math.PI / 180
    return {
      x: Math.cos(latitude) * Math.cos(longitude),
      y: Math.cos(latitude) * Math.sin(longitude),
      z: Math.sin(latitude)
    }
  }

  // `tolerances` lists the decimation step (degrees) per level of detail,
  // coarsest first; the last level always holds the full geometry.
  function prepareFeatureGeometry(rows, tolerances, start, end, output) {
    output = output || []
    var minimumDots = []
    for (var t = 0; t < tolerances.length; t++)
      minimumDots.push(Math.cos(tolerances[t] * Math.PI / 180))
    rows = Array.isArray(rows) ? rows : []
    var first = Math.max(0, start || 0)
    var last = Math.min(rows.length, end === undefined ? rows.length : end)
    for (var i = first; i < last; i++) {
      var feature = rows[i]
      if (!feature || !feature.geometry) continue
      var geometry = feature.geometry
      var polygons = geometry.type === "Polygon" ? [geometry.coordinates] : geometry.coordinates
      if (!Array.isArray(polygons)) continue
      var rings = []
      var largest = null
      for (var p = 0; p < polygons.length; p++) {
        var ring = polygons[p] && polygons[p][0]
        var fine = prepareCoordinates(ring, false)
        if (fine.length < 9) continue
        var cap = ringCap(fine)
        var levels = []
        for (var l = 0; l < minimumDots.length; l++) {
          var reduced = decimateRing(fine, minimumDots[l])
          levels.push(reduced.length >= 12 && reduced.length < fine.length
            ? { world: reduced, projected: new Array(reduced.length), hidden: -1 } : null)
        }
        levels.push({ world: fine, projected: new Array(fine.length), hidden: -1 })
        var prepared = { cap: cap, levels: levels, culled: true }
        rings.push(prepared)
        if (!largest || cap.cosRadius < largest.cosRadius) largest = cap
      }
      if (rings.length === 0) continue
      var properties = feature.properties || {}
      output.push({
        code: String(properties.code || "").toUpperCase(),
        label: String(properties.label || properties.name || ""),
        rank: Number(properties.rank || 5),
        area: Number(properties.area || 0),
        labelAt: labelVector(properties, largest),
        extent: largest.chord,
        cap: featureCap(rings),
        rings: rings
      })
    }
    return output
  }

  function prepareCountryGeometry() {
    return prepareFeatureGeometry(countries, countryTolerances)
  }

  // Admin-1 data is large: prepare it in slices so the UI never stalls.
  property var pendingStates: []
  // Decimation steps (degrees) per level of detail, coarsest first.
  readonly property var countryTolerances: [1.1, 0.45, 0.12]
  readonly property var stateTolerances: [0.9, 0.3, 0.1]

  // Finest level whose decimation step stays below `pixels` on screen
  // (the last level is the full geometry).
  function levelFor(tolerances, view) {
    var pixelsPerDegree = view.radius * Math.PI / 180
    var target = interacting ? 7 : 2.6
    var level = 0
    while (level < tolerances.length && tolerances[level] * pixelsPerDegree > target) level++
    return level
  }
  property int pendingStateIndex: 0

  function prepareStateGeometry() {
    pendingStates = []
    pendingStateIndex = 0
    preparedStates = []
    stateTimer.running = Array.isArray(states) && states.length > 0
  }

  Timer {
    id: stateTimer
    interval: 1
    repeat: true
    onTriggered: {
      var rows = root.states
      var end = Math.min(rows.length, root.pendingStateIndex + 200)
      root.prepareFeatureGeometry(rows, root.stateTolerances, root.pendingStateIndex, end, root.pendingStates)
      root.pendingStateIndex = end
      if (end < rows.length) return
      running = false
      root.preparedStates = root.pendingStates
      root.pendingStates = []
      globeCanvas.requestPaint()
    }
  }

  function prepareGridGeometry() {
    var output = []
    for (var latitude = -60; latitude <= 60; latitude += 30) {
      var parallel = []
      for (var longitude = -180; longitude <= 180; longitude += 3)
        parallel.push([latitude, longitude])
      output.push(prepareCoordinates(parallel, true))
    }
    for (var meridian = -150; meridian <= 180; meridian += 30) {
      var line = []
      for (var lat = -90; lat <= 90; lat += 3) line.push([lat, meridian])
      output.push(prepareCoordinates(line, true))
    }
    return output
  }

  function prepareStationGeometry() {
    var output = []
    var rows = Array.isArray(stations) ? stations : []
    for (var i = 0; i < rows.length; i++) {
      var station = rows[i]
      if (!station || station.latitude === null || station.longitude === null) continue
      var latitude = Number(station.latitude) * Math.PI / 180
      var longitude = Number(station.longitude) * Math.PI / 180
      if (!isFinite(latitude) || !isFinite(longitude)) continue
      var cosLatitude = Math.cos(latitude)
      output.push({
        station: station,
        worldX: cosLatitude * Math.cos(longitude),
        worldY: cosLatitude * Math.sin(longitude),
        worldZ: Math.sin(latitude),
        visible: false,
        screenX: 0,
        screenY: 0,
        depth: -1
      })
    }
    return output
  }

  function paintCurve(ctx, coordinates, centreX, centreY, globeRadius,
                      sinLatitude, cosLatitude, sinLongitude, cosLongitude) {
    var drawing = false
    ctx.beginPath()
    for (var i = 0; i < coordinates.length; i += 3) {
      var horizontal = coordinates[i] * cosLongitude + coordinates[i + 1] * sinLongitude
      var xProjection = coordinates[i + 1] * cosLongitude - coordinates[i] * sinLongitude
      var yProjection = cosLatitude * coordinates[i + 2] - sinLatitude * horizontal
      var depth = sinLatitude * coordinates[i + 2] + cosLatitude * horizontal
      if (depth < 0) {
        drawing = false
        continue
      }
      var x = centreX + xProjection * globeRadius
      var y = centreY - yProjection * globeRadius
      if (!drawing) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
      drawing = true
    }
    ctx.stroke()
  }

  function paintGrid(ctx, centreX, centreY, globeRadius) {
    ctx.strokeStyle = withAlpha(gridColor, 0.18)
    ctx.lineWidth = Math.min(1.5, Math.max(0.7, globeRadius / 500))
    var latitude = centreLatitude * Math.PI / 180
    var longitude = centreLongitude * Math.PI / 180
    var sinLatitude = Math.sin(latitude)
    var cosLatitude = Math.cos(latitude)
    var sinLongitude = Math.sin(longitude)
    var cosLongitude = Math.cos(longitude)
    for (var i = 0; i < preparedGrid.length; i++)
      paintCurve(ctx, preparedGrid[i], centreX, centreY, globeRadius,
        sinLatitude, cosLatitude, sinLongitude, cosLongitude)
  }

  function viewState(centreX, centreY, globeRadius) {
    var latitude = centreLatitude * Math.PI / 180
    var longitude = centreLongitude * Math.PI / 180
    return {
      sinLatitude: Math.sin(latitude),
      cosLatitude: Math.cos(latitude),
      sinLongitude: Math.sin(longitude),
      cosLongitude: Math.cos(longitude),
      centreX: centreX,
      centreY: centreY,
      radius: globeRadius,
      // Squared pixel distance below which consecutive points are skipped.
      minimumStep: interacting ? 20 : 4,
      // Rings smaller than this (pixels across) are skipped.
      minimumRing: interacting ? 3 : 1.2,
      width: globeCanvas.width,
      height: globeCanvas.height
    }
  }

  // Project a unit vector; returns screen position and depth (>= 0 = front).
  function projectVector(x, y, z, view) {
    var horizontal = x * view.cosLongitude + y * view.sinLongitude
    var depth = view.sinLatitude * z + view.cosLatitude * horizontal
    return {
      x: view.centreX + (y * view.cosLongitude - x * view.sinLongitude) * view.radius,
      y: view.centreY - (view.cosLatitude * z - view.sinLatitude * horizontal) * view.radius,
      depth: depth
    }
  }

  function ringCulled(cap, view) {
    var horizontal = cap.x * view.cosLongitude + cap.y * view.sinLongitude
    var depth = view.sinLatitude * cap.z + view.cosLatitude * horizontal
    // Entirely behind the horizon: angle(view, centre) > 90° + radius.
    if (cap.cosRadius > 0 && depth < -cap.sinRadius) return true
    var extent = cap.chord * view.radius
    var x = view.centreX + (cap.y * view.cosLongitude - cap.x * view.sinLongitude) * view.radius
    if (x + extent < 0 || x - extent > view.width) return true
    var y = view.centreY - (view.cosLatitude * cap.z - view.sinLatitude * horizontal) * view.radius
    return y + extent < 0 || y - extent > view.height
  }

  function cullFeature(feature, view) {
    if (!ringCulled(feature.cap, view)) return false
    for (var r = 0; r < feature.rings.length; r++) feature.rings[r].culled = true
    return true
  }

  function projectLevel(level, view) {
    var ring = level.world
    var projected = level.projected
    var points = Math.floor(ring.length / 3)
    var hiddenIndex = -1
    var anyVisible = false
    var cosLongitude = view.cosLongitude, sinLongitude = view.sinLongitude
    var cosLatitude = view.cosLatitude, sinLatitude = view.sinLatitude
    for (var pointIndex = 0; pointIndex < points; pointIndex++) {
      var offset = pointIndex * 3
      var worldX = ring[offset], worldY = ring[offset + 1], worldZ = ring[offset + 2]
      var horizontal = worldX * cosLongitude + worldY * sinLongitude
      projected[offset] = worldY * cosLongitude - worldX * sinLongitude
      projected[offset + 1] = cosLatitude * worldZ - sinLatitude * horizontal
      projected[offset + 2] = sinLatitude * worldZ + cosLatitude * horizontal
      if (projected[offset + 2] < 0) {
        if (hiddenIndex < 0) hiddenIndex = pointIndex
      } else {
        anyVisible = true
      }
    }
    level.hidden = hiddenIndex
    return anyVisible
  }

  // Select the level of detail for a ring, cull it and project it.
  // Returns the projected level or null when nothing is visible.
  function prepareRing(ring, lod, view) {
    ring.culled = true
    if (ringCulled(ring.cap, view)) return null
    if (ring.cap.chord * view.radius < view.minimumRing) return null
    var level = null
    for (var l = lod; !level && l < ring.levels.length; l++) level = ring.levels[l]
    if (!projectLevel(level, view)) return null
    ring.culled = false
    ring.current = level
    return level
  }

  // Adds the visible part of a ring to the current path; closes it along the
  // horizon so partially visible land fills correctly.
  function traceFill(ctx, level, view) {
    var projected = level.projected
    var points = Math.floor(projected.length / 3)
    var centreX = view.centreX, centreY = view.centreY, globeRadius = view.radius
    var minimumStep = view.minimumStep
    var lastX = 0, lastY = 0
    if (level.hidden < 0) {
      for (var visibleIndex = 0; visibleIndex < points; visibleIndex++) {
        var screenX = centreX + projected[visibleIndex * 3] * globeRadius
        var screenY = centreY - projected[visibleIndex * 3 + 1] * globeRadius
        if (visibleIndex === 0) {
          ctx.moveTo(screenX, screenY)
        } else {
          var stepX = screenX - lastX, stepY = screenY - lastY
          if (stepX * stepX + stepY * stepY < minimumStep && visibleIndex < points - 1) continue
          ctx.lineTo(screenX, screenY)
        }
        lastX = screenX
        lastY = screenY
      }
      ctx.closePath()
      return
    }

    var previousOffset = level.hidden * 3
    var previousX = projected[previousOffset]
    var previousY = projected[previousOffset + 1]
    var previousDepth = projected[previousOffset + 2]
    var drawing = false
    var startAngle = 0
    for (var step = 1; step <= points; step++) {
      var currentOffset = ((level.hidden + step) % points) * 3
      var currentX = projected[currentOffset]
      var currentY = projected[currentOffset + 1]
      var currentDepth = projected[currentOffset + 2]
      var previousVisible = previousDepth >= 0
      var currentVisible = currentDepth >= 0
      if (!previousVisible && currentVisible) {
        var enteringRatio = previousDepth / (previousDepth - currentDepth)
        var enteringX = previousX + (currentX - previousX) * enteringRatio
        var enteringY = previousY + (currentY - previousY) * enteringRatio
        var enteringLength = Math.sqrt(enteringX * enteringX + enteringY * enteringY) || 1
        enteringX /= enteringLength
        enteringY /= enteringLength
        startAngle = Math.atan2(-enteringY, enteringX)
        ctx.moveTo(centreX + enteringX * globeRadius, centreY - enteringY * globeRadius)
        lastX = centreX + currentX * globeRadius
        lastY = centreY - currentY * globeRadius
        ctx.lineTo(lastX, lastY)
        drawing = true
      } else if (previousVisible && currentVisible && drawing) {
        var runX = centreX + currentX * globeRadius, runY = centreY - currentY * globeRadius
        var runStepX = runX - lastX, runStepY = runY - lastY
        if (runStepX * runStepX + runStepY * runStepY >= minimumStep) {
          ctx.lineTo(runX, runY)
          lastX = runX
          lastY = runY
        }
      } else if (previousVisible && !currentVisible && drawing) {
        var leavingRatio = previousDepth / (previousDepth - currentDepth)
        var leavingX = previousX + (currentX - previousX) * leavingRatio
        var leavingY = previousY + (currentY - previousY) * leavingRatio
        var leavingLength = Math.sqrt(leavingX * leavingX + leavingY * leavingY) || 1
        leavingX /= leavingLength
        leavingY /= leavingLength
        var endAngle = Math.atan2(-leavingY, leavingX)
        var clockwiseArc = (startAngle - endAngle + Math.PI * 2) % (Math.PI * 2)
        ctx.lineTo(centreX + leavingX * globeRadius, centreY - leavingY * globeRadius)
        ctx.arc(centreX, centreY, globeRadius, endAngle, startAngle, clockwiseArc > Math.PI)
        ctx.closePath()
        drawing = false
      }
      previousX = currentX
      previousY = currentY
      previousDepth = currentDepth
    }
  }

  // Adds only the visible border segments of a ring to the current path.
  function traceOutline(ctx, level, view) {
    var projected = level.projected
    var points = Math.floor(projected.length / 3)
    var centreX = view.centreX, centreY = view.centreY, globeRadius = view.radius
    var minimumStep = view.minimumStep
    var drawing = false
    var lastX = 0, lastY = 0
    for (var i = 0; i < points; i++) {
      var offset = i * 3
      if (projected[offset + 2] < 0) {
        drawing = false
        continue
      }
      var x = centreX + projected[offset] * globeRadius
      var y = centreY - projected[offset + 1] * globeRadius
      if (!drawing) {
        ctx.moveTo(x, y)
      } else {
        var stepX = x - lastX, stepY = y - lastY
        if (stepX * stepX + stepY * stepY < minimumStep && i < points - 1
            && projected[offset + 5] >= 0) continue
        ctx.lineTo(x, y)
      }
      lastX = x
      lastY = y
      drawing = true
    }
    if (level.hidden < 0) ctx.closePath()
  }

  function borderWidth() {
    return RadioModel.clamp(0.9 + Math.log(Math.max(1, globeScale)) * 0.45, 0.9, 2.2)
  }

  function paintCountries(ctx, view) {
    var rows = preparedCountries
    var lod = levelFor(countryTolerances, view)
    var activeCode = activeCountryCode.toUpperCase()
    var active = null

    // One path per country: Qt's closePath() measures the whole current
    // path, so a single batched path gets quadratically slower.
    ctx.fillStyle = withAlpha(landColor, 0.92)
    for (var i = 0; i < rows.length; i++) {
      var country = rows[i]
      if (country.code === activeCode) active = country
      if (cullFeature(country, view)) continue
      var started = false
      for (var r = 0; r < country.rings.length; r++) {
        var level = prepareRing(country.rings[r], lod, view)
        if (!level || country === active) continue
        if (!started) ctx.beginPath()
        started = true
        traceFill(ctx, level, view)
      }
      if (started) ctx.fill()
    }

    if (active) {
      ctx.beginPath()
      for (var a = 0; a < active.rings.length; a++)
        if (!active.rings[a].culled) traceFill(ctx, active.rings[a].current, view)
      ctx.fillStyle = withAlpha(accentColor, 0.32)
      ctx.fill()
    }
  }

  function paintBorders(ctx, rows, view, color, alpha, width, skipCode) {
    // Thin bevelled strokes rasterize much faster while the globe moves.
    ctx.lineJoin = interacting ? "bevel" : "round"
    ctx.strokeStyle = withAlpha(color, alpha)
    ctx.lineWidth = interacting ? Math.min(width, 1.2) : width
    for (var i = 0; i < rows.length; i++) {
      var feature = rows[i]
      if (skipCode && feature.code === skipCode) continue
      var started = false
      for (var r = 0; r < feature.rings.length; r++) {
        var ring = feature.rings[r]
        if (ring.culled) continue
        if (!started) ctx.beginPath()
        started = true
        traceOutline(ctx, ring.current, view)
      }
      if (started) ctx.stroke()
    }
  }

  function paintStates(ctx, view) {
    if (!wantsStates || preparedStates.length === 0) return 0
    var fade = RadioModel.clamp((globeScale - stateScale) / (stateScale * 0.35), 0, 1)
    if (fade <= 0) return 0
    // State borders are detail for a resting globe; skip them in motion.
    if (interacting) return fade
    var lod = levelFor(stateTolerances, view)
    var rows = preparedStates
    for (var i = 0; i < rows.length; i++) {
      var state = rows[i]
      if (cullFeature(state, view)) continue
      for (var r = 0; r < state.rings.length; r++)
        prepareRing(state.rings[r], lod, view)
    }
    paintBorders(ctx, rows, view, outlineColor, 0.3 * fade,
      Math.max(0.55, borderWidth() * 0.45), "")
    return fade
  }

  function measureLabel(bold, text) {
    var cacheKey = (bold ? "b:" : "n:") + text
    var cached = labelWidths[cacheKey]
    if (cached !== undefined) return cached
    var width = (bold ? boldMetrics : regularMetrics).advanceWidth(text)
    labelWidths[cacheKey] = width
    return width
  }

  function overlaps(boxes, box) {
    for (var i = 0; i < boxes.length; i++) {
      var other = boxes[i]
      if (box.x0 < other.x1 && box.x1 > other.x0 && box.y0 < other.y1 && box.y1 > other.y0)
        return true
    }
    return false
  }

  function placeLabels(rows, view, options, boxes, output) {
    var candidates = []
    for (var i = 0; i < rows.length; i++) {
      var feature = rows[i]
      if (!feature.label) continue
      var visible = false
      for (var r = 0; r < feature.rings.length && !visible; r++)
        visible = !feature.rings[r].culled
      if (!visible) continue
      var active = options.activeCode !== "" && feature.code === options.activeCode
      var point = projectVector(feature.labelAt.x, feature.labelAt.y, feature.labelAt.z, view)
      if (point.depth < 0.18) continue
      if (point.x < 0 || point.x > view.width || point.y < 0 || point.y > view.height) continue
      var extent = feature.extent * view.radius
      if (!active && extent < options.minimumExtent) continue
      candidates.push({ feature: feature, point: point, extent: extent, active: active })
    }
    candidates.sort(function(first, second) {
      if (first.active !== second.active) return first.active ? -1 : 1
      return second.feature.area - first.feature.area
    })

    var size = options.size
    var placed = 0
    for (var c = 0; c < candidates.length && placed < options.maximum; c++) {
      var candidate = candidates[c]
      var bold = options.bold || candidate.active
      var text = options.upper ? candidate.feature.label.toUpperCase() : candidate.feature.label
      var textWidth = measureLabel(bold, text) * size / labelMetricSize
      if (!candidate.active && textWidth > candidate.extent * options.overflow) continue
      var box = {
        x0: candidate.point.x - textWidth / 2 - 3,
        x1: candidate.point.x + textWidth / 2 + 3,
        y0: candidate.point.y - size * 0.7,
        y1: candidate.point.y + size * 0.7
      }
      // Keep labels fully on screen and inside the globe's disc.
      if (box.x0 < 2 || box.x1 > view.width - 2 || box.y0 < 2 || box.y1 > view.height - 2) continue
      var farX = Math.max(Math.abs(box.x0 - view.centreX), Math.abs(box.x1 - view.centreX))
      var farY = Math.max(Math.abs(box.y0 - view.centreY), Math.abs(box.y1 - view.centreY))
      if (farX * farX + farY * farY > view.radius * view.radius * 0.97) continue
      if (overlaps(boxes, box)) continue
      boxes.push(box)
      placed += 1
      output.push({
        text: text,
        x: candidate.point.x,
        y: candidate.point.y,
        size: size,
        bold: bold,
        opacity: candidate.active ? 1 : options.alpha,
        active: candidate.active
      })
    }
  }

  function updateLabels(view, stateFade) {
    var output = []
    if (showLabels && view) {
      var boxes = []
      var zoom = Math.max(1, globeScale)
      var countrySize = Math.round(RadioModel.clamp(10 + Math.log(zoom) * 1.6, 10, 15))
      placeLabels(preparedCountries, view, {
        activeCode: activeCountryCode.toUpperCase(),
        size: countrySize,
        bold: true,
        upper: true,
        alpha: 0.9,
        overflow: 1.5,
        minimumExtent: 14,
        maximum: 140
      }, boxes, output)
      if (stateFade > 0 && globeScale >= stateLabelScale) {
        placeLabels(preparedStates, view, {
          activeCode: "",
          size: Math.round(RadioModel.clamp(countrySize - 1.5, 9, 13)),
          bold: false,
          upper: false,
          alpha: 0.68 * stateFade,
          overflow: 1.25,
          minimumExtent: 36,
          maximum: labelPoolSize - output.length
        }, boxes, output)
      }
    }
    labelEntries = output
  }

  function paintSignals(ctx) {
    var rows = preparedStations
    var latitude = centreLatitude * Math.PI / 180
    var longitude = centreLongitude * Math.PI / 180
    var sinLatitude = Math.sin(latitude)
    var cosLatitude = Math.cos(latitude)
    var sinLongitude = Math.sin(longitude)
    var cosLongitude = Math.cos(longitude)
    var globeRadius = radius()
    // Read QML properties and convert colors once, not for every station.
    var canvasWidth = globeCanvas.width
    var canvasHeight = globeCanvas.height
    var centreX = canvasWidth / 2
    var centreY = canvasHeight / 2
    var hitRadius = stationHitRadius
    var selection = selectedStation
    var highlight = highlightedStation
    var markerColor = withAlpha(signalColor, 1)
    var activeColor = accentColor
    var selectedOutline = withAlpha(activeColor, 0.72)
    var highlightedOutline = withAlpha(activeColor, 0.92)
    ctx.fillStyle = markerColor
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var horizontal = row.worldX * cosLongitude + row.worldY * sinLongitude
      var xProjection = row.worldY * cosLongitude - row.worldX * sinLongitude
      var yProjection = cosLatitude * row.worldZ - sinLatitude * horizontal
      var depth = sinLatitude * row.worldZ + cosLatitude * horizontal
      row.visible = depth >= 0
      if (!row.visible) continue
      row.screenX = centreX + xProjection * globeRadius
      row.screenY = centreY - yProjection * globeRadius
      row.depth = depth
      row.visible = row.screenX >= -hitRadius
        && row.screenX <= canvasWidth + hitRadius
        && row.screenY >= -hitRadius
        && row.screenY <= canvasHeight + hitRadius
      if (!row.visible) continue

      var selected = selection && row.station.uuid === selection.uuid
      var highlighted = highlight && row.station.uuid === highlight.uuid && !selected
      var markerRadius = selected ? 4.2 : (highlighted ? 3.7 : 1.7 + depth * 1.25)
      ctx.beginPath()
      ctx.arc(row.screenX, row.screenY, markerRadius, 0, Math.PI * 2)
      if (selected || highlighted) ctx.fillStyle = activeColor
      ctx.globalAlpha = selected || highlighted ? 1 : 0.42 + depth * 0.48
      ctx.fill()

      if (selected || highlighted) {
        ctx.globalAlpha = 1
        ctx.beginPath()
        ctx.arc(row.screenX, row.screenY, selected ? 8.5 : 7.5, 0, Math.PI * 2)
        ctx.strokeStyle = selected ? selectedOutline : highlightedOutline
        ctx.lineWidth = selected ? 1.2 : 1.4
        ctx.stroke()
        ctx.fillStyle = markerColor
      }
    }
    ctx.globalAlpha = 1
  }

  function paintGlobe(ctx) {
    var centreX = globeCanvas.width / 2
    var centreY = globeCanvas.height / 2
    var globeRadius = radius()
    if (!isFinite(globeRadius) || globeRadius <= 0) return

    ctx.reset()
    ctx.fillStyle = backgroundColor
    ctx.fillRect(0, 0, globeCanvas.width, globeCanvas.height)

    // Rebuild the sphere gradient only when its geometry or colour changes.
    var gradientKey = centreX + "," + centreY + "," + globeRadius + "," + sphereColor
    if (!sphereGradient || sphereGradientKey !== gradientKey) {
      sphereGradient = ctx.createRadialGradient(
        centreX - globeRadius * 0.28, centreY - globeRadius * 0.32, globeRadius * 0.04,
        centreX, centreY, globeRadius)
      sphereGradient.addColorStop(0, withAlpha(Qt.lighter(sphereColor, 1.7), 1))
      sphereGradient.addColorStop(0.62, sphereColor)
      sphereGradient.addColorStop(1, Qt.darker(sphereColor, 1.8))
      sphereGradientKey = gradientKey
    }
    var sphere = sphereGradient
    ctx.beginPath()
    ctx.arc(centreX, centreY, globeRadius, 0, Math.PI * 2)
    ctx.fillStyle = sphere
    ctx.fill()

    ctx.save()
    ctx.beginPath()
    ctx.arc(centreX, centreY, globeRadius - 0.5, 0, Math.PI * 2)
    ctx.clip()
    var view = viewState(centreX, centreY, globeRadius)
    paintGrid(ctx, centreX, centreY, globeRadius)
    paintCountries(ctx, view)
    var stateFade = paintStates(ctx, view)
    var activeCode = activeCountryCode.toUpperCase()
    paintBorders(ctx, preparedCountries, view, outlineColor, 0.95, borderWidth(), activeCode)
    if (activeCode) {
      var activeRows = []
      for (var i = 0; i < preparedCountries.length; i++)
        if (preparedCountries[i].code === activeCode) activeRows.push(preparedCountries[i])
      paintBorders(ctx, activeRows, view, accentColor, 0.95, borderWidth() + 0.6, "")
    }
    paintSignals(ctx)
    if (!interacting) updateLabels(view, stateFade)
    ctx.restore()

    ctx.beginPath()
    ctx.arc(centreX, centreY, globeRadius, 0, Math.PI * 2)
    ctx.strokeStyle = withAlpha(outlineColor, 0.52)
    ctx.lineWidth = 1.1
    ctx.stroke()
  }

  function stationUnderPointer(x, y) {
    var nearest = null
    var nearestDistance = stationHitRadius * stationHitRadius
    var rows = preparedStations
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!row.visible) continue
      var deltaX = row.screenX - x
      var deltaY = row.screenY - y
      var distance = deltaX * deltaX + deltaY * deltaY
      if (distance > nearestDistance) continue
      nearest = row.station
      nearestDistance = distance
    }
    return nearest
  }

  function activateAt(x, y) {
    clearLandingHighlight()
    var station = stationUnderPointer(x, y)
    if (station) {
      stationActivated(station)
      return
    }

    var globeRadius = radius()
    var normalizedX = (x - width / 2) / globeRadius
    var normalizedY = -(y - height / 2) / globeRadius
    var coordinate = RadioModel.unproject(
      normalizedX, normalizedY, centreLatitude, centreLongitude)
    if (!coordinate) return
    var country = RadioModel.countryAt(
      countries, coordinate.latitude, coordinate.longitude)
    if (!country || !country.code || country.code === "-99") return
    countryActivated(String(country.code).toUpperCase(), String(country.name || country.code))
  }

  onCountriesChanged: {
    preparedCountries = prepareCountryGeometry()
    globeCanvas.requestPaint()
    if (activeCountryCode) focusCountry(activeCountryCode)
  }
  onStatesChanged: prepareStateGeometry()
  onFontFamilyChanged: {
    labelWidths = ({})
    globeCanvas.requestPaint()
  }
  onShowLabelsChanged: {
    if (!showLabels) labelEntries = []
    globeCanvas.requestPaint()
  }
  onTextColorChanged: globeCanvas.requestPaint()
  onStationsChanged: {
    preparedStations = prepareStationGeometry()
    refreshLandingHighlight()
    globeCanvas.requestPaint()
  }
  onSelectedStationUuidChanged: {
    clearLandingHighlight()
    globeCanvas.requestPaint()
  }
  onActiveCountryCodeChanged: globeCanvas.requestPaint()
  onBackgroundColorChanged: globeCanvas.requestPaint()
  onSphereColorChanged: globeCanvas.requestPaint()
  onLandColorChanged: globeCanvas.requestPaint()
  onGridColorChanged: globeCanvas.requestPaint()
  onOutlineColorChanged: globeCanvas.requestPaint()
  onSignalColorChanged: globeCanvas.requestPaint()
  onAccentColorChanged: globeCanvas.requestPaint()
  onCentreLatitudeChanged: {
    updateHighlightPosition()
    globeCanvas.requestPaint()
  }
  onCentreLongitudeChanged: {
    updateHighlightPosition()
    globeCanvas.requestPaint()
  }
  onGlobeScaleChanged: {
    updateHighlightPosition()
    globeCanvas.requestPaint()
  }
  onWidthChanged: {
    updateHighlightPosition()
    globeCanvas.requestPaint()
  }
  onHeightChanged: {
    updateHighlightPosition()
    globeCanvas.requestPaint()
  }
  onHighlightedStationChanged: {
    updateHighlightPosition()
    globeCanvas.requestPaint()
  }
  onVisibleChanged: {
    if (!visible) {
      stopKineticRotation(true)
      stopZoomAnimation()
    }
  }

  Canvas {
    id: globeCanvas
    anchors.fill: parent
    renderStrategy: Canvas.Cooperative
    onPaint: {
      var ctx = getContext("2d")
      if (!ctx) return
      root.paintGlobe(ctx)
      if (hoverHandler.hovered && !tapHandler.pressed
          && !dragHandler.active && !kineticAnimation.running)
        root.hoveredStation = root.stationUnderPointer(root.hoverX, root.hoverY)
    }
  }

  FontMetrics {
    id: boldMetrics
    font.family: root.fontFamily
    font.pixelSize: root.labelMetricSize
    font.bold: true
    font.letterSpacing: 0.6
  }

  FontMetrics {
    id: regularMetrics
    font.family: root.fontFamily
    font.pixelSize: root.labelMetricSize
  }

  // Map labels live in the scene graph: much cheaper than Canvas text.
  Item {
    id: labelLayer
    anchors.fill: parent
    visible: root.showLabels && !root.interacting

    Repeater {
      model: root.labelPoolSize

      Text {
        required property int index
        readonly property var entry: index < root.labelEntries.length ? root.labelEntries[index] : null
        visible: entry !== null
        x: entry ? Math.round(entry.x - implicitWidth / 2) : 0
        y: entry ? Math.round(entry.y - implicitHeight / 2) : 0
        text: entry ? entry.text : ""
        textFormat: Text.PlainText
        color: entry && entry.active ? root.accentColor : root.textColor
        opacity: entry ? entry.opacity : 0
        font.family: root.fontFamily
        font.pixelSize: entry ? entry.size : root.labelMetricSize
        font.bold: entry ? entry.bold : false
        font.letterSpacing: entry && entry.bold ? 0.6 * entry.size / root.labelMetricSize : 0
        style: Text.Outline
        styleColor: root.withAlpha(root.backgroundColor, 0.85)
      }
    }
  }

  Component.onCompleted: {
    preparedGrid = prepareGridGeometry()
    preparedCountries = prepareCountryGeometry()
    preparedStations = prepareStationGeometry()
    globeCanvas.requestPaint()
  }

  HoverHandler {
    id: hoverHandler
    cursorShape: dragHandler.active || tapHandler.pressed
      ? Qt.ClosedHandCursor
      : (root.hoveredStation ? Qt.PointingHandCursor : Qt.OpenHandCursor)

    onPointChanged: {
      root.hoverX = point.position.x
      root.hoverY = point.position.y
      root.pointerMoved()
      root.hoveredStation = kineticAnimation.running || dragHandler.active
        ? null : root.stationUnderPointer(point.position.x, point.position.y)
    }

    onHoveredChanged: {
      if (!hovered) root.hoveredStation = null
    }
  }

  TapHandler {
    id: tapHandler
    acceptedButtons: Qt.LeftButton
    gesturePolicy: TapHandler.DragThreshold

    onPressedChanged: {
      if (!pressed) return
      root.interactionStarted()
      var caughtKineticRotation = kineticAnimation.running
      root.stopKineticRotation(true)
      root.stopZoomAnimation()
      root.suppressNextTap = caughtKineticRotation
      root.hoveredStation = null
    }

    onTapped: function(eventPoint) {
      if (root.suppressNextTap) {
        root.suppressNextTap = false
        return
      }
      root.activateAt(eventPoint.position.x, eventPoint.position.y)
      root.hoveredStation = hoverHandler.hovered
        ? root.stationUnderPointer(eventPoint.position.x, eventPoint.position.y) : null
    }

    onCanceled: root.suppressNextTap = false
  }

  DragHandler {
    id: dragHandler
    target: null
    acceptedButtons: Qt.LeftButton

    property bool wasActive: false
    property bool launchCanceled: false
    property bool launchPending: false
    property int pendingLaunchGeneration: 0
    property real pendingVelocityX: 0
    property real pendingVelocityY: 0
    property real recentVelocityX: 0
    property real recentVelocityY: 0
    property real recentVelocityAt: 0
    property real samplePositionX: 0
    property real samplePositionY: 0
    property real sampleStartedAt: 0

    function resetMotionSample() {
      recentVelocityX = 0
      recentVelocityY = 0
      recentVelocityAt = 0
      samplePositionX = centroid.position.x
      samplePositionY = centroid.position.y
      sampleStartedAt = Date.now()
    }

    function recordMotionSample() {
      // Qt's filtered mouse velocity can fall below the launch floor before
      // release. Keep a short, capped-by-launch recent sample for human-speed
      // flicks; the coast itself still uses frame-time-independent physics.
      var now = Date.now()
      var elapsedMilliseconds = now - sampleStartedAt
      if (elapsedMilliseconds <= 0) return

      var deltaX = centroid.position.x - samplePositionX
      var deltaY = centroid.position.y - samplePositionY
      samplePositionX = centroid.position.x
      samplePositionY = centroid.position.y
      sampleStartedAt = now
      if (elapsedMilliseconds > 250) return

      var sampledVelocityX = deltaX * 1000 / elapsedMilliseconds
      var sampledVelocityY = deltaY * 1000 / elapsedMilliseconds
      if (!isFinite(sampledVelocityX) || !isFinite(sampledVelocityY)) return
      if (recentVelocityAt > 0) {
        recentVelocityX = recentVelocityX * 0.25 + sampledVelocityX * 0.75
        recentVelocityY = recentVelocityY * 0.25 + sampledVelocityY * 0.75
      } else {
        recentVelocityX = sampledVelocityX
        recentVelocityY = sampledVelocityY
      }
      recentVelocityAt = now
    }

    onActiveChanged: {
      if (active) {
        root.stopKineticRotation(true)
        root.stopZoomAnimation()
        wasActive = true
        launchCanceled = false
        launchPending = false
        root.suppressNextTap = false
        root.interactionStarted()
        root.hoveredStation = null
        resetMotionSample()
        return
      }
      if (!wasActive) return

      wasActive = false
      var releaseVelocity = RadioModel.kineticReleaseVelocity(
        centroid.velocity.x, centroid.velocity.y,
        recentVelocityX, recentVelocityY,
        recentVelocityAt > 0 ? Date.now() - recentVelocityAt : Infinity,
        root.kineticMaximumSampleAge)
      pendingVelocityX = releaseVelocity.x
      pendingVelocityY = releaseVelocity.y
      pendingLaunchGeneration = root.kineticLaunchGeneration
      launchPending = !launchCanceled
      Qt.callLater(function() {
        if (!dragHandler.launchPending || dragHandler.launchCanceled) return
        if (dragHandler.pendingLaunchGeneration !== root.kineticLaunchGeneration) {
          dragHandler.launchPending = false
          return
        }
        dragHandler.launchPending = false
        root.startKineticRotation(
          dragHandler.pendingVelocityX, dragHandler.pendingVelocityY)
      })
    }

    onTranslationChanged: function(delta) {
      if (!active) return
      recordMotionSample()
      root.rotateByPointerDelta(delta.x, delta.y)
    }

    onCanceled: {
      launchCanceled = true
      launchPending = false
      recentVelocityAt = 0
      root.stopKineticRotation(false)
    }
  }

  WheelHandler {
    id: wheelHandler
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    blocking: true

    onWheel: function(event) {
      root.interactionStarted()
      root.stopKineticRotation(true)
      root.stopZoomAnimation()
      root.suppressNextTap = false
      root.hoveredStation = null
      var factor = Math.exp(event.angleDelta.y / 720)
      root.globeScale = RadioModel.clamp(
        root.globeScale * factor, root.minimumScale, root.maximumScale)
      event.accepted = true
    }
  }

  FrameAnimation {
    id: kineticAnimation
    running: false

    onTriggered: {
      if (frameTime > root.kineticMaximumFrameTime) {
        root.stopKineticRotation(true)
        return
      }
      if (frameTime <= 0) return

      var step = RadioModel.advanceKineticRotation({
        longitude: root.centreLongitude,
        latitude: root.centreLatitude,
        velocityX: root.kineticVelocityX,
        velocityY: root.kineticVelocityY
      }, frameTime, {
        deceleration: root.kineticDeceleration,
        scale: root.globeScale,
        longitudeSensitivity: root.longitudeSensitivity,
        latitudeSensitivity: root.latitudeSensitivity,
        minimumLatitude: -78,
        maximumLatitude: 78
      })
      root.kineticVelocityX = step.velocityX
      root.kineticVelocityY = step.velocityY
      root.centreLongitude = step.longitude
      root.centreLatitude = step.latitude
      if (!step.active) root.finishKineticRotation()
    }
  }

  Rectangle {
    id: tooltip
    property var station: root.hoveredStation || root.highlightedStation
    property bool landing: !root.hoveredStation && !!root.highlightedStation
    property real anchorX: root.hoveredStation ? root.hoverX : root.highlightX
    property real anchorY: root.hoveredStation ? root.hoverY : root.highlightY

    visible: !!station && !tapHandler.pressed && !dragHandler.active
      && !kineticAnimation.running
    x: Math.min(root.width - width - 8, Math.max(8, anchorX + 14))
    y: Math.min(root.height - height - 8, Math.max(8, anchorY + 14))
    width: landing
      ? Math.min(280, Math.max(0, root.width - 16))
      : Math.min(280, Math.max(0, root.width - 16), tooltipText.implicitWidth + 20)
    height: tooltipContent.implicitHeight + 14
    color: Qt.rgba(root.backgroundColor.r, root.backgroundColor.g, root.backgroundColor.b, 0.94)
    border.color: root.withAlpha(root.outlineColor, 0.5)
    border.width: 1
    radius: 2

    Column {
      id: tooltipContent
      anchors.centerIn: parent
      width: Math.max(0, parent.width - 20)
      spacing: 2

      Text {
        id: tooltipText
        width: parent.width
        text: tooltip.station
          ? (tooltip.landing ? "Landed near · " : "") + tooltip.station.name
            + (!tooltip.landing && tooltip.station.estimatedLocation === true
              ? " · approximate location" : "")
          : ""
        textFormat: Text.PlainText
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: 12
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: tooltip.landing && tooltip.station
          && tooltip.station.estimatedLocation === true
        text: "approximate location"
        textFormat: Text.PlainText
        color: root.withAlpha(root.textColor, 0.66)
        font.family: root.fontFamily
        font.pixelSize: 11
      }
    }
  }
}
