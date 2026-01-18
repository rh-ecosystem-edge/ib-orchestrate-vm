# IBI / IBU VM orchestration

This repo provides the framework for running Image Base Upgrade (IBU) and
Installation (IBI) on libvirt virtual machines for development, debugging and
experimentation purposes. It also provides framework for performing IP Configuration (IPC) on SNO clusters.

Usage:

- [IBI Usage](README.ibi.md)
- [IBU Usage](README.ibu.md)
- [IPC Usage](ipc/README.md)

## Requirements

For running some of the options in the makefile you might need the following packages:

- `virt-install`
- `nmstate`

Remember to define `PULL_SECRET` not pointing to the file containing it but to the full secret itself, you can convert from the file to the variable by running:

```sh
export PULL_SECRET="$(jq -c . ~/openshift_pull.json)"
```

That will load file contents with jq in compact form and store it in that environment variable.
