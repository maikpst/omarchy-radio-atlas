#!/usr/bin/env python3
"""Build the globe's map assets from Natural Earth GeoJSON.

Usage (needs shapely, e.g. through uv):

  uv run --with shapely python3 tools/build-map-data.py \
    ne_50m_admin_0_countries.geojson ne_10m_admin_1_states_provinces.geojson

Writes assets/countries.json, assets/states.json and extends
assets/country-search.json with German names and state lookups.
Source data: https://github.com/nvkelso/natural-earth-vector (public domain).
"""

import json
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

from shapely.geometry import MultiPolygon, Polygon, mapping, shape
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"

COUNTRY_TOLERANCE = 0.02
STATE_TOLERANCE = 0.025
PRECISION = 3

# Countries whose Natural Earth admin-1 level is finer than what people call
# states or provinces. These are dissolved into the named grouping instead.
DISSOLVE = {
    "GB": "geonunit",
    "IT": "region",
    "FR": "region",
    "ES": "region",
    "SI": "region",
    "LV": "region",
    "PH": "region",
    "UG": "region",
    "MK": "region",
    "MT": "region",
    "AZ": "region",
    "IE": "region",
}


def fold(text):
    text = unicodedata.normalize("NFKD", str(text or ""))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return " ".join(text.lower().replace("ß", "ss").split())


def rounded(geometry):
    def ring(coords):
        out = []
        for x, y in coords:
            point = [round(x, PRECISION), round(y, PRECISION)]
            if not out or out[-1] != point:
                out.append(point)
        if out and out[0] != out[-1]:
            out.append(out[0])
        return out

    polygons = []
    for polygon in getattr(geometry, "geoms", [geometry]):
        if not isinstance(polygon, Polygon) or polygon.is_empty:
            continue
        exterior = ring(polygon.exterior.coords)
        if len(exterior) < 4:
            continue
        rings = [exterior]
        for interior in polygon.interiors:
            hole = ring(interior.coords)
            if len(hole) >= 4:
                rings.append(hole)
        polygons.append(rings)
    if not polygons:
        return None
    if len(polygons) == 1:
        return {"type": "Polygon", "coordinates": polygons[0]}
    return {"type": "MultiPolygon", "coordinates": polygons}


def polygons_of(geometry):
    return [g for g in getattr(geometry, "geoms", [geometry]) if isinstance(g, Polygon)]


def simplify(geometry, tolerance, minimum_area):
    geometry = geometry.buffer(0) if not geometry.is_valid else geometry
    parts = polygons_of(geometry)
    if not parts:
        return None
    largest = max(parts, key=lambda p: p.area)
    kept = [p for p in parts if p.area >= minimum_area or p is largest]
    simplified = MultiPolygon(kept).simplify(tolerance, preserve_topology=True)
    return rounded(simplified)


def label_point(geometry, x=None, y=None):
    if x is not None and y is not None and -180 <= x <= 180 and -90 <= y <= 90:
        return round(y, 3), round(x, 3)
    largest = max(polygons_of(geometry), key=lambda p: p.area)
    point = largest.representative_point()
    return round(point.y, 3), round(point.x, 3)


def point_count(geometry):
    polygons = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
    return sum(len(ring) for polygon in polygons for ring in polygon)


def build_countries(source):
    previous = json.loads((ASSETS / "countries.json").read_text())["features"]
    previous_names = {}
    for feature in previous:
        code = feature["properties"]["code"]
        previous_names.setdefault(code, feature["properties"]["name"])

    rows = json.loads(Path(source).read_text())["features"]
    sovereign = {}
    for feature in rows:
        p = feature["properties"]
        if p["ISO_A2_EH"] not in ("-99", None):
            sovereign.setdefault(p["SOV_A3"], p["ISO_A2_EH"])

    features = []
    for feature in rows:
        p = feature["properties"]
        code = p["ISO_A2_EH"]
        if code in ("-99", None):
            code = sovereign.get(p["SOV_A3"], "-99")
        if code == "-99":
            continue
        geometry = shape(feature["geometry"])
        simplified = simplify(geometry, COUNTRY_TOLERANCE, 0.002)
        if not simplified:
            continue
        latitude, longitude = label_point(geometry, p.get("LABEL_X"), p.get("LABEL_Y"))
        name = previous_names.pop(code, None) or p["NAME_EN"] or p["NAME"]
        features.append({
            "type": "Feature",
            "properties": {
                "name": name,
                "code": code,
                "label": p.get("NAME_DE") or p["NAME"],
                "labelLatitude": latitude,
                "labelLongitude": longitude,
                "rank": int(p.get("LABELRANK") or 5),
                "area": round(geometry.area, 3),
            },
            "geometry": simplified,
        })
    # Large countries first so enclaves (Lesotho, San Marino, ...) paint on top.
    features.sort(key=lambda f: -f["properties"]["area"])
    return features


def build_states(source):
    rows = json.loads(Path(source).read_text())["features"]
    groups = defaultdict(list)
    for feature in rows:
        p = feature["properties"]
        code = p.get("iso_a2")
        if not code or code == "-99" or not feature.get("geometry"):
            continue
        field = DISSOLVE.get(code)
        if field:
            key = (code, p.get(field) or p.get("name"))
        else:
            key = (code, p.get("adm1_code") or p.get("name"))
        groups[key].append(feature)

    features = []
    for (code, _key), members in groups.items():
        geometry = unary_union([shape(f["geometry"]).buffer(0) for f in members])
        if geometry.is_empty:
            continue
        p = members[0]["properties"]
        if DISSOLVE.get(code):
            name = p.get(DISSOLVE[code]) or p.get("name")
            latitude, longitude = label_point(geometry)
            rank = min(int(m["properties"].get("labelrank") or 9) for m in members)
            german = name
        else:
            name = p.get("name") or p.get("name_en")
            german = p.get("name_de") or name
            latitude, longitude = label_point(geometry, p.get("longitude"), p.get("latitude"))
            rank = int(p.get("labelrank") or 9)
        simplified = simplify(geometry, STATE_TOLERANCE, 0.004)
        if not simplified or not name:
            continue
        english = name if DISSOLVE.get(code) else (p.get("name_en") or name)
        features.append({
            "type": "Feature",
            "properties": {
                "name": name,
                "label": german,
                "english": english,
                "code": code,
                "labelLatitude": latitude,
                "labelLongitude": longitude,
                "rank": rank,
                "area": round(geometry.area, 4),
            },
            "geometry": simplified,
        })
    features.sort(key=lambda f: (f["properties"]["code"], -f["properties"]["area"]))
    return features


def write_collection(path, features):
    path.write_text(json.dumps(
        {"type": "FeatureCollection", "features": features},
        ensure_ascii=False, separators=(",", ":")))
    total = sum(point_count(f["geometry"]) for f in features)
    print(f"{path.name}: {len(features)} features, {total} points, {path.stat().st_size} bytes")


def main():
    countries = build_countries(sys.argv[1])
    states = build_states(sys.argv[2])
    write_collection(ASSETS / "countries.json", countries)

    lookup_path = ASSETS / "country-search.json"
    lookup = json.loads(lookup_path.read_text())
    for key, code in list(lookup.items()):
        lookup.setdefault(fold(key), code)
    for feature in countries:
        p = feature["properties"]
        for name in (p["name"], p["label"]):
            key = fold(name)
            if key and key not in lookup:
                lookup[key] = p["code"]
        lookup.setdefault(p["code"].lower(), p["code"])
        lookup.setdefault(p["name"].strip().lower(), p["code"])
    lookup_path.write_text(json.dumps(dict(sorted(lookup.items())), ensure_ascii=False, indent=2) + "\n")

    # State search: folded name -> [country code, spellings Radio Browser may use].
    # Names shared by states in several countries ("Central", "North") or
    # that already name a country are too ambiguous to act as a filter.
    state_lookup = {}
    owners = defaultdict(set)
    for feature in states:
        p = feature["properties"]
        spellings = list(dict.fromkeys(n for n in (p["name"], p["english"], p["label"]) if n))
        for name in spellings:
            key = fold(name)
            owners[key].add(p["code"])
            if len(key) >= 3 and key not in state_lookup:
                state_lookup[key] = [p["code"]] + spellings[:2]
    for key, codes in owners.items():
        if key in state_lookup and (len(codes) > 1 or key in lookup):
            del state_lookup[key]
    for feature in states:
        del feature["properties"]["english"]
    (ASSETS / "state-search.json").write_text(
        json.dumps(dict(sorted(state_lookup.items())), ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"state-search.json: {len(state_lookup)} names")
    write_collection(ASSETS / "states.json", states)


if __name__ == "__main__":
    main()
