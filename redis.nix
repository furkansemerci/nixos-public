{ config, lib, pkgs, ... }:
let
  redisPassword = "fes123!";
  masterName = "fes";
  
  sentinelConf = pkgs.writeText "sentinel.conf" ''
    port 26379
    bind 0.0.0.0
    daemonize no
    pidfile /run/redis-sentinel/redis-sentinel.pid
    logfile /var/lib/redis-sentinel/sentinel.log
    dir /var/lib/redis-sentinel
    
    # Sentinel Monitoring Logic
    sentinel monitor ${masterName} 127.0.0.1 6379 1
    sentinel auth-pass ${masterName} ${redisPassword}
    sentinel down-after-milliseconds ${masterName} 5000
    sentinel failover-timeout ${masterName} 60000
    sentinel parallel-syncs ${masterName} 1
  '';
in
{
  environment.systemPackages = [ pkgs.redis ];

  # REDIS MASTER 
  services.redis.servers."master" = {
    enable = true;
    port = 6379;
    bind = "0.0.0.0"; 
    openFirewall = true;
    requirePass = redisPassword;
    settings = {
      appendonly = "yes";
      appendfilename = "appendonly.aof";
      loglevel = "notice";
      dbfilename = "dump.rdb";
      masterauth = redisPassword;
    };
  };

  # REDIS SENTINEL
  systemd.services.redis-sentinel = {
    description = "Redis Sentinel";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "redis-master.service" ];
    
    preStart = ''
      # Create log file if it doesn't exist
      touch /var/lib/redis-sentinel/sentinel.log
      chown redis-master:redis-master /var/lib/redis-sentinel/sentinel.log
      chmod 640 /var/lib/redis-sentinel/sentinel.log
      
      # Copy the sentinel config to a writable location
      # Sentinel needs to rewrite its config file
      cp ${sentinelConf} /var/lib/redis-sentinel/sentinel.conf
      chown redis-master:redis-master /var/lib/redis-sentinel/sentinel.conf
      chmod 640 /var/lib/redis-sentinel/sentinel.conf
    '';
    
    serviceConfig = {
      Type = "simple";
      User = "redis-master";
      Group = "redis-master";
      # Use the writable copy instead of the nix store version
      ExecStart = "${pkgs.redis}/bin/redis-server /var/lib/redis-sentinel/sentinel.conf --sentinel";
      Restart = "always";
      RestartSec = "5s";
      RuntimeDirectory = "redis-sentinel";
      StateDirectory = "redis-sentinel";
      # Ensure proper permissions
      StateDirectoryMode = "0750";
    };
  };

  networking.firewall.allowedTCPPorts = [ 6379 26379 ];
}