---
layout: home

hero:
  name: ageism
  text: age secret deployment for NixOS
  tagline: Rekey, deduplicate, and incrementally deploy encrypted secrets to local and remote hosts.
  actions:
    - theme: brand
      text: Get started
      link: /guide/introduction
    - theme: alt
      text: CLI reference
      link: /reference/cli

features:
  - title: Rekeying on deploy
    details: Source secrets are decrypted on the controller and re-encrypted for each target host's public key.
  - title: Concurrent and resilient
    details: Hosts are deployed to concurrently. A failure on one host does not block the others.
  - title: Incremental
    details: Secrets are identified by content hash, so only missing or changed secrets are transferred.
  - title: NixOS integration
    details: Generate JSON index files for your NixOS configuration and decrypt secrets at boot with the bundled module.
---
