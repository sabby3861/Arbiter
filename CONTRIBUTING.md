# Contributing to Arbiter

Thanks for your interest in contributing to Arbiter! Here's how to get started.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/Arbiter.git`
3. Create a branch: `git checkout -b feature/your-feature`
4. Make your changes
5. Run tests: `swift test`
6. Push and open a pull request

## Development Setup

- Xcode 16+ or Swift 6.1+
- macOS 14+
- Run `swift build` to verify the project compiles
- Run `swift test` to run the test suite

## Code Style

- Follow Swift API Design Guidelines
- All public APIs must have doc comments
- All types must be `Sendable` (Swift 6 strict concurrency)
- Use `async/await` for all asynchronous operations
- No force unwraps, force tries, or force casts
- Use `os.Logger` for debug logging, never `print()`
- Keep functions under 40 lines and files under 400 lines

## Adding a New Provider

1. Create a new directory under `Sources/Arbiter/Providers/YourProvider/`
2. Implement the `AIProvider` protocol
3. Add a model enum listing available models
4. Add a mapper for converting between Arbiter types and provider-specific JSON
5. Add comprehensive tests under `Tests/ArbiterTests/`
6. Update the README with the new provider

## Pull Request Guidelines

- Keep PRs focused on a single change
- Include tests for new functionality
- Update documentation if public APIs change
- Ensure all tests pass before submitting

## Reporting Issues

Open an issue on GitHub with:
- A clear description of the problem
- Steps to reproduce
- Expected vs actual behavior
- Swift version and platform

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
