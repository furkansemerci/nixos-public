{ config, lib, pkgs, ... }:

let
  cfg = config.services.my-clickhouse;
  
  # Configuration Variables (formerly Nomad Vars)
  clusterName = "production_cluster";
  dbName = "logs_db";
  defaultPasswordSha256 = "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8"; # Example: "password"
  
  # Define your topology here (Static list instead of dynamic service discovery)
  # In a real setup, you might pass this via specialArgs or a higher-level module.
  clusterNodes = [
    { id = 1; host = "10.0.2.16"; port = 9000; raftPort = 9234; }
    { id = 2; host = "10.0.2.17"; port = 9000; raftPort = 9234; }
    { id = 3; host = "10.0.2.18"; port = 9000; raftPort = 9234; }
  ];

  # Determine if we are in clustered mode
  isCluster = (builtins.length clusterNodes) > 1;

  # Helper to find current node config based on networking.hostName or IP
  myNode = lib.findFirst (n: n.host == "10.0.0.1") (builtins.head clusterNodes) clusterNodes; 
  # ^ TODO: Replace "10.0.0.1" with dynamic check or config.networking.hostName logic

in {
  options.services.my-clickhouse = {
    enable = lib.mkEnableOption "Custom ClickHouse Setup";
  };

  config = lib.mkIf cfg.enable {
    
    # 1. Open Firewall Ports
    networking.firewall.allowedTCPPorts = [ 8123 9000 9009 9234 ];

    # 2. Main ClickHouse Service
    services.clickhouse = {
      enable = true;
      package = pkgs.clickhouse; # Or specific version
      
      # Users XML generation
      users = {
        default = {
          password_sha256_hex = defaultPasswordSha256;
          networks = { ip = "::/0"; };
          profile = "default";
          quota = "default";
          access_management = 1;
        };
      };

      # Config.xml generation (The "settings" attr set maps to XML tags)
      settings = {
        logger = {
          level = "debug";
          log = "/var/log/clickhouse/server.log";
          errorlog = "/var/log/clickhouse/error.log";
          size = "1000M";
          count = 3;
        };

        http_port = 8123;
        tcp_port = 9000;
        interserver_http_port = 9009;
        listen_host = "0.0.0.0";

        # Resources
        mark_cache_size = 268435456;
        index_mark_cache_size = 67108864;
        
        # MergeTree Settings
        merge_tree = {
          merge_max_block_size = 1024;
          max_bytes_to_merge_at_max_space_in_pool = 1073741824;
          number_of_free_entries_in_pool_to_lower_max_size_of_merge = 2;
        };

        # Macros for ReplicatedMergeTree
        macros = lib.mkIf isCluster {
          shard = "01";
          replica = "${toString myNode.id}"; 
          cluster = clusterName;
        };

        # Remote Servers (Cluster Topology)
        remote_servers = lib.mkIf isCluster {
          "${clusterName}" = {
            shard = {
              internal_replication = true;
              replica = map (node: {
                host = node.host;
                port = node.port;
              }) clusterNodes;
            };
          };
        };

        # ClickHouse Keeper (ZooKeeper replacement)
        keeper_server = lib.mkIf isCluster {
          tcp_port = myNode.raftPort;
          server_id = myNode.id;
          log_storage_path = "/var/lib/clickhouse/coordination/log";
          snapshot_storage_path = "/var/lib/clickhouse/coordination/snapshots";
          
          raft_configuration = {
            server = map (node: {
              id = node.id;
              hostname = node.host;
              port = node.raftPort;
            }) clusterNodes;
          };
        };

        # Tell ClickHouse to use the local Keeper
        zookeeper = lib.mkIf isCluster {
          node = map (node: {
            host = node.host;
            port = node.raftPort;
          }) clusterNodes;
        };
      };
    };

    # 3. Initialization Script (Replaces initdb.sh)
    # This runs ONCE when the system starts to ensure tables exist.
    systemd.services.clickhouse-init-tables = {
      description = "Initialize ClickHouse Tables";
      after = [ "clickhouse.service" ];
      requires = [ "clickhouse.service" ];
      wantedBy = [ "multi-user.target" ];
      
      # Restart logic in case ClickHouse isn't ready immediately
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "10s";
      };

      script = let
        engine = if isCluster then "ReplicatedMergeTree" else "MergeTree";
        # Helper to construct the SQL. 
        # Note: In Nix, multiline strings '' ... '' are very convenient.
        initSql = pkgs.writeText "init.sql" ''
          CREATE DATABASE IF NOT EXISTS ${dbName} ${lib.optionalString isCluster "ON CLUSTER ${clusterName}"};

          -- System Logs Table
          CREATE TABLE IF NOT EXISTS ${dbName}.system_logs ${lib.optionalString isCluster "ON CLUSTER ${clusterName}"} (
            timestamp DateTime,
            time DateTime64(3, 'Asia/Istanbul'),
            message String,
            level String
            -- ... (Add all your other columns from the Nomad file here)
          )
          ENGINE = ${engine}
          ORDER BY (toUnixTimestamp64Nano(time))
          TTL timestamp + INTERVAL 6 MONTH;

          -- Service Logs Table
          CREATE TABLE IF NOT EXISTS ${dbName}.service_logs ${lib.optionalString isCluster "ON CLUSTER ${clusterName}"} (
            time DateTime64(3, 'UTC'),
            tenant_id String,
            message String
            -- ... (Add all your other columns here)
          )
          ENGINE = ${engine}
          PARTITION BY (tenant_id, toDate(time))
          ORDER BY (toUnixTimestamp64Nano(time));

          -- Distributed Tables (Only if clustered)
          ${lib.optionalString isCluster ''
          CREATE TABLE IF NOT EXISTS ${dbName}.system_logs_dist ON CLUSTER ${clusterName} 
          AS ${dbName}.system_logs
          ENGINE = Distributed('${clusterName}', '${dbName}', 'system_logs', rand());

          CREATE TABLE IF NOT EXISTS ${dbName}.service_logs_dist ON CLUSTER ${clusterName} 
          AS ${dbName}.service_logs
          ENGINE = Distributed('${clusterName}', '${dbName}', 'service_logs', rand());
          ''}
        '';
      in ''
        # Wait for ClickHouse to be ready
        until ${pkgs.curl}/bin/curl -sS --fail http://localhost:8123/ping; do
          echo "Waiting for ClickHouse..."
          sleep 2
        done

        echo "ClickHouse is up. Applying schema..."
        ${pkgs.clickhouse}/bin/clickhouse-client --host 127.0.0.1 --query="$(cat ${initSql})"
      '';
    };
  };
}