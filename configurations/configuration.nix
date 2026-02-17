{ config, lib, pkgs, ... }:

{
  imports =
    [ 
      ./network.nix
      ./hardware-configuration.nix
      ./clickhouse.nix
      ./redis.nix
      ./docker-nginx.nix
      ./postgresql-ha.nix
      ./nomad.nix
    ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "fes-nixos"; 
  networking.networkmanager.enable = true;
  networking.firewall.enable = false;   
 
  time.timeZone = "Europe/Istanbul";

  users.users.fes = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; 
    # Set a password to not get locked out
    initialPassword = "password"; 
    packages = with pkgs; [];
  };

  security.sudo.extraRules = [{
    users = ["fes"];
    commands = [{ command = "ALL";
      options = ["NOPASSWD"]; 
    }];
  }];

  environment.systemPackages = with pkgs; [
    vim 
    wget
    git
    pkgs.nix-ld
    pkgs.net-tools
    jq
  ];
  nixpkgs.config.allowUnfree = true;

  services.openssh.enable = true;
  services.my-clickhouse.enable = true;
  programs.nix-ld.enable = true;
  system.stateVersion = "25.11"; 
}