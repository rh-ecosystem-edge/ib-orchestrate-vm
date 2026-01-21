## TL;DR Full run with vDU profile
- Define a few environment variables:

```bash
export SEED_IMAGE=quay.io/whatever/ostbackup:seed
export PULL_SECRET=$(jq -c . /path/to/my/pull-secret.json)
export BACKUP_SECRET=$(jq -c . /path/to/my/repo/credentials.json)
export IP_STACK=v4        # v4|v6|v4v6|v6v4 (dual-stack supported)
```

- Create seed VM with vDU profile

```bash
make seed vdu
```

- Create and push seed image

```bash
make seed-image-create SEED_IMAGE=$SEED_IMAGE
```

- Create target VM

```bash
make target
```

- Restore seed image in target

```bash
make sno-upgrade SEED_IMAGE=$SEED_IMAGE
```

## Prerequisites

- virt-install

```bash
sudo dnf install virt-install
```

- In case you don't have nmstatectl installed please install it

```bash
sudo dnf install nmstate
```

- Set `PULL_SECRET` environment variable to the contents of your cluster pull secret
- Set `BACKUP_SECRET` environment variable with the credentials needed to push/pull the seed image, in standard pull-secret format

## Fedora prerequisites

### If using systemd-resolved as a system DNS resolver

<details>
  <summary>Show more info</summary>


Add the `NetworkManager` dnsmasq instance as a DNS server for resolved:

```bash
sudo mkdir /etc/systemd/resolved.conf.d
```

Then create `/etc/systemd/resolved.conf.d/dns_servers.conf` with:

```
[Resolve]
DNS=127.0.0.1
Domains=~.
```

And finally restart systemd-resolved:

```bash
sudo systemctl restart systemd-resolved
```

Note that by default in this repo the cluster domain ends with `redhat.com`, so
make sure you're not connected to the redhat VPN, otherwise `resolved` will
prefer using the Red Hat DNS servers for any domain ending with `redhat.com`

</details>

### If using authselect as nsswitch manager

<details>
  <summary>Show more info</summary>

#### Install libvirt-nss
```bash
sudo dnf install libvirt-nss
```

#### Add authselect libvirt feature

```bash
sudo authselect enable-feature with-libvirt
```

This makes it so that libvirt guest names resolve to IP addresses

</details>

### Libvirt no route to host issue

<details>
  <summary>Show more info</summary>

Sometimes your libvirt bridge interface will not contain your VM's interfaces,
which means you'll have a "no route to host" errors when trying to contact
services on your VM.

To fix this, install the `bridge-utils` package, run `brctl show`. If the `tt0`
bridge has no `vnet*` interfaces listed, you'll need to add them with 
`sudo brctl addif tt0 <vnet interface>`.

</details>

## How this works
### Generate the seed image template
This process can be done in a single step, or run each step separately to have more control
#### Single step
There is a makefile target that does all the steps for us
```bash
make seed
```

#### Step by step

To generate a seed image we want to:
- Provision a VM and install SNO in it

```bash
make seed-vm-create wait-for-seed
```

- Prepare the seed cluster to have a couple of needed extras

```bash
make seed-cluster-prepare
```

#### Customize seed SNO

- (OPTIONAL) Modify that installation to suit the use-case that we want to have in the seed image. In this example we install the components of a vDU profile

```bash
make vdu
```

### Create a seed image using seed VM
To create a seed image we will use [LifeCycle Agent](https://github.com/openshift-kni/lifecycle-agent), and manage everything with the CR `SeedGenerator`

This process will stop openshift and launch lca-cli as a podman container, and afterwards restore the openshift cluster and update `SeedGenerator` CR
```bash
make seed-image-create SEED_IMAGE=quay.io/whatever/repo:tag
```

### Create and prepare a target cluster
As with the seed image, this process can be done in a single step, or run each step manually

#### Single step
There is a makefile target that does all the steps for us
```bash
make target
```

#### Step by step
Or we can choose to run each step manually, to have more control of each step

- Provision a VM and install SNO in it

```bash
make target-vm-create wait-for-target
```

- Prepare the target cluster for a couple of extras (LCA operator, shared /var/lib/containers)

```bash
make target-cluster-prepare
```

### Upgrade target SNO with a seed image
To upgrade the `target` cluster using a seed image we will use [LifeCycle Agent](https://github.com/openshift-kni/lifecycle-agent), and manage everything with the CR `ImageBasedUpgrade`

This process will upgrade the `target` cluster using the seed image and reboot into it
```bash
make sno-upgrade SEED_IMAGE=quay.io/whatever/repo:tag
```

To follow the logs and see what is going on in real time, we can run:
```bash
make lca-logs CLUSTER=seed
```

## Extra goodies

### Descriptive help for the Makefile
You can run
```bash
make help
```
and get a description of the main Makefile targets that you can use

### Backup and reuse VM qcow2 files
To be able to reuse the VMs, we can backup the qcow2 files of both seed and target VM
This will allow us to skip the initial provision, allowing for faster iterations when testing
To create a backup run:

```bash
make seed-vm-backup
```

or

```bash
make target-vm-backup
```

To restore an image, we run the complementary `restore` command

```bash
make seed-vm-restore
```

or

```bash
make target-vm-restore
```

Remember that certificates expire, so if a backed up image is old, certificates will expire and openshift wont be usable
If certs have expired, you can run recert to issue new certificates:

```bash
make seed-vm-recert
```

or

```bash
make target-vm-recert
```

### vDU profile
A vDU profile can be applied to the image before baking with

```bash
make vdu
```

### Use shared directorty for /var/lib/containers
A shared directory `/sysroot/containers` can be used to mount and share /var/lib/containers among ostree deployments
Run:

```bash
make seed-varlibcontainers
```

or

```bash
make target-varlibcontainers
```

This will create a `/sysroot/containers` in the SNO (when not specifying the cluster with the CLUSTER variable, it defaults to the seed image) to be mounted in /var/lib/containers
The use case for this is to easily precache all the images that the cluster in the seed image will need, while original target cluster is still running

#### WARNING
It is important to note that for precaching to work, this change must be applied both in seed image and target cluster

## Examples
### Installing the backup into some running SNO

```
make seed-image-restore SNO_KUBECONFIG=path/to/target/sno/kubeconfig SEED_IMAGE=$SEED_IMAGE
```

- Reboot the target host

## Extras

- Set `DHCP` environment variable in order to run with dhcp, default is static ip 
