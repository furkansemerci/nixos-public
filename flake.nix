{
  description = "Fes Automated Installer";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko, ... }: 
  let
    system = "x86_64-linux";
    
    # 1. The Final System (What ends up installed on disk)
    mySystem = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        disko.nixosModules.disko
        ./configuration.nix
        ./disk-config.nix
      ];
    };

    # 2. The Installer ISO (The tool that installs the system)
    installIso = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
        disko.nixosModules.disko
        ./disk-config.nix
        
        ({ config, pkgs, ... }: {
           # Add the entire system closure to the ISO for offline install
           system.extraDependencies = [ mySystem.config.system.build.toplevel ];

           # Automated Install Script
           systemd.services.install-mysystem = {
             wantedBy = [ "multi-user.target" ];
             after = [ "network.target" "polkit.service" ];
             path = [ pkgs.util-linux pkgs.git pkgs.nix ];
             script = ''
               echo "WARNING: AUTOMATIC INSTALLATION TO /dev/sda STARTING IN 10 SECONDS..."
               sleep 10
               
               # 1. Partition and Format
               ${config.system.build.diskoScript}

               # 2. Install
               nixos-install --system ${mySystem.config.system.build.toplevel} --no-root-passwd --root /mnt

               # 3. Shutdown
               echo "Installation Complete. Shutting down."
               poweroff
             '';
             serviceConfig = {
               Type = "oneshot";
               User = "root";
               StandardOutput = "journal+console";
             };
           };
        })
      ];
    };
  in {
    nixosConfigurations.install-iso = installIso;
  };
}