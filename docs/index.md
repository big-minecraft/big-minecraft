# Big Minecraft
Welcome to the Big Minecraft documentation.

## Rationale
We created Big-Minecraft to serve as an out-of-the box minecraft network to quickly host our random minecraft projects at scale. Because of this, it is important to fundamentally understand what BMC is and what it is not. 

**What BMC is:**
- A way to easily scale gamemodes with ephemeral instances on a managed network
- A way to deploy an auto-scaling game to bare metal or a cloud provider
- A local testing environment for spinning up temporary networks

**What BMC is NOT:**
- A way to a single server
- A way to host multiple non-connected servers 
- A way to host a network of servers exclusively requiring persistent data storage
- A way to provide minecraft servers to paying customers

--- 

At its core, Big-Minecraft is a **fully-managed** environment. This means it ships with additional software that is often needed and used to host larger networks.

This currently includes:
- MariaDB
- MongoDB
- Redis
- SFTP Server

It also means that a majority of these tools can be accessed from **our custom web panel** for ease of use.
This can be useful if you need in depth access to minecraft server files and configuration as a person with minimal networking and/or command line knowledge.

---
With all of this in mind, if you still feel that BMC fits your needs, feel free to proceed to installation. 

