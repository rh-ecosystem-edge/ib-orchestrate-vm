# Image Based Installation (IBI) using coreos-installer

This PoC will:
- Install vanilla RHCOS to disk
- Mount the installation disk
- Create shared /var/lib/containers directory
- Restore SNO present in SEED_IMAGE

### TODO
- Use LifeCycle Agent binary to perform the restoration
- Add example configuration files/certs so we can have a working full run
- Embed pull-secret for downloading the seed image

## Steps
1. Define a few environment variables:

```bash
export SEED_IMAGE=quay.io/whatever/ostbackup:seed
export SEED_VERSION=version_matching_seed_version
export PULL_SECRET=$(jq -c . /path/to/my/pull-secret.json)
export BACKUP_SECRET=$(jq -c . /path/to/my/repo/credentials.json)

# Optional variables
export SSH_KEY=~/.ssh/id_rsa.pub
export IBI_INSTALLATION_DISK=/dev/vda
```

2. Prepare a coreos live iso with a custom ignition

```bash
make ibi-iso
```

3. Provision VM

```bash
make ibi-vm
```

4. Check progress

```bash
make ibi-logs
```

wait until the installation is complete (this step takes about a minute):

```
Jan 01 08:12:18 ibi install-rhcos-and-restore-seed.sh[4523]: ----------------------------------------------------------------------------------------
Jan 01 08:12:18 ibi install-rhcos-and-restore-seed.sh[1589]: DONE. Be sure to attach the relocation site info to the host and you can reboot the node
Jan 01 08:12:18 ibi install-rhcos-and-restore-seed.sh[4525]: ----------------------------------------------------------------------------------------
Jan 01 08:12:18 ibi systemd[1]: Finished SNO Image Based Installation.
```

4. Generate the configuration ISO and attach it to the VM

```bash
make imagebasedconfig.iso
make ibi-attach-config.iso
```

after generating the imagebasedconfig.iso you can find the kubeconfig for the installation under `ibi-iso-work-dir/auth/kubeconfig`.

5. Reboot VM

```bash
make ibi-reboot
```

After few minutes your cluster should be ready.

6. Use oc to query the API:

```bash
[coreos-installer]# oc --kubeconfig ibi-iso-work-dir/auth/kubeconfig get node
NAME   STATUS   ROLES                         AGE   VERSION
ibi    Ready    control-plane,master,worker   15m   v1.27.8+4fab27b
```
