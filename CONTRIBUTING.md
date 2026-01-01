# Contributing to Win-Reboot-Project

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Code of Conduct

- Be respectful and constructive
- Help others learn and grow
- Focus on what is best for the community

## How to Contribute

### Reporting Bugs

When filing an issue, include:
- Your Linux distribution and version
- GRUB version (`grub-install --version`)
- Complete error messages or logs
- Steps to reproduce the issue

### Suggesting Enhancements

- Describe the enhancement in detail
- Explain why it would be useful
- Provide examples if applicable

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Test thoroughly (in a VM if possible)
5. Commit with clear messages (`git commit -m 'Add amazing feature'`)
6. Push to your fork (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## Development Guidelines

### Shell Script Style

- Use `#!/usr/bin/env bash` shebang
- Set `set -euo pipefail` at the top
- Include usage/help functions
- Provide clear error messages
- Use consistent naming: `snake_case` for functions

### Testing

Before submitting:
```bash
# Validate syntax
bash -n scripts/your-script.sh

# Test in a VM
# - Test on different distributions
# - Test with and without optional dependencies
# - Verify GRUB changes don't break existing boot entries
```

### Preset Files

When adding or modifying removal presets:
- Document each removal path with comments
- Test that OOBE (Out-of-Box Experience) still works
- Verify Windows activation isn't affected
- Note any known limitations

### Documentation

- Update README.md for user-facing changes
- Update INSTALL.md for setup/configuration changes
- Add inline comments for complex logic
- Include usage examples

## Project Structure

```
Win-Reboot-Project/
├── scripts/              # Main executable scripts
│   ├── fetch_iso.sh
│   ├── tiny11.sh
│   ├── grub_entry.sh
│   ├── reboot_to_installer.sh
│   ├── check_deps.sh
│   ├── interactive_setup.sh
│   └── cleanup.sh
├── data/
│   └── removal-presets/  # Tiny11 removal lists
│       ├── minimal.txt
│       ├── lite.txt
│       └── aggressive.txt
├── out/                  # Build outputs (gitignored)
├── tmp/                  # Temporary files (gitignored)
├── README.md
├── INSTALL.md
├── LICENSE
└── Makefile
```

## Areas for Contribution

### High Priority
- [ ] Test on more Linux distributions (OpenSUSE, Gentoo, etc.)
- [ ] Add Windows 10 ISO support
- [ ] Improve error handling and recovery
- [ ] Add more comprehensive tests

### Medium Priority
- [ ] Implement wimboot/iPXE fallback for Secure Boot scenarios
- [ ] Add GUI wrapper (zenity/kdialog)
- [ ] Support for multiple Windows editions in one ISO
- [ ] Automatic cleanup after successful Windows installation

### Low Priority
- [ ] Add language packs support
- [ ] Custom Windows theme injection
- [ ] Automated driver injection
- [ ] Post-install script execution

## Release Process

Maintainers will:
1. Update version numbers
2. Update CHANGELOG
3. Tag releases with semantic versioning
4. Create GitHub releases with notes

## Questions?

- Open a GitHub issue for questions
- Check existing issues and PRs first
- Be patient - this is a community project

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
