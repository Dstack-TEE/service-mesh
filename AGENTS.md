# Repository Instructions

- Avoid degradation handling, fallbacks, hacks, heuristics, local
  stabilizations, or post-processing bandages that are not faithful
  general algorithms.
- When output is structured with multiple levels of bullet points, use
  multiple levels when the content needs them. The single-level rule
  only applies when the content can be structured in one level.

## Changelog

- Maintain `CHANGELOG.md`.
- Add an `Unreleased` entry for every merged change that affects user
  behavior, deployment flow, trust or security model, public
  configuration, examples, or user-facing documentation.
- Keep entries short and concrete. State what changed and why it
  matters to an operator or developer.
- When cutting a release, move relevant `Unreleased` entries under a
  dated version heading and leave a new empty `Unreleased` section.
