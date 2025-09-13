```mermaid
graph TD
  subgraph Proxmox_Cluster
    subgraph cortech [cortech (12c/188.6GiB)]
      vm101[QEMU 101 homeassistant]
      lxc100[LXC 100 proxy]
      lxc102[LXC 102 wireguard]
      lxc105[LXC 105 minecraft-bedrock]
      lxc106[LXC 106 radarr]
      lxc107[LXC 107 qbittorrent]
      lxc108[LXC 108 jackett]
      lxc109[LXC 109 plex]
      lxc110[LXC 110 sonarr]
      lxc114[LXC 114 postgres]
      lxc116[LXC 116 redis]
      lxc118[LXC 118 gha-runner-trading]
    end
    subgraph cortech-node1 [cortech-node1 (4c/30.3GiB)]
      lxc113[(LXC 113 postal)]:::stopped
      lxc115[(LXC 115 infisical)]:::stopped
    end
    subgraph cortech-node2 [cortech-node2 (4c/30.3GiB)]
      lxc111[(LXC 111 wordpress-ff)]:::stopped
    end
    subgraph cortech-node3 [cortech-node3 (96c/566.2GiB) GPU]
      lxc103[(LXC 103 plotlens-ollama tmpl)]:::stopped
      lxc104[(LXC 104 plotlens-ollama tmpl)]:::stopped
    end
    subgraph cortech-node5 [cortech-node5 (8c/31.0GiB)]
      lxc112[(LXC 112 n8n)]:::stopped
    end
  end

classDef stopped fill:#eee,stroke:#999,stroke-dasharray: 3 3,color:#666;

lxc100 -->|"TLS + ingress"| public[Public *.corbello.io]
```
