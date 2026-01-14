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
      lxc119[LXC 119 legal-api]
      lxc123[LXC 123 minio-01]
      vm200[QEMU 200 k3s-srv-1]:::k3s
      vm204[QEMU 204 k3s-wrk-2]:::k3s
    end
    subgraph cortech-node1 [cortech-node1 (4c/30GiB)]
      lxc113[LXC 113 postal]:::stopped
      lxc115[LXC 115 infisical]:::stopped
      vm201[QEMU 201 k3s-srv-2]:::k3s
    end
    subgraph cortech-node2 [cortech-node2 (4c/30GiB)]
      lxc111[LXC 111 wordpress-ff]:::stopped
      vm202[QEMU 202 k3s-srv-3]:::k3s
    end
    subgraph cortech-node3 [cortech-node3 (96c/566GiB) GPU offline]
      node3empty[No guests]:::empty
    end
    subgraph cortech-node5 [cortech-node5 (8c/30GiB)]
      lxc112[LXC 112 n8n]
      vm203[QEMU 203 k3s-wrk-1]:::k3s
    end
  end

  subgraph K3s_Cluster [K3s Cluster - 192.168.1.90 VIP]
    k3sapi[API VIP :6443]
    vm200 --> k3sapi
    vm201 --> k3sapi
    vm202 --> k3sapi
    vm203 -.-> k3sapi
    vm204 -.-> k3sapi
  end

classDef stopped fill:#eee,stroke:#999,stroke-dasharray: 3 3,color:#666;
classDef empty fill:#fff,stroke:#ccc,stroke-dasharray: 2 2,color:#999;
classDef k3s fill:#326ce5,stroke:#fff,color:#fff;
lxc100 -->|"TLS + ingress"| public[Public *.corbello.io]
k3sapi -->|"Rancher/Grafana"| lxc100
```
