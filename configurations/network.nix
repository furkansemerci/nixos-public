{ config, pkgs, lib, ... }:

{

  networking = {
    defaultGateway = {
      address = "10.0.2.1";
      interface = "enp0s3";
    };
    nameservers = [ "10.0.2.1" ];
    interfaces = {
      enp0s3.ipv4.addresses = [{
        address = "10.0.2.15";
        prefixLength = 24;
      }];

    };
  };

}
