# Installing BMC onto your Cluster

> This step assumes you already have a clustrer that meets the defined requirements.
> If you do not, you may either install your own or use BMC's cluster installation system.
>
> [Cluster Installation System](environment.md){ .md-button }

First, if you have not already in this terminal session, remember to set which profile you wish to install BMC with.
```sh
export PROFILE=<barememetal | eks | gke | aks>
```

## Preparing for Install
Next, run the following command to generate a config for your BMC install:
```sh
task config:init
```

This will create the file `config/<barememetal | eks | gke | aks>.yaml`.
Open this file with your text editor of choice.

Fill out the config according to the guide written in the file's comments.

Run the following command to validate your config once done:
```sh
task config:verify
```
This will let you know if there are any issues with your configuration options.

Once this is done, generate your secrets for the cluster:
```sh
task secrets:generate
```
**Make sure to copy these secrets down somewhere secure for later reference.**

## Installation
To complete the install, simply run:
```sh
task install
```
This process may take upwards of **10 minutes**. 

Since instalation verification is built into this command, it will let you know if any errors ocurr during installation.  



