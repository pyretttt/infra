# Step by step guide

1. Run `mise run oci-provision` providing required variables
2. Run `setup-fluxcd` providing github credentials
3. Also setup sops encryption for fluxcd `mise run fluxcd-age-setup`. Store contents of `age.delete_me.agekey` inside personal password manager. Public key may be commited. Secrets may now be encrypted with `mise run age-encrypt <file>`.
4. Setup wireguard cluster vpn with `mise run render-wg-config`. Commit changes and connect through wireguard client. Wireguard will be automatically configured to resolve private DNS resources.
