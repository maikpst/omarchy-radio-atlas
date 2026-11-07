var radians = Math.PI / 180
var degrees = 180 / Math.PI
var estimatedLocationCache = ({})
var estimatedRegionCache = ({})
var estimatedFeatures = null
var maximumSelectionBytes = 4194304

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value))
}

function wrapLongitude(value) {
  var wrapped = (value + 180) % 360
  if (wrapped < 0) wrapped += 360
  return wrapped - 180
}

function limitKineticVelocity(x, y, maximumSpeed) {
  var velocityX = Number(x)
  var velocityY = Number(y)
  var limit = Number(maximumSpeed)
  if (!isFinite(velocityX) || !isFinite(velocityY) || !isFinite(limit) || limit <= 0)
    return { x: 0, y: 0, speed: 0 }

  var speed = Math.sqrt(velocityX * velocityX + velocityY * velocityY)
  if (!isFinite(speed) || speed <= 0) return { x: 0, y: 0, speed: 0 }
  if (speed <= limit) return { x: velocityX, y: velocityY, speed: speed }

  var ratio = limit / speed
  return { x: velocityX * ratio, y: velocityY * ratio, speed: limit }
}

function kineticLaunchVelocity(x, y, minimumSpeed, maximumSpeed) {
  var limited = limitKineticVelocity(x, y, maximumSpeed)
  var threshold = Math.max(0, Number(minimumSpeed) || 0)
  return {
    x: limited.speed >= threshold ? limited.x : 0,
    y: limited.speed >= threshold ? limited.y : 0,
    active: limited.speed >= threshold
  }
}

function kineticReleaseVelocity(nativeX, nativeY, sampledX, sampledY,
                                sampleAgeMilliseconds, maximumSampleAgeMilliseconds) {
  var nativeVelocityX = Number(nativeX)
  var nativeVelocityY = Number(nativeY)
  var sampledVelocityX = Number(sampledX)
  var sampledVelocityY = Number(sampledY)
  if (!isFinite(nativeVelocityX)) nativeVelocityX = 0
  if (!isFinite(nativeVelocityY)) nativeVelocityY = 0
  if (!isFinite(sampledVelocityX)) sampledVelocityX = 0
  if (!isFinite(sampledVelocityY)) sampledVelocityY = 0

  var nativeSpeed = Math.sqrt(
    nativeVelocityX * nativeVelocityX + nativeVelocityY * nativeVelocityY)
  var sampledSpeed = Math.sqrt(
    sampledVelocityX * sampledVelocityX + sampledVelocityY * sampledVelocityY)
  var sampleAge = Number(sampleAgeMilliseconds)
  var maximumSampleAge = Math.max(0, Number(maximumSampleAgeMilliseconds) || 0)
  var sampleIsFresh = isFinite(sampleAge) && sampleAge >= 0
    && sampleAge <= maximumSampleAge
  var sampleIsAligned = nativeSpeed === 0
    || nativeVelocityX * sampledVelocityX + nativeVelocityY * sampledVelocityY > 0
  if (sampleIsFresh && sampledSpeed > nativeSpeed && sampleIsAligned) {
    return { x: sampledVelocityX, y: sampledVelocityY }
  }
  return { x: nativeVelocityX, y: nativeVelocityY }
}

function advanceKineticRotation(state, elapsedSeconds, options) {
  var current = state || ({})
  var config = options || ({})
  var longitude = Number(current.longitude)
  var latitude = Number(current.latitude)
  var velocityX = Number(current.velocityX)
  var velocityY = Number(current.velocityY)
  var elapsed = Number(elapsedSeconds)
  if (!isFinite(longitude)) longitude = 0
  if (!isFinite(latitude)) latitude = 0
  if (!isFinite(velocityX)) velocityX = 0
  if (!isFinite(velocityY)) velocityY = 0

  var speed = Math.sqrt(velocityX * velocityX + velocityY * velocityY)
  if (!isFinite(speed) || speed <= 0 || !isFinite(elapsed) || elapsed <= 0) {
    return {
      longitude: wrapLongitude(longitude),
      latitude: latitude,
      velocityX: velocityX,
      velocityY: velocityY,
      active: speed > 0
    }
  }

  var deceleration = Number(config.deceleration)
  if (!isFinite(deceleration) || deceleration < 0) deceleration = 0
  var activeTime = deceleration > 0 ? Math.min(elapsed, speed / deceleration) : elapsed
  var nextSpeed = Math.max(0, speed - deceleration * activeTime)
  var distance = (speed + nextSpeed) * activeTime / 2
  var directionX = velocityX / speed
  var directionY = velocityY / speed
  var deltaX = directionX * distance
  var deltaY = directionY * distance

  var scale = Number(config.scale)
  if (!isFinite(scale) || scale <= 0) scale = 1
  var longitudeSensitivity = Number(config.longitudeSensitivity)
  var latitudeSensitivity = Number(config.latitudeSensitivity)
  if (!isFinite(longitudeSensitivity)) longitudeSensitivity = 0
  if (!isFinite(latitudeSensitivity)) latitudeSensitivity = 0
  var minimumLatitude = Number(config.minimumLatitude)
  var maximumLatitude = Number(config.maximumLatitude)
  if (!isFinite(minimumLatitude)) minimumLatitude = -78
  if (!isFinite(maximumLatitude)) maximumLatitude = 78

  var nextLongitude = wrapLongitude(longitude - deltaX * longitudeSensitivity / scale)
  var nextLatitude = clamp(
    latitude + deltaY * latitudeSensitivity / scale,
    minimumLatitude, maximumLatitude)
  var nextVelocityX = directionX * nextSpeed
  var nextVelocityY = directionY * nextSpeed
  if ((nextLatitude >= maximumLatitude && nextVelocityY > 0)
      || (nextLatitude <= minimumLatitude && nextVelocityY < 0))
    nextVelocityY = 0

  var remainingSpeed = Math.sqrt(
    nextVelocityX * nextVelocityX + nextVelocityY * nextVelocityY)
  return {
    longitude: nextLongitude,
    latitude: nextLatitude,
    velocityX: nextVelocityX,
    velocityY: nextVelocityY,
    active: remainingSpeed > 1e-9
  }
}

function project(latitude, longitude, centreLatitude, centreLongitude) {
  var phi = Number(latitude) * radians
  var lambda = wrapLongitude(Number(longitude) - Number(centreLongitude)) * radians
  var phi0 = Number(centreLatitude) * radians
  var cosPhi = Math.cos(phi)
  var sinPhi = Math.sin(phi)
  var cosPhi0 = Math.cos(phi0)
  var sinPhi0 = Math.sin(phi0)

  return {
    x: cosPhi * Math.sin(lambda),
    y: cosPhi0 * sinPhi - sinPhi0 * cosPhi * Math.cos(lambda),
    z: sinPhi0 * sinPhi + cosPhi0 * cosPhi * Math.cos(lambda)
  }
}

function unproject(x, y, centreLatitude, centreLongitude) {
  var rho2 = x * x + y * y
  if (rho2 > 1) return null

  var z = Math.sqrt(Math.max(0, 1 - rho2))
  var phi0 = Number(centreLatitude) * radians
  var cosPhi0 = Math.cos(phi0)
  var sinPhi0 = Math.sin(phi0)
  var latitude = Math.asin(y * cosPhi0 + z * sinPhi0)
  var longitude = Number(centreLongitude) * radians
    + Math.atan2(x, z * cosPhi0 - y * sinPhi0)

  return {
    latitude: latitude * degrees,
    longitude: wrapLongitude(longitude * degrees)
  }
}

function pointInRing(longitude, latitude, ring) {
  var inside = false
  if (!Array.isArray(ring) || ring.length < 3) return false

  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    var xi = Number(ring[i][0])
    var yi = Number(ring[i][1])
    var xj = Number(ring[j][0])
    var yj = Number(ring[j][1])
    var crosses = (yi > latitude) !== (yj > latitude)
      && longitude < (xj - xi) * (latitude - yi) / ((yj - yi) || 1e-12) + xi
    if (crosses) inside = !inside
  }
  return inside
}

function pointInPolygon(longitude, latitude, polygon) {
  if (!Array.isArray(polygon) || polygon.length === 0) return false
  if (!pointInRing(longitude, latitude, polygon[0])) return false

  for (var i = 1; i < polygon.length; i++) {
    if (pointInRing(longitude, latitude, polygon[i])) return false
  }
  return true
}

function countryAt(features, latitude, longitude) {
  var rows = Array.isArray(features) ? features : []
  for (var i = 0; i < rows.length; i++) {
    var feature = rows[i]
    if (!feature || !feature.geometry) continue
    var geometry = feature.geometry
    var polygons = geometry.type === "Polygon" ? [geometry.coordinates] : geometry.coordinates
    if (!Array.isArray(polygons)) continue

    for (var p = 0; p < polygons.length; p++) {
      if (pointInPolygon(longitude, latitude, polygons[p])) return feature.properties || null
    }
  }
  return null
}

function countryCentre(features, code) {
  var rows = Array.isArray(features) ? features : []
  var wanted = String(code || "").toUpperCase()

  for (var i = 0; i < rows.length; i++) {
    var feature = rows[i]
    if (!feature || !feature.geometry || !feature.properties) continue
    if (String(feature.properties.code || "").toUpperCase() !== wanted) continue

    var geometry = feature.geometry
    var polygons = geometry.type === "Polygon" ? [geometry.coordinates] : geometry.coordinates
    if (!Array.isArray(polygons)) return null

    var best = null
    for (var p = 0; p < polygons.length; p++) {
      var ring = polygons[p] && polygons[p][0]
      if (!Array.isArray(ring) || ring.length < 3) continue

      var points = []
      var previousLongitude = Number(ring[0][0])
      for (var n = 0; n < ring.length; n++) {
        var longitude = Number(ring[n][0])
        var latitude = Number(ring[n][1])
        if (!isFinite(longitude) || !isFinite(latitude)) continue
        if (points.length > 0) {
          while (longitude - previousLongitude > 180) longitude -= 360
          while (longitude - previousLongitude < -180) longitude += 360
        }
        points.push([longitude, latitude])
        previousLongitude = longitude
      }
      if (points.length < 3) continue

      var crossSum = 0
      var longitudeSum = 0
      var latitudeSum = 0
      for (var pointIndex = 0, previous = points.length - 1;
           pointIndex < points.length; previous = pointIndex++) {
        var first = points[previous]
        var second = points[pointIndex]
        var cross = first[0] * second[1] - second[0] * first[1]
        crossSum += cross
        longitudeSum += (first[0] + second[0]) * cross
        latitudeSum += (first[1] + second[1]) * cross
      }

      var area = Math.abs(crossSum)
      if (area < 1e-9 || (best && area <= best.area)) continue
      best = {
        area: area,
        latitude: latitudeSum / (3 * crossSum),
        longitude: wrapLongitude(longitudeSum / (3 * crossSum))
      }
    }

    return best ? { latitude: best.latitude, longitude: best.longitude } : null
  }

  return null
}

function countryEstimateRegion(features, code) {
  var bestPolygon = null
  var bestArea = 0

  for (var i = 0; i < features.length; i++) {
    var feature = features[i]
    if (!feature || !feature.geometry || !feature.properties) continue
    if (String(feature.properties.code || "").toUpperCase() !== code) continue

    var geometry = feature.geometry
    var polygons = geometry.type === "Polygon" ? [geometry.coordinates] : geometry.coordinates
    if (!Array.isArray(polygons)) break
    for (var p = 0; p < polygons.length; p++) {
      var ring = polygons[p] && polygons[p][0]
      if (!Array.isArray(ring) || ring.length < 3) continue
      var points = []
      var previousLongitude = Number(ring[0][0])
      for (var pointIndex = 0; pointIndex < ring.length; pointIndex++) {
        var longitude = Number(ring[pointIndex][0])
        var latitude = Number(ring[pointIndex][1])
        if (!isFinite(longitude) || !isFinite(latitude)) continue
        if (points.length > 0) {
          while (longitude - previousLongitude > 180) longitude -= 360
          while (longitude - previousLongitude < -180) longitude += 360
        }
        points.push([longitude, latitude])
        previousLongitude = longitude
      }
      if (points.length < 3) continue

      var area = 0
      for (var n = 0, previous = points.length - 1; n < points.length; previous = n++)
        area += points[previous][0] * points[n][1] - points[n][0] * points[previous][1]
      area = Math.abs(area)
      if (area > bestArea) {
        bestArea = area
        bestPolygon = [points].concat(polygons[p].slice(1))
      }
    }
    break
  }

  if (!bestPolygon) return null
  var bestRing = bestPolygon[0]
  var minimumLongitude = Infinity
  var maximumLongitude = -Infinity
  var minimumLatitude = Infinity
  var maximumLatitude = -Infinity
  for (var boundIndex = 0; boundIndex < bestRing.length; boundIndex++) {
    minimumLongitude = Math.min(minimumLongitude, bestRing[boundIndex][0])
    maximumLongitude = Math.max(maximumLongitude, bestRing[boundIndex][0])
    minimumLatitude = Math.min(minimumLatitude, bestRing[boundIndex][1])
    maximumLatitude = Math.max(maximumLatitude, bestRing[boundIndex][1])
  }

  return {
    polygon: bestPolygon,
    minimumLongitude: minimumLongitude,
    maximumLongitude: maximumLongitude,
    minimumLatitude: minimumLatitude,
    maximumLatitude: maximumLatitude
  }
}

function estimatedCountryLocation(features, code, key) {
  if (!Array.isArray(features)) return null
  if (estimatedFeatures !== features) {
    estimatedFeatures = features
    estimatedRegionCache = ({})
    estimatedLocationCache = ({})
  }
  var wanted = String(code || "").toUpperCase()
  var cacheKey = "$" + wanted + ":" + String(key || wanted)
  if (estimatedLocationCache[cacheKey] !== undefined)
    return estimatedLocationCache[cacheKey]
  var regionKey = "$" + wanted
  if (estimatedRegionCache[regionKey] === undefined)
    estimatedRegionCache[regionKey] = countryEstimateRegion(features, wanted)
  var region = estimatedRegionCache[regionKey]
  if (!region) return null

  var seed = 2166136261
  var source = String(key || wanted)
  for (var character = 0; character < source.length; character++) {
    seed ^= source.charCodeAt(character)
    seed = Math.imul(seed, 16777619)
  }
  seed >>>= 0

  function random() {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0
    return seed / 4294967296
  }

  for (var attempt = 0; attempt < 96; attempt++) {
    var candidateLongitude = region.minimumLongitude
      + random() * (region.maximumLongitude - region.minimumLongitude)
    var candidateLatitude = region.minimumLatitude
      + random() * (region.maximumLatitude - region.minimumLatitude)
    if (pointInPolygon(candidateLongitude, candidateLatitude, region.polygon)) {
      var location = {
        latitude: candidateLatitude,
        longitude: wrapLongitude(candidateLongitude)
      }
      estimatedLocationCache[cacheKey] = location
      return location
    }
  }
  var centre = countryCentre(features, wanted)
  if (centre) estimatedLocationCache[cacheKey] = centre
  return centre
}

function stationPosition(station, width, height, scale, centreLatitude, centreLongitude) {
  if (!station || station.latitude === null || station.longitude === null) return null
  var point = project(station.latitude, station.longitude, centreLatitude, centreLongitude)
  if (point.z < 0) return null
  var radius = Math.min(width, height) * 0.44 * scale
  return {
    x: width / 2 + point.x * radius,
    y: height / 2 - point.y * radius,
    z: point.z
  }
}

function nearestVisibleStation(stations, centreLatitude, centreLongitude, excludedUuid,
                               width, height, scale) {
  var rows = Array.isArray(stations) ? stations : []
  var excluded = String(excludedUuid || "")
  var viewportWidth = Number(width)
  var viewportHeight = Number(height)
  var viewportScale = Number(scale)
  var constrainToViewport = isFinite(viewportWidth) && viewportWidth > 0
    && isFinite(viewportHeight) && viewportHeight > 0
    && isFinite(viewportScale) && viewportScale > 0
  var viewportRadius = constrainToViewport
    ? Math.min(viewportWidth, viewportHeight) * 0.44 * viewportScale : 0
  var nearest = null
  var nearestDepth = -Infinity
  var preferred = null
  var preferredDepth = -Infinity

  for (var i = 0; i < rows.length; i++) {
    var station = rows[i]
    if (!station || station.latitude === null || station.longitude === null) continue
    var latitude = Number(station.latitude)
    var longitude = Number(station.longitude)
    if (!isFinite(latitude) || !isFinite(longitude)) continue
    var point = project(latitude, longitude, centreLatitude, centreLongitude)
    if (!isFinite(point.z) || point.z < 0) continue
    if (constrainToViewport) {
      var screenX = viewportWidth / 2 + point.x * viewportRadius
      var screenY = viewportHeight / 2 - point.y * viewportRadius
      if (screenX < 0 || screenX > viewportWidth
          || screenY < 0 || screenY > viewportHeight)
        continue
    }
    if (point.z > nearestDepth) {
      nearest = station
      nearestDepth = point.z
    }
    if (String(station.uuid || "") !== excluded && point.z > preferredDepth) {
      preferred = station
      preferredDepth = point.z
    }
  }

  return preferred || nearest
}

function stationAt(stations, x, y, width, height, scale, centreLatitude, centreLongitude, hitRadius) {
  var rows = Array.isArray(stations) ? stations : []
  var nearest = null
  var nearestDistance = Number(hitRadius || 12)

  for (var i = 0; i < rows.length; i++) {
    var position = stationPosition(rows[i], width, height, scale, centreLatitude, centreLongitude)
    if (!position) continue
    var dx = position.x - x
    var dy = position.y - y
    var distance = Math.sqrt(dx * dx + dy * dy)
    if (distance > nearestDistance) continue
    nearest = rows[i]
    nearestDistance = distance
  }
  return nearest
}

function mergeGeoStations(primary, secondary, countries) {
  var rows = mergeStations(primary, secondary, 5500)
  var output = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (row.latitude === null || row.longitude === null) {
      var estimate = estimatedCountryLocation(countries, row.countryCode, row.uuid)
      if (!estimate) continue
      var estimated = ({})
      for (var key in row) estimated[key] = row[key]
      estimated.latitude = estimate.latitude
      estimated.longitude = estimate.longitude
      estimated.estimatedLocation = true
      output.push(estimated)
    } else {
      output.push(row)
    }
    if (output.length >= 5500) break
  }
  return output
}

function combineStations(groups, maximum, replaceDuplicates) {
  var output = []
  var seen = ({})
  var limit = Math.max(1, Number(maximum || 500))

  for (var g = 0; g < groups.length; g++) {
    var rows = Array.isArray(groups[g]) ? groups[g] : []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!row || !row.uuid) continue
      var key = "$" + row.uuid
      if (seen[key] !== undefined) {
        if (replaceDuplicates && g > 0) output[seen[key]] = row
        continue
      }
      if (output.length >= limit) continue
      seen[key] = output.length
      output.push(row)
    }
  }
  return output
}

function mergeStations(primary, secondary, maximum) {
  return combineStations([primary, secondary], maximum, true)
}

function prioritizeStations(priority, fallback, maximum) {
  return combineStations([priority, fallback], maximum, false)
}

// Lowercase, strip accents and collapse whitespace so "Österreich",
// "osterreich" and "OSTERREICH" compare equal.
function foldText(value) {
  var text = String(value === null || value === undefined ? "" : value).toLowerCase()
  text = text.replace(/ß/g, "ss")
  try {
    text = text.normalize("NFKD").replace(/[̀-ͯ]/g, "")
  } catch (error) {
    // Older engines without String.prototype.normalize keep the accents.
  }
  return text.replace(/\s+/g, " ").trim()
}

function lookupCountry(countryNames, text) {
  if (!countryNames || !text) return ""
  var code = countryNames[text]
  return typeof code === "string" ? code : ""
}

function lookupState(stateNames, text) {
  if (!stateNames || !text) return null
  var entry = stateNames[text]
  if (!Array.isArray(entry) || entry.length < 2) return null
  var spellings = []
  for (var i = 1; i < entry.length; i++) {
    var folded = foldText(entry[i])
    if (folded && spellings.indexOf(folded) < 0) spellings.push(folded)
  }
  return { code: String(entry[0] || "").toUpperCase(), spellings: spellings }
}

// Splits a query into free text and an optional country or state filter,
// e.g. "jazz bayern" -> terms ["jazz"], state Bayern/Bavaria.
function parseSearchQuery(query, countryNames, stateNames) {
  var raw = String(query || "").trim().toLowerCase()
  var folded = foldText(query)
  var parsed = { text: folded, terms: [], countryCode: "", state: null, whole: false, filterText: "" }
  if (!folded) return parsed

  parsed.countryCode = lookupCountry(countryNames, raw) || lookupCountry(countryNames, folded)
  if (!parsed.countryCode) parsed.state = lookupState(stateNames, folded)
  if (parsed.countryCode || parsed.state) {
    parsed.whole = true
    return parsed
  }

  var words = folded.split(" ")
  if (words.length > 1) {
    // Longest run of words that names a country or a state wins.
    for (var size = words.length - 1; size >= 1; size--) {
      for (var start = 0; start + size <= words.length; start++) {
        var phrase = words.slice(start, start + size).join(" ")
        var code = phrase.length >= 2 ? lookupCountry(countryNames, phrase) : ""
        var state = !code && phrase.length >= 3 ? lookupState(stateNames, phrase) : null
        // Two-letter country codes ("de", "us") only count as filters at the
        // edges of a query, where they are unlikely to be part of a name.
        if (code && phrase.length === 2 && start !== 0 && start + size !== words.length) code = ""
        if (!code && !state) continue
        parsed.countryCode = code
        parsed.state = state
        parsed.filterText = phrase
        parsed.terms = words.slice(0, start).concat(words.slice(start + size))
        return parsed
      }
    }
  }
  parsed.terms = words
  return parsed
}

function stationMatchesState(station, state) {
  if (!state) return false
  var code = String(station.countryCode || "").toUpperCase()
  if (code && state.code && code !== state.code) return false
  var value = foldText(station.state)
  if (!value) return false
  for (var i = 0; i < state.spellings.length; i++)
    if (value.indexOf(state.spellings[i]) >= 0) return true
  return false
}

function wordStart(haystack, needle) {
  var index = haystack.indexOf(needle)
  while (index >= 0) {
    if (index === 0 || !/[a-z0-9]/.test(haystack.charAt(index - 1))) return true
    index = haystack.indexOf(needle, index + 1)
  }
  return false
}

// Returns a relevance score, or -1 when the station does not match.
function scoreStation(station, parsed) {
  if (!station) return -1
  var name = foldText(station.name)
  var tags = foldText(String(station.tags || "").replace(/,/g, " , "))
  var fields = {
    name: name,
    tags: tags,
    state: foldText(station.state),
    language: foldText(station.language),
    country: parsed.countryCode ? "" : foldText(station.country) + " " + foldText(station.countryCode),
    codec: foldText(station.codec)
  }
  var score = 0

  if (parsed.whole) {
    // A bare country or state name: stations located there, plus stations
    // that mention the name elsewhere ("USA Radio" in Germany).
    var located = parsed.countryCode
      ? String(station.countryCode || "").toUpperCase() === parsed.countryCode
      : stationMatchesState(station, parsed.state)
    var mentioned = false
    var mentionFields = ["name", "tags", "state", "language", "codec"]
    for (var m = 0; m < mentionFields.length && !mentioned; m++)
      mentioned = fields[mentionFields[m]].indexOf(parsed.text) >= 0
    if (!located && !mentioned) return -1
    score += located ? 40 : 0
    if (mentioned) score += wordStart(name, parsed.text) ? 30 : 15
  } else {
    if (parsed.countryCode || parsed.state) {
      var inside = parsed.countryCode
        ? String(station.countryCode || "").toUpperCase() === parsed.countryCode
        : stationMatchesState(station, parsed.state)
      // "Antenne Bayern" without state metadata still matches by name.
      if (inside) score += 20
      else if (wordStart(name, parsed.filterText) || tags.indexOf(parsed.filterText) >= 0) score += 12
      else return -1
    }

    var terms = parsed.terms
    for (var t = 0; t < terms.length; t++) {
      var term = terms[t]
      var termScore = 0
      if (name.indexOf(term) >= 0) termScore = wordStart(name, term) ? 14 : 9
      if (tags.indexOf(term) >= 0)
        termScore = Math.max(termScore, wordStart(tags, term) ? 11 : 6)
      if (fields.language.indexOf(term) >= 0) termScore = Math.max(termScore, 7)
      if (fields.state.indexOf(term) >= 0) termScore = Math.max(termScore, 7)
      if (fields.country.indexOf(term) >= 0) termScore = Math.max(termScore, 5)
      if (fields.codec.indexOf(term) >= 0) termScore = Math.max(termScore, 2)
      if (termScore === 0) return -1
      score += termScore
    }

    var phrase = terms.join(" ")
    if (phrase) {
      if (name === phrase) score += 60
      else if (name.indexOf(phrase) === 0) score += 35
      else if (terms.length > 1 && name.indexOf(phrase) >= 0) score += 20
      if (("," + tags.replace(/ , /g, ",") + ",").indexOf("," + phrase + ",") >= 0) score += 12
    }
  }

  // Popular, working stations first among equally relevant ones.
  var votes = Math.max(0, Number(station.votes) || 0)
  var clicks = Math.max(0, Number(station.clicks) || 0)
  score += Math.min(12, Math.log(1 + votes) * 1.1 + Math.log(1 + clicks) * 0.9)
  return score
}

function rankStations(stations, query, maximum, countryNames, stateNames, keepUnmatched) {
  var rows = Array.isArray(stations) ? stations : []
  var parsed = parseSearchQuery(query, countryNames, stateNames)
  if (!parsed.text) return []
  var scored = []
  for (var i = 0; i < rows.length; i++) {
    var score = scoreStation(rows[i], parsed)
    if (score < 0) {
      if (!keepUnmatched || !rows[i]) continue
      score = -1000
    }
    scored.push({ station: rows[i], score: score, order: i })
  }
  scored.sort(function(first, second) {
    return second.score - first.score || first.order - second.order
  })
  var limit = Math.max(1, Number(maximum || 150))
  var output = []
  for (var j = 0; j < scored.length && output.length < limit; j++)
    output.push(scored[j].station)
  return output
}

function searchStations(stations, query, maximum, countryNames, stateNames) {
  return rankStations(stations, query, maximum, countryNames, stateNames, false)
}

// Bounding box of a country's largest polygon (its mainland), so overseas
// territories do not stretch it around the globe.
function countryBounds(features, code) {
  var rows = Array.isArray(features) ? features : []
  var wanted = String(code || "").toUpperCase()
  for (var i = 0; i < rows.length; i++) {
    var feature = rows[i]
    if (!feature || !feature.geometry || !feature.properties) continue
    if (String(feature.properties.code || "").toUpperCase() !== wanted) continue
    var geometry = feature.geometry
    var polygons = geometry.type === "Polygon" ? [geometry.coordinates] : geometry.coordinates
    if (!Array.isArray(polygons)) return null
    var best = null
    for (var p = 0; p < polygons.length; p++) {
      var ring = polygons[p] && polygons[p][0]
      if (!Array.isArray(ring) || ring.length < 3) continue
      var box = null
      var previous = 0
      for (var n = 0; n < ring.length; n++) {
        var longitude = Number(ring[n][0])
        var latitude = Number(ring[n][1])
        if (!isFinite(longitude) || !isFinite(latitude)) continue
        if (box) {
          while (longitude - previous > 180) longitude -= 360
          while (longitude - previous < -180) longitude += 360
        }
        previous = longitude
        if (!box) box = { south: latitude, north: latitude, west: longitude, east: longitude }
        box.south = Math.min(box.south, latitude)
        box.north = Math.max(box.north, latitude)
        box.west = Math.min(box.west, longitude)
        box.east = Math.max(box.east, longitude)
      }
      if (!box) continue
      box.size = (box.north - box.south) * (box.east - box.west)
      if (!best || box.size > best.size) best = box
    }
    return best
  }
  return null
}

// Stations of the chosen country plus those in a margin around it, so the
// neighbourhood lights up too. Neighbours come first so the chosen
// country's own dots are drawn on top.
function stationsAroundCountry(stations, features, code, maximum) {
  var rows = Array.isArray(stations) ? stations : []
  var wanted = String(code || "").toUpperCase()
  if (!wanted) return []
  var limit = Math.max(1, Number(maximum || 5500))
  var own = []
  var nearby = []
  var box = countryBounds(features, wanted)
  var centreLatitude = 0, centreLongitude = 0, halfLatitude = -1, halfLongitude = -1
  if (box && box.east - box.west < 120) {
    var span = Math.max(box.north - box.south, box.east - box.west)
    var margin = clamp(span * 0.35, 2, 8)
    centreLatitude = (box.north + box.south) / 2
    centreLongitude = (box.east + box.west) / 2
    halfLatitude = (box.north - box.south) / 2 + margin
    halfLongitude = (box.east - box.west) / 2
      + margin / Math.max(0.3, Math.cos(centreLatitude * Math.PI / 180))
  }
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (!row) continue
    if (String(row.countryCode || "").toUpperCase() === wanted) {
      own.push(row)
      continue
    }
    if (halfLatitude < 0 || row.latitude === null || row.longitude === null) continue
    var latitude = Number(row.latitude)
    var longitude = Number(row.longitude)
    if (!isFinite(latitude) || !isFinite(longitude)) continue
    if (Math.abs(latitude - centreLatitude) > halfLatitude) continue
    var offset = ((longitude - centreLongitude) % 360 + 540) % 360 - 180
    if (Math.abs(offset) > halfLongitude) continue
    nearby.push(row)
  }
  own = own.slice(0, limit)
  return nearby.slice(0, limit - own.length).concat(own)
}

function stationsForCountry(stations, code, maximum) {
  var rows = Array.isArray(stations) ? stations : []
  var wanted = String(code || "").toUpperCase()
  if (!wanted) return []

  var output = []
  var limit = Math.max(1, Number(maximum || 150))
  for (var i = 0; i < rows.length && output.length < limit; i++) {
    if (String(rows[i] && rows[i].countryCode || "").toUpperCase() === wanted)
      output.push(rows[i])
  }
  return output
}

function utf8Length(text) {
  var bytes = 0
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code <= 0x7f) bytes++
    else if (code <= 0x7ff) bytes += 2
    else if (code >= 0xd800 && code <= 0xdbff
             && i + 1 < text.length
             && text.charCodeAt(i + 1) >= 0xdc00 && text.charCodeAt(i + 1) <= 0xdfff) {
      bytes += 4
      i++
    } else bytes += 3
  }
  return bytes
}

function stationWindow(stations, uuid, maximum) {
  var rows = Array.isArray(stations) ? stations : []
  var index = indexByUuid(rows, uuid)
  if (index < 0) return []

  var limit = Math.min(rows.length, Math.max(1, Number(maximum || 500)))
  while (true) {
    var before = Math.floor((limit - 1) / 2)
    var start = (index - before + rows.length) % rows.length
    var output = []
    for (var i = 0; i < limit; i++) output.push(rows[(start + i) % rows.length])
    if (utf8Length(JSON.stringify(output)) + 1 <= maximumSelectionBytes) return output
    if (limit === 1) return []
    limit = Math.max(1, Math.floor(limit / 2))
  }
}

function compactTags(tags, maximum) {
  var raw = String(tags || "")
  var parts = raw.split(",")
  var output = []
  var limit = Math.max(1, Number(maximum || 2))
  for (var i = 0; i < parts.length && output.length < limit; i++) {
    var part = cleanText(parts[i])
    if (part && output.indexOf(part) === -1) output.push(part)
  }
  return output.join(" · ")
}

// Strip control, zero-width and bidi-control characters, collapse spaces, trim.
function cleanText(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f-\u009f\u00ad\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff]/g, "")
    .replace(/\s+/g, " ")
    .trim()
}

// Split stream metadata into artist/title. A leading station name is removed
// only when it is the whole title or is followed by a separator, so
// "Rockwell - ..." on a station called "Rock" stays intact.
function trackParts(rawTitle, stationName) {
  var title = cleanText(rawTitle).replace(/^[\s:|\-–—·]+/, "").trim()
  var station = cleanText(stationName)
  if (station && title.toLowerCase().indexOf(station.toLowerCase()) === 0) {
    var rest = title.slice(station.length)
    if (rest === "") title = ""
    else if (/^(\s+[-–—|·:\/]\s+|\s*[:|·]\s*)/.test(rest))
      title = rest.replace(/^[\s:|\-–—·\/]+/, "").trim()
  }
  var split = title.match(/^(.+?)\s+[-–—]\s+(.+)$/)
  return split ? { artist: split[1].trim(), title: split[2].trim() } : { artist: "", title: title }
}

function joinParts(parts) {
  var output = []
  for (var i = 0; i < parts.length; i++) {
    var part = cleanText(parts[i]).replace(/^[·|,\-\s]+|[·|,\-\s]+$/g, "")
    if (part && output.indexOf(part) === -1) output.push(part)
  }
  return output.join(" · ")
}

function stationMeta(station) {
  if (!station) return ""
  return joinParts([station.countryCode, station.codec,
    Number(station.bitrate) > 0 ? Number(station.bitrate) + " kbps" : ""])
}

function stationDetails(station, tagLimit) {
  if (!station) return ""
  var tags = compactTags(station.tags, tagLimit)
  return joinParts([stationMeta(station)].concat(tags ? tags.split(" · ") : []))
}

function indexByUuid(stations, uuid) {
  var rows = Array.isArray(stations) ? stations : []
  for (var i = 0; i < rows.length; i++) if (rows[i].uuid === uuid) return i
  return -1
}
