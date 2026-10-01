# Reference captures (Phase 0)

Status: **not captured.** Needs a simulator or device session against the
production Expo build; nothing here has been recorded yet.

## Naming

`<screen>__<device>__<appearance>__<text-size>__<state>.png`, for example
`jobs-list__iphone-15__dark__default__populated.png`. Recordings use `.mov`.

## Matrix to capture per screen

- Devices: iPhone compact, iPhone large, iPad portrait, iPad landscape.
- Appearance: light and dark.
- Text size: default and largest accessibility Dynamic Type.
- States: loading, empty, populated, offline, error, destructive confirmation.

## Rules

- Use disposable accounts only; never capture a real customer's data.
- Record the Expo build number and date next to each batch.
