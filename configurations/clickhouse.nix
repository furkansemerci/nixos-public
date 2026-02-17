{ config, lib, pkgs, ... }:

let
  # CLUSTER VARIABLES (Single Node Config)
  clusterName = "fes_cluster";
  dbName = "logs_db";
  defaultPassword = "fes123!";
  defaultPasswordSha256 = "0f7879ad25d83c9ce566f4c73217f618550b50f0a75065b9b1c7da58dd38e591"; 

  # Note: keeperPort (9181) is added to separate it from raftPort (9234)
  clusterNodes = [
    { id = 1; host = "10.0.2.15"; port = 9000; raftPort = 9234; keeperPort = 9181; }
  ];

  # FORCE CLUSTER MODE:
  # We set this to true so we use ReplicatedMergeTree and keeper even on a single node
  # This makes it easier to expand to 3 nodes later without migrating data
  isCluster = true; 
  
  myNode = lib.findFirst (n: n.host == "10.0.2.15") (builtins.head clusterNodes) clusterNodes;

  cfg = config.services.my-clickhouse;

in {
  
  # MODULE INTERFACE
  options.services.my-clickhouse = {
    enable = lib.mkEnableOption "Custom ClickHouse Setup";

    package = lib.mkPackageOption pkgs "clickhouse" {
      example = "pkgs.clickhouse";
    };
  };

  # IMPLEMENTATION
  config = lib.mkIf cfg.enable {

    # Service Implementation
    
    users.users.clickhouse = {
      isSystemUser = true;
      group = "clickhouse";
      description = "ClickHouse server user";
    };
    users.groups.clickhouse = {};

    systemd.services.clickhouse = {
      description = "ClickHouse server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      
      serviceConfig = {
        Type = "notify";
        User = "clickhouse";
        Group = "clickhouse";
        
        # Directories
        StateDirectory = "clickhouse";          # /var/lib/clickhouse
        LogsDirectory = "clickhouse";           # /var/log/clickhouse
        RuntimeDirectory = "clickhouse-server"; # /run/clickhouse-server
        
        # Force Permissions (Crucial fix for crash 56/233)
        ExecStartPre = "+${pkgs.coreutils}/bin/chown -R clickhouse:clickhouse /var/log/clickhouse /var/lib/clickhouse";

        # Start with explicit Config and PID file
        ExecStart = "${cfg.package}/bin/clickhouse-server --config-file=/etc/clickhouse-server/config.xml --pid-file=/run/clickhouse-server/clickhouse-server.pid";
        
        TimeoutStartSec = "infinity";
        LimitNOFILE = 262144;
        Restart = "on-failure";
        RestartSec = "30s";

        MemoryMax = "1G";
        CPUQuota = "100%";
        TasksMax = 1032;
      };
    };

    environment.etc = {
      # Base config.xml from package
      "clickhouse-server/config.xml".source = "${cfg.package}/etc/clickhouse-server/config.xml";
      
      "clickhouse-server/users.xml".text = ''
        <?xml version="1.0"?>
        <clickhouse>
          <profiles>
            <default>
              <max_memory_usage>10000000000</max_memory_usage>
              <use_uncompressed_cache>0</use_uncompressed_cache>
              <load_balancing>random</load_balancing>
            </default>
          </profiles>

          <quotas>
            <default>
              <interval>
                <duration>3600</duration>
                <queries>0</queries>
                <errors>0</errors>
                <result_rows>0</result_rows>
                <read_rows>0</read_rows>
                <execution_time>0</execution_time>
              </interval>
            </default>
          </quotas>

          <users>
            <default>
              <password_sha256_hex>${defaultPasswordSha256}</password_sha256_hex>
              <networks>
                <ip>::/0</ip>
              </networks>
              <profile>default</profile>
              <quota>default</quota>
              <access_management>1</access_management>
            </default>
          </users>
        </clickhouse>
      '';
      
      # Server configuration override
      "clickhouse-server/config.d/nixos-config.xml".text = ''
        <?xml version="1.0"?>
        <clickhouse>
          <logger>
            <level>debug</level>
            <log>/var/log/clickhouse/server.log</log>
            <errorlog>/var/log/clickhouse/error.log</errorlog>
            <size>1000M</size>
            <count>3</count>
          </logger>

          <default_replica_path>/clickhouse/tables/{shard}/{database}/{table}</default_replica_path>
          <default_replica_name>{replica}</default_replica_name>
          
          <pid_file>/run/clickhouse-server/clickhouse-server.pid</pid_file>

          <http_port>8123</http_port>
          <tcp_port>9000</tcp_port>
          <interserver_http_port>9009</interserver_http_port>
          <listen_host>0.0.0.0</listen_host>

          <mark_cache_size>268435456</mark_cache_size>
          <index_mark_cache_size>67108864</index_mark_cache_size>

          <merge_tree>
            <merge_max_block_size>1024</merge_max_block_size>
            <max_bytes_to_merge_at_max_space_in_pool>1073741824</max_bytes_to_merge_at_max_space_in_pool>
            <number_of_free_entries_in_pool_to_lower_max_size_of_merge>2</number_of_free_entries_in_pool_to_lower_max_size_of_merge>
          </merge_tree>

          ${lib.optionalString isCluster ''
          <macros>
            <shard>01</shard>
            <replica>${toString myNode.id}</replica>
            <cluster>${clusterName}</cluster>
          </macros>

          <remote_servers>
            <${clusterName}>
              <shard>
                <internal_replication>true</internal_replication>
                ${lib.concatMapStrings (node: ''
                <replica>
                  <host>${node.host}</host>
                  <port>${toString node.port}</port>
                </replica>
                '') clusterNodes}
              </shard>
            </${clusterName}>
          </remote_servers>

          <keeper_server>
            <tcp_port>${toString myNode.keeperPort}</tcp_port>
            <server_id>${toString myNode.id}</server_id>
            <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
            <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>

            <raft_configuration>
              <server>
                <id>1</id>
                <hostname>127.0.0.1</hostname>
                <port>${toString myNode.raftPort}</port>
              </server>
            </raft_configuration>
          </keeper_server>

          <zookeeper>
            <node>
              <host>127.0.0.1</host>
              <port>${toString myNode.keeperPort}</port>
            </node>
          </zookeeper>
          ''}
        </clickhouse>
      '';
    };

    environment.systemPackages = [ cfg.package ];
    networking.firewall.allowedTCPPorts = [ 8123 9000 9009 9234 9181 ];

    # Initialization Script
    systemd.services.clickhouse-init-tables = {
      description = "Initialize ClickHouse Tables";
      after = [ "clickhouse.service" ];
      requires = [ "clickhouse.service" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "10s";
      };

      script = let
        engine = if isCluster 
                 then "ReplicatedMergeTree" 
                 else "MergeTree";
                 
        initSql = pkgs.writeText "init.sql" ''
          CREATE DATABASE IF NOT EXISTS ${dbName} ${lib.optionalString isCluster "ON CLUSTER ${clusterName}"};

          CREATE TABLE IF NOT EXISTS ${dbName}.system_logs ${lib.optionalString isCluster "ON CLUSTER ${clusterName}"} (
            timestamp DateTime,
            time DateTime64(3, 'Asia/Istanbul'),
            message String,
            level String
          )
          ENGINE = ${engine}
          ORDER BY (toUnixTimestamp64Nano(time))
          TTL timestamp + INTERVAL 6 MONTH;

          CREATE TABLE IF NOT EXISTS ${dbName}.service_logs ${lib.optionalString isCluster "ON CLUSTER ${clusterName}"} (
            time DateTime64(3, 'UTC'),
            tenant_id String,
            message String
          )
          ENGINE = ${engine}
          PARTITION BY (tenant_id, toDate(time))
          ORDER BY (toUnixTimestamp64Nano(time));

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
        until ${pkgs.curl}/bin/curl -sS --fail http://localhost:8123/ping; do
          echo "Waiting for ClickHouse..."
          sleep 2
        done
        echo "ClickHouse is up. Applying schema..."
        ${cfg.package}/bin/clickhouse-client --host 127.0.0.1 --user default --password ${defaultPassword} --query="$(cat ${initSql})"
      '';
    };
  };
}