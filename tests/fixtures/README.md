# Fixtures

Minimal project trees for specs that depend on project *shape* rather than
project content: which formatter conform picks, whether angularls is allowed to
start, whether spring-boot.nvim recognises a Gradle project.

They are copied into a temp dir by `helpers.fixture(name)` before use — the
config auto-saves on BufLeave, so a spec that opened a file in place would
rewrite the fixture. Keep them as small as the assertion allows.
