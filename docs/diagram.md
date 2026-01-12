```mermaid
graph TD
  subgraph Proxmox_Cluster
    subgraph cortech [cortech (12c/188GiB)]
      lxc100[LXC 100 proxy]
      vm101[QEMU 101 homeassistant]
      lxc102[LXC 102 wireguard]
      lxc105[LXC 105 minecraft-bedrock]
      lxc114[LXC 114 postgres]
      lxc116[LXC 116 redis]
      lxc117[LXC 117 gha-runner-personal]:::stopped
      lxc118[LXC 118 gha-runner-trading]
      lxc119[LXC 119 legal-api]
      lxc120[LXC 120 ai-trader]
      lxc121[LXC 121 jarvis]
      lxc122[LXC 122 jarvis-obs]
      lxc123[LXC 123 minio-01]
      lxc124[LXC 124 dify-01]
    end
    subgraph cortech-node1 [cortech-node1 (4c/30GiB)]
      lxc113[LXC 113 postal]:::stopped
      lxc115[LXC 115 infisical]:::stopped
    end
    subgraph cortech-node2 [cortech-node2 (4c/30GiB)]
      lxc111[LXC 111 wordpress-ff]:::stopped
    end
    subgraph cortech-node3 [cortech-node3 (nullc/0GiB) GPU]
      lxc103[LXC 103 null]:::stopped
      lxc104[LXC 104 null]:::stopped
    end
    subgraph cortech-node5 [cortech-node5 (8c/30GiB)]
      lxc112[LXC 112 n8n]
    end
  end

classDef stopped fill:#eee,stroke:#999,stroke-dasharray: 3 3,color:#666;
lxc100 -->|"TLS + ingress"| public[Public *.corbello.io]
```
