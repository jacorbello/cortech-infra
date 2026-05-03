```mermaid
graph TD
  subgraph Proxmox_Cluster
    subgraph cortech [cortech (12c/188GiB)]
      lxc100[LXC 100 proxy]
      vm101[QEMU 101 homeassistant]
      lxc102[LXC 102 wireguard]:::stopped
      lxc103[LXC 103 wireguard-v2]
      lxc114[LXC 114 postgres]
      lxc116[LXC 116 redis]
      lxc119[LXC 119 legal-api]
      lxc120[LXC 120 uptime-kuma]
      lxc121[LXC 121 keycloak]
      lxc123[LXC 123 minio-01]
      lxc124[LXC 124 nomad]
      lxc125[LXC 125 timemachine]
      vm200[QEMU 200 k3s-srv-1]
      vm204[QEMU 204 k3s-wrk-2]
      vm9000[QEMU 9000 k3s-template]:::stopped
    end
    subgraph cortech-node1 [cortech-node1 (4c/30GiB)]
      vm201[QEMU 201 k3s-srv-2]
    end
    subgraph cortech-node2 [cortech-node2 (4c/30GiB)]
      vm202[QEMU 202 k3s-srv-3]
    end
    subgraph cortech-node3 [cortech-node3 (96c/566GiB) GPU]
      vm205[QEMU 205 ollama]:::stopped
      vm206[QEMU 206 k3s-wrk-3]
      vm207[QEMU 207 k3s-wrk-4]
    end
    subgraph cortech-node5 [cortech-node5 (8c/30GiB)]
      lxc112[LXC 112 n8n]
      vm203[QEMU 203 k3s-wrk-1]
    end
  end

classDef stopped fill:#eee,stroke:#999,stroke-dasharray: 3 3,color:#666;
lxc100 -->|"TLS + ingress"| public[Public *.corbello.io]
```
