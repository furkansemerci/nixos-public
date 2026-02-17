{ config, pkgs, ... }:

{

  virtualisation.docker.enable  = true;

  virtualisation.oci-containers = {
    backend = "docker";

    containers = {
      nginx-test = {
        image = "nginx:latest";
        autoStart = true;
        ports = ["8080:80"];

        environment = {
          TEST_MESSAGE = "Hello from NixOS" ;
          APP_ENV = " development"; 
        };

        extraOptions = [
          "--memory=256m"
          "--cpus=0.5"
        ];
      };
    };
  };
}