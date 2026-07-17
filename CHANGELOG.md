# Changelog

## 0.14.0

* **Deletion propagation**: samples deleted from HealthKit are now reported to the server. The anchored queries used for incremental sync already receive `HKDeletedObject` tombstones; they were previously discarded. The sync payload's `data` object has a new `deleted` array of `{id, type}` entries (`id` = the deleted sample's UUID, `type` = the HK type identifier of the query that reported it). **Server contract**: for each tombstone, delete the stored record whose id equals `id` and any records whose `parentId` equals `id`. Matches the Android SDK 0.12.0 payload change.
  - Deletion-only pages now advance and persist the anchor correctly (previously a page containing only deletions was treated as "no data" and the tombstones were lost).
  - Page-termination check now counts samples + deletions, matching what the query `limit` actually bounds.
* **Full-export anchor baseline moved to export start**: the incremental anchor for each type is now captured *before* its first export page instead of at type completion. Anything written or deleted while a (possibly multi-hour) initial export runs is replayed by the first incremental sync — previously the completion-time baseline silently skipped mid-export writes and permanently lost tombstones for samples deleted during the export (including ones the export had already uploaded). Overlap re-delivery is absorbed by server upsert-by-id.

## 0.13.0

* **Sync telemetry**: new `/logs` endpoint integration for initial full sync diagnostics.
  - `historical_data_sync_start` event sent before the first payload with per-type record counts, time range, and device state.
  - `historical_data_type_sync_end` event sent per data type as each completes (fire-and-forget), with record count, duration, success status, and device state snapshot.
  - Device state includes battery level/state, thermal state, low power mode, RAM usage, and foreground/background task type.
  - Types with zero records are excluded from end events.
  - Start event is sent for both fresh and resumed full exports.

## 0.12.0

* **Source device name**: added `name` field to the source object in health data payloads, providing human-readable device identification alongside existing device metadata.

## 0.11.0

* **Smarter token refresh error handling**: token refresh failures are now classified as either `authFailure` (refresh token rejected with 401/403) or `networkError` (timeout, DNS, 5xx). Only genuine auth failures trigger user disconnect — transient network errors during refresh no longer force sign-out, allowing the SDK's retry mechanism to recover automatically.

## 0.10.0

* **Combined payloads**: all health data types are now merged into a single payload per sync round instead of separate requests per type.
* **Interleaved sync**: data is fetched round-robin across all types (newest to oldest) instead of sequentially type-by-type.
* **Streaming JSON serialization**: payloads are serialized directly to the network stream, reducing memory usage from O(n) to O(depth).
* **Token refresh fix**: fixed stale credential being reused across sync rounds after a token refresh — credential is now read fresh from Keychain before each upload.
* **Bearer prefix normalization**: access tokens returned by the refresh endpoint without the `Bearer ` prefix are now handled correctly.
* **Sign-out reliability**: `signOut()` now guarantees state cleanup even if the native call throws.
* **Cleaned up logging**: removed verbose debug logs and all token/credential values from log output. Logs now show only essential sync lifecycle events, payload summaries, and HTTP statuses.

## 0.9.0

* Initial tracked release.
