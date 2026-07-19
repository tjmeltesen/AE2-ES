# Shared libraries

This directory contains project-agnostic, import-safe Lua utilities shared by
AE2-ES runtime modules. Domain-specific broker logic belongs in `src/`; entry
points and composition remain in `bin/`.

## Remote-control rollout

`enableRemoteControl` permits authenticated PING/PONG only. Complete and
record a manual PING soak before enabling either `enableRemoteThrottle` or
`enableRemoteRestart`; each command remains independently disabled by default.

Follow-up: replace the current `sha256(message + secret)` control signature
construction with a proper HMAC. This is documentation only; HMAC is not
implemented in this pass.
