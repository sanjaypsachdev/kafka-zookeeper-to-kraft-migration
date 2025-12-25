# Mermaid Diagrams for Kafka Architecture

This file contains the Mermaid diagram code for generating the architecture diagrams used in the README.

## ZooKeeper-Based Architecture (Legacy)

Save this as `kafka-zookeeper-architecture.jpg`:

```mermaid
graph TB
    subgraph "OpenShift Namespace"
        subgraph "Kafka Resource"
            KR[Kafka Resource<br/>Cluster Configuration]
        end
        
        subgraph "ZooKeeper Cluster"
            ZK1[ZooKeeper Pod 1]
            ZK2[ZooKeeper Pod 2]
            ZK3[ZooKeeper Pod 3]
        end
        
        subgraph "Kafka Brokers"
            B1[Kafka Broker Pod 1]
            B2[Kafka Broker Pod 2]
            B3[Kafka Broker Pod 3]
        end
        
        KR -->|Manages| ZK1
        KR -->|Manages| ZK2
        KR -->|Manages| ZK3
        KR -->|Manages| B1
        KR -->|Manages| B2
        KR -->|Manages| B3
        
        B1 -.->|Metadata Operations| ZK1
        B2 -.->|Metadata Operations| ZK2
        B3 -.->|Metadata Operations| ZK3
        
        ZK1 <-->|Consensus| ZK2
        ZK2 <-->|Consensus| ZK3
        ZK3 <-->|Consensus| ZK1
    end
    
    style ZK1 fill:#ffcccc
    style ZK2 fill:#ffcccc
    style ZK3 fill:#ffcccc
    style B1 fill:#cce5ff
    style B2 fill:#cce5ff
    style B3 fill:#cce5ff
    style KR fill:#e6f3ff
```

## KRaft-Based Architecture (Modern)

Save this as `kafka-kraft-architecture.jpg`:

```mermaid
graph TB
    subgraph "OpenShift Namespace"
        subgraph "Kafka Resource"
            KR2[Kafka Resource<br/>Cluster Configuration]
        end
        
        subgraph "Controller Node Pool"
            CP[KafkaNodePool<br/>Role: Controller]
            C1[Controller Pod 1]
            C2[Controller Pod 2]
            C3[Controller Pod 3]
        end
        
        subgraph "Broker Node Pool"
            BP[KafkaNodePool<br/>Role: Broker]
            B1N[Broker Pod 1]
            B2N[Broker Pod 2]
            B3N[Broker Pod 3]
        end
        
        KR2 -->|Manages| CP
        KR2 -->|Manages| BP
        
        CP -->|Manages| C1
        CP -->|Manages| C2
        CP -->|Manages| C3
        
        BP -->|Manages| B1N
        BP -->|Manages| B2N
        BP -->|Manages| B3N
        
        B1N -.->|Metadata Operations| C1
        B2N -.->|Metadata Operations| C2
        B3N -.->|Metadata Operations| C3
        
        C1 <-->|Raft Consensus| C2
        C2 <-->|Raft Consensus| C3
        C3 <-->|Raft Consensus| C1
    end
    
    style C1 fill:#ccffcc
    style C2 fill:#ccffcc
    style C3 fill:#ccffcc
    style B1N fill:#cce5ff
    style B2N fill:#cce5ff
    style B3N fill:#cce5ff
    style CP fill:#e6ffe6
    style BP fill:#e6f3ff
    style KR2 fill:#e6f3ff
```

## How to Generate JPG Files

### Option 1: Using Mermaid Live Editor (Online)
1. Go to https://mermaid.live/
2. Paste one of the Mermaid code blocks above (without the markdown code fences)
3. Click "Download PNG" or use a screenshot tool to save as JPG
4. Save as `kafka-zookeeper-architecture.jpg` or `kafka-kraft-architecture.jpg` in the `images/` directory

### Option 2: Using Mermaid CLI
```bash
# Install Mermaid CLI
npm install -g @mermaid-js/mermaid-cli

# Generate images
mmdc -i mermaid-diagrams.md -o images/kafka-zookeeper-architecture.jpg -t dark
mmdc -i mermaid-diagrams.md -o images/kafka-kraft-architecture.jpg -t dark
```

### Option 3: Using VS Code Extension
1. Install the "Markdown Preview Mermaid Support" extension
2. Open this file in VS Code
3. Use the preview to view the diagrams
4. Export or screenshot the diagrams as JPG files

### Option 4: Using Online Converters
- https://mermaid.ink/ - Paste the code and download as image
- https://kroki.io/ - Supports Mermaid and can export as JPG

