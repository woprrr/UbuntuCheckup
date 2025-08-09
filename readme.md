# PC Checkup & Optimisation – Ubuntu

Script Bash permettant de réaliser un **audit complet** et, si souhaité, d’appliquer des **optimisations système** pour améliorer les performances d’un PC sous **Ubuntu 24.04 LTS** (ou dérivés), avec prise en charge spécifique des configurations gaming/NVIDIA.

## Fonctionnalités

- **Rapport système complet** : OS, noyau, CPU, RAM, GPU, uptime
- **Vérification santé matérielle** : températures (`lm-sensors`), SSD/NVMe (`smartctl`, `nvme-cli`)
- **Analyse temps de boot** : `systemd-analyze` et `blame` (services lents)
- **Optimisation mémoire** :
  - Ajuste la taille du swap (min. 4 Go)
  - Configure `vm.swappiness` (par défaut : 10)
  - Active `zram` (swap compressé en RAM)
- **Optimisation démarrage** :
  - Désactive certains services non essentiels (liste configurable)
  - Configure Docker et Containerd en socket-activation
- **Nettoyage système** :
  - Mises à jour complètes
  - Suppression paquets obsolètes
  - Nettoyage caches et journaux (`journalctl`)
- **Optimisation graphique NVIDIA** :
  - Active `ForceFullCompositionPipeline` (Xorg uniquement, HDMI-1 par défaut)

## Modes d’exécution

- **Dry-run** (par défaut) : génère uniquement un **rapport** sans rien modifier
- **Apply** : applique réellement les optimisations

## Utilisation

```bash
# Donner les droits d’exécution
chmod +x pc-checkup.sh

# Mode rapport (dry-run)
sudo ./pc-checkup.sh
# ou
sudo ./pc-checkup.sh --dry-run

# Mode application des optimisations
sudo ./pc-checkup.sh --apply

