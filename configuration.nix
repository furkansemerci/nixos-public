{ config, lib, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./network.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "fes-nixos"; # Define your hostname.

  # Configure network connections interactively with nmcli or nmtui.
  networking.networkmanager.enable = true;
  networking.firewall.enable = false;   
 
  # Set your time zone.
  time.timeZone = "Europe/Istanbul";




  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.fes = {
    isNormalUser = true;
    extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
    packages = with pkgs; [];
  };

  security.sudo.extraRules = [{
    users = ["fes"];
    commands = [{ command = "ALL";
      options = ["NOPASSWD"]; 
    }];
  }];



  # programs.firefox.enable = true;

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    wget
    git
    pkgs.nix-ld
    pkgs.net-tools
  ];



  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  programs.nix-ld.enable = true;

  system.stateVersion = "25.11"; # Did you read the comment?

}

