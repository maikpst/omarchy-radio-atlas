# Map data

`countries.json` is derived from Natural Earth's 1:50m Admin 0 Countries data,
`states.json` from the 1:10m Admin 1 States and Provinces data. Some countries'
admin-1 units are dissolved into their regions (Italy, France, Spain, the UK,
...). Labels use Natural Earth's German names. `tools/build-map-data.py`
rebuilds both files and the lookups below. Natural Earth data is in the public
domain.

Source: https://www.naturalearthdata.com/

# Country search names

`country-search.json` maps lowercase names and codes to Radio Browser country
codes. It combines Radio Browser's country directory, retrieved on 2026-09-29,
with the labels in `countries.json` and the aliases `USA`, `United States`, `UK`,
and `Great Britain`. Entries without a name or a two-letter code are excluded.
The UI and fetch script share this bundled snapshot, so lookup works offline
without another network request. Update it when country names or codes change.

Source: https://de1.api.radio-browser.info/json/countries

# State and language search names

`state-search.json` maps folded (lowercase, accent-free) state and province
names to a country code and the spellings Radio Browser stations use, e.g.
`bayern` -> `["DE", "Bayern", "Bavaria"]`. Names shared by several countries are
left out. `language-search.json` maps German language names to Radio Browser's
English language values.
