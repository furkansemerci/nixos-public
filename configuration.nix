{ config, lib, pkgs, ... }:

{
  imports =
    [ 
      ./network.nix
      #./clickhouse.nix
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
  ];

  services.openssh.enable = true;
  programs.nix-ld.enable = true;
  system.stateVersion = "25.11"; 
}