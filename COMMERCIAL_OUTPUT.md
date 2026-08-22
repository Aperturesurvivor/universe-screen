# Commercial output and provenance boundary

This repository can produce a local, synthetic visual proof for the **Agent
Universe Launch Loop**. The minimum output package is one silent 15-second,
1920x1080, 30 fps H.264 MP4 captured from Demo Mode, plus the manifest and
export preset used for that capture.

Demo Mode is intentionally narrower than the local Universe Screen product. It
loads only the checked-in `Resources/Demo/sample-manifest.json`, fixes the
procedural seed and scene timestamp, and pauses live filesystem and local Codex
monitoring. The labels in that sample are invented for the demo; they do not
come from a user workspace, a rollout, a prompt, or agent output.

## Included in the output offer

- the rendered 15-second video;
- the validated synthetic manifest used to render it;
- `Resources/Demo/export-1080p-15s.json` as the delivery specification; and
- a short provenance record containing the repository commit, manifest hash,
  preset hash, capture date, and capture hardware/software versions.

## Excluded from the output offer

- this source code, an app binary, or any software license;
- live filesystem labels, customer files, Codex sessions, prompts, messages,
  reasoning, tool arguments, commands, patches, or outputs;
- the separate `universe-screen-codex` runtime-injection prototype;
- customer-specific ingestion or a claim that this is a hosted monitoring
  service;
- third-party logos, music, fonts, stock media, or trademarks not separately
  cleared; and
- claims about productivity, agent accuracy, or performance beyond evidence
  recorded for the specific capture.

The repository currently has no open-source license, so publishing source does
not grant reuse rights. Selling a rendered output does not change that source
boundary or transfer ownership of the app.

## Required preflight before any commercial delivery

1. Run the native test suite and confirm the sample manifest and export preset
   pass validation.
2. Review every visible label in the manifest and captured frames. The validator
   blocks obvious paths, email addresses, URLs, and template tokens, but it
   cannot decide whether arbitrary text is confidential or trademarked.
3. Capture only with Demo Mode enabled. Confirm Mission Control says
   `Synthetic manifest` and `Synthetic agents` rather than `Live` integrations.
4. Use the exact duration, dimensions, frame rate, codec, container, and audio
   policy in the checked-in export preset.
5. Record SHA-256 hashes of the manifest, preset, and final MP4 alongside the
   repository commit. Keep the final review and delivery decision human-gated.

The preset is a delivery contract, not an implemented offline video exporter.
Screen capture, trimming, codec inspection, and final visual review remain
manual completion steps.
