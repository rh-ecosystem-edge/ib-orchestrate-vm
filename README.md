# SNO seed image creation and restoration using Image Base Upgrade (IBU)
Note that this repo is just a proof-of-concept. This repo is for debugging / experimenting with
single node OpenShift **

Note that single node OpenShift relocation is currently unsupported.

## TL;DR Full run with vDU profile
- Define a few environment variables:
```
SEED_IMAGE=quay.io/whatever/ostbackup:seed
export PULL_SECRET=$(jq -c . /path/to/my/pull-secret.json)
export BACKUP_SECRET=$(jq -c . /path/to/my/repo/credentials.json)
```
- Create seed VM with vDU profile
```
make seed vdu
```
- Create and push seed image
```
make seed-image-create SEED_IMAGE=$SEED_IMAGE
```
- Create recipient VM
```
make recipient
```
- Restore seed image in recipient
```
make sno-upgrade SEED_IMAGE=$SEED_IMAGE
```

## Prerequisites

- NMState v2.2.10 or above, this is required due to the nmstate config used in the agent-config.yaml
```bash
sudo dnf copr enable nmstate/nmstate-git
sudo dnf install nmstate
- Set `PULL_SECRET` environment variable to the contents of your cluster pull secret
- Set `BACKUP_SECRET` environment variable with the credentials needed to push/pull the seed image, in standard pull-secret format
```

- virt-install

```bash
sudo dnf install virt-install
```

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

This process will stop openshift and launch ibu-imager as a podman container, and afterwards restore the openshift cluster and update `SeedGenerator` CR
```bash
make seed-image-create SEED_IMAGE=quay.io/whatever/repo:tag
```

### Create and prepare a recipient cluster
As with the seed image, this process can be done in a single step, or run each step manually

#### Single step
There is a makefile target that does all the steps for us
```bash
make recipient
```

#### Step by step
Or we can choose to run each step manually, to have more control of each step

- Provision a VM and install SNO in it
```bash
make recipient-vm-create wait-for-recipient
```

- Prepare the recipient cluster for a couple of extras (LCA operator, shared /var/lib/containers)
```bash
make recipient-cluster-prepare
```

### Upgrade recipient SNO with a seed image
To upgrade the `recipient` cluster using a seed image we will use [LifeCycle Agent](https://github.com/openshift-kni/lifecycle-agent), and manage everything with the CR `ImageBasedUpgrade`

This process will upgrade the `recipient` cluster using the seed image and reboot into it
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
To be able to reuse the VMs, we can backup the qcow2 files of both seed and recipient VM
This will allow us to skip the initial provision, allowing for faster iterations when testing
To create a backup run:
```bash
make seed-vm-backup
```
or
```bash
make recipient-vm-backup
```

To restore an image, we run the complementary `restore` command
```bash
make seed-vm-restore
```
or
```bash
make recipient-vm-restore
```

IMPORTANT: Remember that certificates expire, so if a backed up image is old, certificates will expire and openshift wont be usable

TODO: Apply recert after restoring the image

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
make recipient-varlibcontainers
```

This will create a `/sysroot/containers` in the SNO (when not specifying the cluster with the CLUSTER variable, it defaults to the seed image) to be mounted in /var/lib/containers
The use case for this is to easily precache all the images that the cluster in the seed image will need, while original recipient cluster is still running

#### WARNING
It is important to note that for precaching to work, this change must be applied both in seed image and recipient cluster

## Examples
### Installing the backup into some running SNO
```
make seed-image-restore SNO_KUBECONFIG=path/to/recipient/sno/kubeconfig SEED_IMAGE=$SEED_IMAGE
```
- Reboot the recipient host
