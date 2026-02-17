{  config, pkgs, lib, ...  }:

let
  nodeName = "node1";
  nodeIp = "10.0.2.15";

  postgresqlVersion = "15";
  postgresDataDir = "/var/lib/postgresql/${postgresqlVersion}/main";
  postgresArchiveDir = "/var/lib/postgresql/${postgresqlVersion}/archive";
  
  patroniScope = "postgres-cluster";
  patroniNamespace = "/db";

  etcdDataDir = "/var/lib/etcd";
  etcdInitialClusterToken = "etcd-cluster-token";

  superuserUsername = "postgres";
  superuserPassword = "fes123";
  replicationUsername = "replicator";
  replicationPassword = "fes123";
  statsUsername = "fes";
  statsUserPassword = "fes123";
  databaseName = "fesdb";

  pgAdminEmail = "efe@gmail.com";
  pgAdminPassword = "fes123";

in{
  services.etcd = {
    enable = true;
    name = "${nodeName}";
    dataDir = etcdDataDir;
    initialCluster = ["${nodeName}=http://${nodeIp}:2380"];
    initialClusterState = "new";
    initialClusterToken = etcdInitialClusterToken;
    listenPeerUrls = ["http://0.0.0.0:2380"];
    listenClientUrls = ["http://${nodeIp}:2379"];
    initialAdvertisePeerUrls = ["http://${nodeIp}:2380"];
    advertiseClientUrls = ["http://${nodeIp}:2379"];
    extraConf = {
      "LOGGER" = "zap";
      "LOG_LEVEL" = "error";
      "LOG_OUTPUTS" = "/var/log/etcd/etcd.log";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/log/etcd 0755 etcd etcd -"
    "d /var/log/postgresql 0755 postgres postgres -"
    "d ${postgresArchiveDir} 0755 postgres postgres -"
    "d /var/local/pgadmin 0755 pgadmin pgadmin -"
    "d /var/run/postgresql 0755 postgres postgres -"
  ];

  environment.systemPackages = with pkgs; [
    etcd 
    postgresql_15
    python311
    patroni
    python311Packages.psycopg2
    python311Packages.python-etcd
    postgresql_15
  ];

  environment.etc."patroni.yml" = {
    text = ''
      scope: ${patroniScope}
      namespace: ${patroniNamespace}
      name: pg-${nodeName}

      restapi:
        listen: ${nodeIp}:8008
        connect_address: ${nodeIp}:8008

      log:
        type: json
        dir: /var/log/postgresql
        format:
          - message
          - module
          - funcName
          - process
          - thread
          - asctime: '@timestamp'
          - levelname: level
        static_fields:
          app: patroni

      etcd3:
        hosts: ${nodeIp}:2379

      bootstrap:
        dcs:
          ttl: 30
          loop_wait: 10
          retry_timeout: 10
          maximum_lag_on_failover: 1048576
          postgresql:
            use_pg_rewind: true
            parameters:
              wal_level: replica
              hot_standby: "on"
              wal_keep_segments: 64
              max_wal_senders: 11
              max_replication_slots: 5
              max_connections: 200

        initdb:
          - encoding: UTF8
          - data-checksums

        post_init: /etc/patroni-post-init.sh

      postgresql:
        listen: ${nodeIp}:5432
        connect_address: ${nodeIp}:5432
        data_dir: ${postgresDataDir}
        bin_dir: ${pkgs."postgresql_${postgresqlVersion}"}/bin
        authentication:
          replication:
            username: ${replicationUsername}
            password: ${replicationPassword}
          superuser:
            username: ${superuserUsername}
            password: ${superuserPassword}
        parameters:
          unix_socket_directories: "/var/run/postgresql"
          wal_log_hints: "on"
          archive_mode: "on"
          archive_command: "cp %p ${postgresArchiveDir}/%f"
          archive_timeout: 1800s
          shared_buffers: 8GB
          effective_cache_size: 24GB
          maintenance_work_mem: 2GB
          checkpoint_completion_target: 0.9
          wal_buffers: 16MB
          default_statistics_target: 100
          random_page_cost: 1.1
          effective_io_concurrency: 200
          work_mem: 15728kB
          huge_pages: try
          min_wal_size: 1GB
          max_wal_size: 4GB
          max_worker_processes: 12
          max_parallel_workers_per_gather: 4
          max_parallel_workers: 12
          max_parallel_maintenance_workers: 4
          logging_collector: on
          log_directory: '/var/log/postgresql'
          log_min_error_statement: NOTICE
          log_destination: 'stderr,jsonlog'
        pg_hba:
          - host all ${superuserUsername} all md5
          - host replication ${replicationUsername} all md5
          - host all ${statsUsername} all trust
          - host all postgres all trust
          - local all all trust
        create_replica_methods:
          - basebackup
        basebackup:
          max-rate: 100M
          checkpoint: fast

      tags:
        nofailover: false
        noloadbalance: false
        clonefrom: false
        nosync: false
    '';
  };

  environment.etc."patroni-post-init.sh" = {
    text = ''
      #!/bin/sh
      CONNECTION_STRING=$1
      ${pkgs."postgresql_${postgresqlVersion}"}/bin/psql "$CONNECTION_STRING" <<-EOSQL
        CREATE USER ${statsUsername} PASSWORD '${statsUserPassword}';
        GRANT pg_monitor TO ${statsUsername};
        CREATE DATABASE ${databaseName} WITH OWNER ${superuserUsername} ENCODING 'UTF8';
      EOSQL
      exit 0
    '';
    mode = "0755";
  };

  systemd.services.patroni = {
    description = "Patroni Postgresql HA";
    after = ["network.target" "etcd.service"];
    wants = ["etcd.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      User = "postgres";
      Group = "postgres";
      ExecStart = "${pkgs.patroni}/bin/patroni /etc/patroni.yml";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      KillMode = "mixed";
      KillSignal = "SIGINT";
      Restart = "on-failure";
      RestartSec = "10s";
      TimeoutSec = 0;
      RuntimeDirectory = "postgresql";
      RuntimeDirectoryMode = "0755";
      StateDirectory = "postgresql"; 
      StateDirectoryMode = "0700";
    };
  };

  systemd.services.postgresql.enable = lib.mkForce false;

  virtualisation.docker.enable = true;

  systemd.services.pgadmin = {
    description = "pgAdmin 4";
    after = ["docker.service" "network.target"];
    requires = ["docker.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = [
        "-${pkgs.docker}/bin/docker stop pgadmin4"
        "-${pkgs.docker}/bin/docker rm pgadmin4"
      ];
      ExecStart = ''${pkgs.docker}/bin/docker run -d \
      --name pgadmin4 \
      --restart unless-stopped \
      -p 8090:80 \
      -e PGADMIN_DEFAULT_EMAIL=${pgAdminEmail} \
      -e PGADMIN_DEFAULT_PASSWORD=${pgAdminPassword} \
      -v /var/local/pgadmin:/var/lib/pgadmin \
      dpage/pgadmin4
      '';
      ExecStop = "${pkgs.docker}/bin/docker stop pgadmin4";
    };
  };

  users.users.pgadmin = {
    isSystemUser = true;
    group = "pgadmin";
  };

  users.groups.pgadmin = {};

  users.users.postgres = {
  isSystemUser = true;
  group = "postgres";
  home = "/var/lib/postgresql";
  };

  users.groups.postgres = {};


}