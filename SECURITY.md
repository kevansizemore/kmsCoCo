# Security Policy

## Scope & Nature of the Project

`kmsCoCo` is an open-source software emulator replicating the vintage 1980s **Tandy Color Computer (CoCo 1)** on modern operating systems.

## Handling Security Concerns (Fork-First Model)

As detailed in [CONTRIBUTING.md](CONTRIBUTING.md), this repository has issues, discussions, and pull requests disabled:

1. **Remediation via Forking**: If you identify a security issue, parsing vulnerability (e.g. in `.cas` or `.dsk` handlers), or memory defect, you are encouraged to patch it directly within your own fork under the [GNU GPLv3](LICENSE).
2. **Upstream Vulnerabilities**: If the issue exists in upstream core emulation or common components, consider reporting it directly upstream to [XRoar](https://www.6809.org.uk/xroar/).
3. **Private Disclosure**: If GitHub Private Vulnerability Reporting is accessible on [github.com/kevansizemore/kmsCoCo](https://github.com/kevansizemore/kmsCoCo), findings may be submitted there. However, the maintainer maintains no service level agreement or commitment to review or remediate reports.

## Disclaimer

As outlined in [CONTRIBUTING.md](CONTRIBUTING.md) and [LICENSE](LICENSE), this software is provided strictly on an **"AS IS"** and **"AS AVAILABLE"** basis without warranty, fitness guarantee, or security guarantee of any kind.
