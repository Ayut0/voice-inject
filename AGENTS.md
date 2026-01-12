# Repository Guidelines

## Project Structure & Module Organization
- `hello.go` is the current Go entrypoint and the only compiled source in the repository.
- `docs/` contains planning and design notes (see `docs/development_plan.md` and `docs/voice_inject_development_documentation.md`).
- `cmd/` and `internal/` are present but currently empty; future CLI and package code is expected to live here following standard Go layout.

## Build, Test, and Development Commands
- `go build ./...`: Compile all Go packages in the module. Use this to verify the module builds after changes.
- `go run hello.go`: Run the current sample entrypoint.
- `go fmt ./...`: Format all Go files to standard Go style.

## Coding Style & Naming Conventions
- Go 1.22 module (`go.mod`): keep code compatible with Go 1.22.
- Formatting: use `gofmt` (`go fmt ./...`) before committing.
- Naming: follow Go conventions (MixedCaps for exported identifiers, lowerCamel for unexported, short receiver names).

## Testing Guidelines
- No test framework or test files are present yet.
- When adding tests, use Go’s standard `testing` package and name files `*_test.go`.
- Prefer table-driven tests and keep test data close to the package under test (e.g., `internal/foo/foo_test.go`).

## Commit & Pull Request Guidelines
- No established commit message convention found in the repository. Use clear, imperative subjects (e.g., "Add CLI skeleton").
- PRs should include a brief summary, the commands run (if any), and any relevant screenshots or terminal output.
- Link related issues or tasks when available.

## Configuration & Environment Notes
- This repository targets macOS in the current docs (e.g., `pbcopy`, `osascript` in the plan); call out OS-specific behavior in PRs.
