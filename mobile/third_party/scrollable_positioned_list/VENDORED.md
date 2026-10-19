# Vendored scrollable_positioned_list

- **Source:** [pub.dev `scrollable_positioned_list` 0.3.8](https://pub.dev/packages/scrollable_positioned_list/versions/0.3.8), from [google/flutter.widgets](https://github.com/google/flutter.widgets/tree/master/packages/scrollable_positioned_list).
- **Archive sha256:** `1b54d5f1329a1e263269abc9e2543d90806131aa14fe7c6062a8054d57249287`
- **License:** BSD-3-Clause, in `LICENSE`.
- **Copied:** `lib/`, `LICENSE`, `README.md`, `CHANGELOG.md`, `pubspec.yaml`, unchanged except one trailing space trimmed from `README.md`. The example and tests were left out.

## Local changes

The upstream package keys every item by its index, so inserting a message
at the bottom of a reversed chat moves every item to a new key and remounts
every built row. The change adds an optional `findChildIndexCallback` to
`ScrollablePositionedList`. When it is set, an item whose widget has a key
keeps that key in the list, and the callback finds its new index.
Without the callback, the package behaves as upstream.
