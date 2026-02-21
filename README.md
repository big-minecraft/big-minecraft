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
- **Persistent Storage** - Support for various storage backends (Longhorn, NFS, CephFS)

## Quick Start

### Prerequisites

- Kubernetes cluster (1.25+)
- kubectl, helm, helmfile
- [Task](https://taskfile.dev) - Modern task runner

### Installation

```bash
# 1. Install Task (if not already installed)
brew install go-task/tap/go-task  # macOS
# or: sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d

# 2. Initialize configuration
task config:init

# 3. Edit configuration with your settings
nano charts/bmc-chart/values.custom.yaml

# 4. Generate secrets
task secrets:generate

# 5. Install BMC
task install
```

Access the panel at your configured domain and use the invite code from step 4.

**For detailed installation instructions, see [INSTALL.md](INSTALL.md)**

## Architecture

### Components

**Infrastructure Layer (Kubernetes):**
- Helm charts for deployment definitions
- Custom Resource Definitions (CRDs) for GameServers
- Persistent volume management
- Load balancing (MetalLB or cloud-native)

**Application Layer:**
- **BMC Panel** - React 19 + TypeScript web interface
- **BMC Manager** - Node.js backend orchestration service
- **Redis** - Real-time coordination and messaging
- **MariaDB** - SQL database for structured data
- **MongoDB** - NoSQL database for flexible storage
- **Prometheus** - Metrics collection (optional)

**Deployment Types:**
- **Persistent** - Long-lived single server instances
- **Scalable** - Auto-scaling server pools
- **Proxy** - Player queue and lobby servers
- **Process** - Lightweight single-process instances

### Technology Stack

**Backend:**
- Node.js 18+ with TypeScript
- Express.js REST API
- Socket.io for real-time updates
- Pulumi for infrastructure as code
- Kubernetes client libraries

**Frontend:**
- React 19 with TypeScript
- Vite build system
- Tailwind CSS styling
- Monaco editor for file editing
- Recharts for metrics visualization

**Infrastructure:**
- Kubernetes + Helm + Helmfile
- Traefik ingress controller
- cert-manager for TLS certificates
- Longhorn for persistent storage

## Project Structure

```
big-minecraft/
├── Taskfile.yml                   # Task orchestration
├── helmfile.yaml                  # Helm release management
├── INSTALL.md                     # Installation guide
├── scripts/                       # Helper scripts
│   ├── detect-dependencies.sh     # Auto-detect K8s components
│   ├── validate-config.sh         # Configuration validation
│   ├── check-secrets.sh           # Secret verification
│   └── generate-secrets.sh        # Secret generation
├── charts/
│   └── bmc-chart/                 # Main Helm chart
│       ├── values.yaml            # Default values
│       ├── values.example.yaml    # Configuration template
│       ├── templates/             # K8s resource templates
│       └── Chart.yaml
└── chart-templates/               # Deployment type templates
    ├── persistent-deployment-chart/
    ├── scalable-deployment-chart/
    ├── proxy-chart/
    └── process-chart/
```

## Available Tasks

```bash
task verify          # Verify prerequisites
task config:init     # Initialize configuration
task secrets:generate # Generate secrets
task install         # Complete installation
task status          # Show installation status
task logs            # View panel logs
task restart         # Restart services
task uninstall       # Remove installation
task help            # Show all tasks
```

## Configuration

BMC uses a layered configuration approach:

1. **values.yaml** - Safe defaults (committed to git)
2. **values.auto.yaml** - Auto-detected (generated)
3. **values.custom.yaml** - Your settings (gitignored)

Edit `values.custom.yaml` to configure:
- Domain names
- Let's Encrypt email
- Load balancer IPs
- Storage classes
- Volume sizes

See [values.example.yaml](charts/bmc-chart/values.example.yaml) for all options.

## Management Panel

The BMC panel provides:

- **Dashboard** - Overview of all deployments and metrics
- **Deployment Manager** - Create, edit, delete server deployments
- **File Browser** - Upload, download, edit server files
- **Database Manager** - Create and manage SQL/NoSQL databases
- **User Management** - Invite users, manage permissions
- **Monitoring** - Real-time CPU, memory, player counts
- **Console** - Direct server console access

## Documentation

- [Installation Guide](INSTALL.md) - Complete installation instructions
- [Configuration Reference](charts/bmc-chart/values.example.yaml) - All configuration options
- Panel Documentation - Available in the web interface

## Support

For issues, questions, or contributions:
- GitHub Issues - Report bugs or request features
- Pull Requests - Contributions welcome

## License

[Your License Here]

## Related Projects

- **bmc-panel** - Web interface repository (separate project)
- Panel location: `/Users/elliott/Desktop/k8s3/bmc-panel`

---

**Ready to get started? See [INSTALL.md](INSTALL.md) for detailed installation instructions.**
