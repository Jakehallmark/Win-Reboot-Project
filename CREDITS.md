# Credits & Acknowledgments

Win-Reboot-Project stands on the shoulders of giants. This project would not exist without the incredible work of the following individuals and projects.

## 🌟 Primary Inspiration

### Tiny11 Project
**Repository**: https://github.com/ntdevlabs/tiny11builder  
**Creator**: ntdevlabs

**Our deepest gratitude goes to ntdevlabs and the Tiny11 project!**

The Tiny11 project revolutionized Windows 11 by creating a lightweight, bloat-free installation that removes unnecessary components while maintaining full functionality. Their work provided:

- **Methodology**: Safe component removal strategies
- **Research**: Extensive testing of what can be removed without breaking Windows
- **Documentation**: Clear guidance on creating minimal Windows installations
- **Community**: Active development and user support
- **Innovation**: Registry tweaks for TPM/Secure Boot bypass

Win-Reboot-Project adapts their PowerShell-based approach to work natively on Linux systems, bringing the Tiny11 philosophy to the Linux ecosystem.

**If you appreciate Win-Reboot-Project, please visit and star the original Tiny11 project!**

---

## 🛠️ Essential Tools & Libraries

### wimlib
**Website**: https://wimlib.net  
**Author**: Eric Biggers

Cross-platform library for creating, extracting, and modifying Windows Imaging (WIM) archives. Absolutely essential for Linux-based Windows image manipulation.

- Enables mounting and editing WIM/ESD files on Linux
- Provides `wimlib-imagex` command-line tool
- Reliable alternative to Windows DISM on Linux

### UUP Dump
**Website**: https://uupdump.net  
**Community**: UUP Dump contributors

Community-driven service for downloading Windows updates directly from Microsoft's servers.

- Provides API for latest Windows build detection
- Generates download scripts for authentic Windows ISOs
- Eliminates need for third-party ISO sources
- Ensures all downloads come from official Microsoft CDN

### aria2
**Website**: https://aria2.github.io  
**Author**: Tatsuhiro Tsujikawa

Lightweight multi-protocol & multi-source download utility.

- Fast, parallel downloads from Microsoft CDN
- Reliable resumption of interrupted downloads
- Used by UUP Dump helper scripts

---

## 📚 Technology Stack

### GRUB Bootloader
**Website**: https://www.gnu.org/software/grub/

Grand Unified Bootloader - enables ISO loopback mounting and chainloading without USB media.

### p7zip / 7-Zip
**Website**: https://7-zip.org

File archiver for extracting ISO contents and manipulating archives.

### xorriso / genisoimage
ISO 9660 filesystem creation tools for rebuilding modified Windows ISOs.

---

## 🎓 Knowledge & Research

### Microsoft Documentation
- Official Windows setup and deployment documentation
- Windows PE (Preinstallation Environment) specifications
- UEFI boot specifications

### Community Forums & Wikis
- MyDigitalLife Forums - Windows modification community
- ArchWiki - Comprehensive GRUB and Windows installation guides
- Gentoo Wiki - Cross-platform tooling documentation

---

## 💡 Concept & Methodology

This project combines:
1. **Tiny11's debloating philosophy** - Minimal, functional Windows
2. **Linux systems administration** - Bash scripting, package management
3. **GRUB bootloader expertise** - Chainloading and loopback mounting
4. **Open source tools** - wimlib, aria2, p7zip, xorriso

---

## 🙏 Thank You

Special thanks to:
- **ntdevlabs** for creating and maintaining Tiny11
- **Eric Biggers** for wimlib development
- **UUP Dump community** for their service and tools
- **Microsoft** for providing official update channels
- **GNU/Linux community** for the amazing ecosystem
- **All open source contributors** whose tools make this possible

---

## 📜 License Acknowledgments

Win-Reboot-Project is released under the MIT License.

This project uses and integrates with:
- **wimlib**: Dual-licensed (GPLv3+ or LGPL)
- **aria2**: GPLv2+
- **p7zip**: LGPL
- **GRUB**: GPLv3+
- **UUP Dump scripts**: Community-maintained

All external tools retain their original licenses. Please refer to individual project documentation for licensing details.

---

## 🤝 Contributing Back

If Win-Reboot-Project helps you, please consider:

1. **Star this repository** and the [Tiny11 project](https://github.com/ntdevlabs/tiny11builder)
2. **Report bugs and suggest improvements** via GitHub issues
3. **Share your experience** with the community
4. **Contribute code** via pull requests
5. **Support the upstream projects** we depend on

---

**Last Updated**: January 1, 2026  
**Win-Reboot-Project Version**: 1.0.0
