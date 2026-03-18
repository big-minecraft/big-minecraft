# Big Minecraft (BMC) - Kubernetes Orchestrator

A complete Kubernetes-based orchestration platform for managing Minecraft server networks at scale.

## Features

- **Multi-Deployment Management** - Run multiple Minecraft servers with different configurations
- **Auto-Scaling** - Scalable deployments that distribute players automatically
- **Web Panel** - Full-featured management interface with real-time monitoring
- **File Management** - Built-in SFTP and web-based file browser
- **Database Management** - Integrated MariaDB and MongoDB with GUI management
- **User Management** - Multi-user support with roles and 2FA authentication
- **Real-time Metrics** - Live CPU, memory, and player count monitoring

---
## Quick Start

### Prerequisites

- Kubernetes cluster (1.25+)
- nfs-common installed on each node in the cluster
- kubectl, helm, helmfile
- A domain pointing at the entrypoint IP for your cluster
- [Task](https://taskfile.dev) - Modern task runner
### Installation

Firstly, ensure you have all of the prerequisites stated above properly installed.

Next, run the following command to generate the setup config file.

```bash
task config:init
```
Fill out `values.custom.json`, ensuring that you change all required values.

Next, run the following command to generate the secrets for BMC.
```bash
task secrets:generate
```

Make sure to save these values to a secure place. Pay special attention to your `Initial Invite Code`.

Next, install BMC with the following command.
```bash
task install
```
Access the panel at your configured domain and use the previously obtained invite code.

---
## Available Tasks

```bash
task verify          # Verify prerequisites
task config:init     # Initialize configuration
task secrets:generate # Generate secrets
task install         # Complete installation
task uninstall       # Remove installation
task help            # Show all tasks
```
---
## Support

For issues, questions, or contributions:
- GitHub Issues - Report bugs or request features
- Pull Requests - Contributions welcome