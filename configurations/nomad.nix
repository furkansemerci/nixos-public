{ config, pkgs, ... }:


let
  jobsDir = ./nomad-jobs;
  varsDir = ./nomad-vars;

in
{
  services.nomad = {
    enable = true;
    dropPrivileges = false;
    enableDocker = true;
    
    extraSettingsPlugins = [ ];
    
    settings = {
      data_dir = "/opt/nomad/data";
      bind_addr = "0.0.0.0";
      
      acl = {
        enabled = true;
      };
      
      server = {
        enabled = true;
        bootstrap_expect = 1;
        server_join = {
          retry_join = [ "10.0.2.15:4648" ];
        };
      };
      
      client = {
        enabled = true;
        server_join = {
          retry_join = [ "10.0.2.15:4647" ];
        };

        host_volume."docker-sock-ro" = {
          path = "/var/run/docker.sock";
          read_only = true;
        };
        meta = {
          NODE = "node1";
        };
      };
      
      ui = {
        enabled = true;
        label = {
          text = "NixOSTest";
          background_color = "#c45940";
          text_color = "#effbff";
        };
      };
      
      plugin."docker" = {
        config = {
          allow_caps = [ "all" ];
          allow_privileged = true;
          volumes = {
            enabled = true;
          };
        };
      };
      
      plugin."raw_exec" = {
        config = {
          enabled = true;
        };
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d /opt/nomad/data 0755 nomad nomad -"
  ];

  networking.firewall = {
    allowedTCPPorts = [ 4646 4647 4648 ];
    allowedUDPPorts = [ 4648 ];
  };

  virtualisation.docker.enable = true;

  environment.etc = 
    builtins.listToAttrs(
     (map (name: {
        name = "nomad-jobs/${name}";
        value = { source = "${jobsDir}/${name}";};
      }) (builtins.attrNames (builtins.readDir jobsDir)))

      ++

      (map (name: {
        name = "nomad-vars/${name}";
        value = { source = "${varsDir}/${name}";};
      })(builtins.attrNames (builtins.readDir varsDir)))
    );


systemd.services.nomad-jobs = {
  description = "Deploy Nomad Jobs";
  after = [ "nomad.service" ];
  requires = [ "nomad.service" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    TimeoutStartSec = "5min";
  };
script = ''
  set -euo pipefail
  set -x
  
  NOMAD=${pkgs.nomad}/bin/nomad
  JQ=${pkgs.jq}/bin/jq
  CURL=${pkgs.curl}/bin/curl
  TOKEN_FILE=/var/lib/nomad/acl.env
  
  mkdir -p /var/lib/nomad
  
  echo "Waiting for Nomad service to be active..."
  for i in {1..30}; do
    if systemctl is-active --quiet nomad.service; then
      echo "Nomad service is active"
      break
    fi
    echo "Attempt $i/30: Waiting for Nomad service..."
    sleep 1
  done
  
  echo "Waiting for Nomad HTTP API to be ready..."
  for i in {1..60}; do
    if $CURL -sf http://127.0.0.1:4646/v1/agent/self >/dev/null 2>&1; then
      echo "Nomad HTTP API is ready"
      sleep 2 
      break
    fi
    echo "Attempt $i/60: Nomad API not ready yet..."
    sleep 1
  done
  
  # Check if we need to bootstrap
  if [ ! -f "$TOKEN_FILE" ] || [ ! -s "$TOKEN_FILE" ] || ! grep -q "^NOMAD_TOKEN=.\\+$" "$TOKEN_FILE"; then
    echo "Token file missing or invalid, attempting to bootstrap ACL..."
    
    # Try to bootstrap
    if BOOTSTRAP_OUTPUT=$($NOMAD acl bootstrap -json 2>&1); then
      echo "Bootstrap successful"
      TOKEN=$(echo "$BOOTSTRAP_OUTPUT" | $JQ -r .SecretID)
      
      if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
        echo "ERROR: Failed to extract token from bootstrap output"
        exit 1
      fi
      
      echo "NOMAD_TOKEN=$TOKEN" > "$TOKEN_FILE"
      chmod 600 "$TOKEN_FILE"
      echo "Saved new ACL token"
    else
      # Bootstrap failed - check if already bootstrapped
      if echo "$BOOTSTRAP_OUTPUT" | grep -qi "already"; then
        echo "ACL already bootstrapped but token file is missing/invalid"
        echo "Resetting Nomad ACL state..."
        
        systemctl stop nomad.service
        rm -rf /var/lib/nomad/server /opt/nomad/data/server
        systemctl start nomad.service
        
        echo "Waiting for Nomad to restart..."
        for i in {1..30}; do
          if systemctl is-active --quiet nomad.service; then
            echo "Nomad service restarted"
            break
          fi
          sleep 1
        done
        
        # Wait for API after restart
        echo "Waiting for Nomad API after restart..."
        for i in {1..60}; do
          if $CURL -sf http://127.0.0.1:4646/v1/agent/self >/dev/null 2>&1; then
            echo "Nomad API ready after restart"
            sleep 2
            break
          fi
          sleep 1
        done
        
        echo "Attempting bootstrap after reset..."
        BOOTSTRAP_OUTPUT=$($NOMAD acl bootstrap -json)
        TOKEN=$(echo "$BOOTSTRAP_OUTPUT" | $JQ -r .SecretID)
        
        if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
          echo "ERROR: Failed to extract token after reset"
          exit 1
        fi
        
        echo "NOMAD_TOKEN=$TOKEN" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        echo "Saved ACL token after reset"
      else
        echo "ERROR: Bootstrap failed with unexpected error"
        echo "$BOOTSTRAP_OUTPUT"
        exit 1
      fi
    fi
  else
    echo "Valid token file already exists"
  fi
  
  # Source the token
  source "$TOKEN_FILE"
  export NOMAD_TOKEN
  
  if [ -z "$NOMAD_TOKEN" ]; then
    echo "ERROR: NOMAD_TOKEN is empty"
    exit 1
  fi
  
  echo "Token loaded successfully"
  
  for v in /etc/nomad-vars/*; do
    if [ -f "$v" ]; then
      filename=$(basename "$v")
      name="''${filename%.*}"

      echo "Injecting var "$v""
      $NOMAD var put "nomad/jobs/$name" @"$v"
    fi 
  done
  

  # Deploy jobs
  for f in /etc/nomad-jobs/*; do
    if [ -f "$f" ]; then
      echo "Deploying $f"
      $NOMAD job run "$f"
    fi
  done


  echo "All jobs deployed successfully"
'';
};

}