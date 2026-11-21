# VIRT-MANAGER

This setup is usually required on Fedora because of FIREWALLD, not on plain Arch

# NOTE

To make echo "qemu:///system" the default run this command:
```bash
echo 'export LIBVIRT_DEFAULT_URI="qemu:///system"' >> ~/.zshrc
```
