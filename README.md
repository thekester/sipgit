# ToIP Lab Notes

## Rétablir l'accès Internet pour le conteneur `sip-dhcp`

Lorsque le conteneur `sip-dhcp` a perdu l'accès Internet (impossibilité de résoudre `deb.debian.org` depuis `apt`), voici la séquence complète qui a permis de retrouver une connectivité fonctionnelle :

```bash
# 1. Réparer les permissions sur les fichiers réseau générés automatiquement
sudo lxc exec sip-dhcp -- chmod 644 /etc/systemd/network/10-toip-eth0.network /etc/resolv.conf

# 2. Redémarrer la pile réseau systemd dans le conteneur
sudo lxc exec sip-dhcp -- systemctl restart systemd-networkd

# 3. Vérifier l'adressage et la table de routage
sudo lxc exec sip-dhcp -- ip addr show eth0
sudo lxc exec sip-dhcp -- ip route

# 4. Constater la panne (pings en échec)
sudo lxc exec sip-dhcp -- ping -c1 1.1.1.1
sudo lxc exec sip-dhcp -- ping -c1 deb.debian.org

# 5. Réactiver le NAT du pont LXD pour fournir une sortie Internet
sudo lxc network set lxdbr0 ipv4.nat true

# 6. Redémarrer le conteneur pour prendre la nouvelle configuration
sudo lxc restart sip-dhcp

# 7. Vérifier le retour de la connectivité
sudo lxc exec sip-dhcp -- ping -c1 1.1.1.1
sudo lxc exec sip-dhcp -- ping -4 -c1 deb.debian.org   # forcer IPv4 évite un éventuel échec IPv6
sudo lxc exec sip-dhcp -- ping -6 -c1 deb.debian.org   # échec attendu (pas de passerelle IPv6)

# 8. Relancer l'automatisation pour finir l'installation
sudo USB_IFACE=enp0s8 ./setup_toip_infrastructure.sh
```

## Vérifications et sorties recueillies

Après le redémarrage du conteneur, les commandes suivantes ont confirmé la situation (IPv4 opérationnel, IPv6 toujours limitée côté deb.debian.org) :

```bash
$ sudo lxc exec sip-dhcp -- ip route
default via 10.42.0.1 dev eth0 proto static 
10.42.0.0/24 dev eth0 proto kernel scope link src 10.42.0.2 

$ sudo lxc exec sip-dhcp -- ping -c1 1.1.1.1
64 bytes from 1.1.1.1: icmp_seq=1 ttl=254 time=9.51 ms

$ sudo lxc exec sip-dhcp -- ping -4 -c1 deb.debian.org
64 bytes from debian.map.fastlydns.net (151.101.194.132): icmp_seq=1 ttl=254 time=13.5 ms

$ sudo lxc exec sip-dhcp -- ping -6 -c1 deb.debian.org
ping: connect: Network is unreachable
```

Même après ce rétablissement, l'installation de `dnsmasq` via le script peut rester bloquée au stade « InRelease » si le miroir Debian ne répond pas immédiatement. Dans ce cas, relancer l'installation (`sudo USB_IFACE=enp0s8 ./setup_toip_infrastructure.sh`) après quelques secondes/minutes ou utiliser `Ctrl+C` puis relancer plus tard.

## Contourner le blocage `InRelease`

Si `apt` reste bloqué sur `deb.debian.org` malgré le NAT, forcer IPv4 à l'intérieur du conteneur :

```bash
sudo lxc exec sip-dhcp -- sh -c 'apt-get update -o Acquire::ForceIPv4=true'
sudo lxc exec sip-dhcp -- sh -c 'apt-get install -y dnsmasq -o Acquire::ForceIPv4=true'
```

Si l'installation a déjà été interrompue à mi-chemin, terminer les paquets en attente avant de relancer :

```bash
sudo lxc exec sip-dhcp -- dpkg --configure -a
```

Une fois `dnsmasq` installé, rejouer `sudo USB_IFACE=enp0s8 ./setup_toip_infrastructure.sh` pour régénérer les fichiers Asterisk et le CSV de comptes.

Le script recherche désormais automatiquement les fichiers de configuration Asterisk. Il tente d'abord `/etc/asterisk/*.conf` sur l'hôte, puis inspecte chaque conteneur LXC et sélectionne le premier qui contient `sip.conf`, `extensions.conf` et `voicemail.conf`. Pour forcer une cible spécifique, définissez `ASTERISK_SIP_CONF`, `ASTERISK_EXTENSIONS_CONF`, `ASTERISK_VOICEMAIL_CONF` ou `ASTERISK_CONTAINER` avant d'exécuter le script.

## Étapes post-setup

1. **Exécuter la vérification automatique**
   - Lancer `sudo ./post_setup_checks.sh` pour générer `post_setup_summary.txt` (état du bridge, leases dnsmasq, peers/chaînes Asterisk, exemples `pjsua`). Le script détecte automatiquement chan_sip ou chan_pjsip (`sip show peers` ↔ `pjsip show contacts`).

2. **Configurer les terminaux SIP**
   - Brancher chaque téléphone/ATA sur le réseau `lxdbr0`.
   - Dans l’interface de chaque appareil, définir proxy/registrar `10.42.0.3`, domaine `sip.lab`.
   - Renseigner `username` + `auth ID` = extension (2001–2009) et le `secret` depuis `sip_devices.csv`.
   - Autoriser les codecs G.711 (µ/a-law) et DTMF RFC2833 ; pour les PAP-2T, configurer chaque port FXS avec l’extension correspondante.

3. **Vérifier le DHCP**
   - Observer les baux : `sudo lxc exec sip-dhcp -- tail -f /var/log/syslog`.
   - Confirmer que les terminaux reçoivent une IP `10.42.0.50-99`, gateway `10.42.0.1`, DNS `10.42.0.2`.
   - Si besoin de provisioning auto, ajouter `dhcp-option=option:tftp-server,<IP-tftp>` dans dnsmasq et relancer le script.

4. **Valider côté Asterisk**
   - Sur le PBX : `asterisk -rx "sip show peers"` (ou `pjsip show contacts`) pour vérifier les enregistrements.
   - Lancer des appels croisés (`2001` ↔ `2002`, etc.) en surveillant `asterisk -rx "core show channels verbose"`.
   - Tester la messagerie (`VoiceMail` context `toip-phones`) : composer `*97` ou attendre le timeout ; PIN 1234 par défaut.

5. **Tester depuis un client externe**
   - Exemple `pjsua` :
     ```bash
     pjsua --id sip:2001@sip.lab --registrar sip:10.42.0.3 --realm '*' \
           --username 2001 --password '<secret-2001>' sip:2002@sip.lab
     ```
   - Cette commande enregistre un UA distant auprès du PBX, puis initie un appel vers une autre extension. En la rejouant (et en inversant les extensions), vous démontrez que la signalisation traverse bien l’interface USB-bridge `lxdbr0`, que les comptes générés fonctionnent et que l’infrastructure répond à la consigne « tester le réseau téléphonique avec pjsua sur un hôte distant ». Répétez avec d’autres couples d’extensions pour valider les terminaux restants.

6. **Tracer et documenter**
   - Conserver les sorties clés (attache interface, création conteneur, `sip show peers`).
   - Noter dans votre rapport : plan d’adressage, comptes générés, résultats d’appel, éventuels ajustements de provisioning.

## Validation par étapes (conformité à l'énoncé)

1. **Exécuter les scripts d’assistance** –
   - `sudo ./post_setup_checks.sh` : génère `post_setup_summary.txt` (bridge, leases dnsmasq, exemples `pjsua`).
   - `sudo ./assist_phone_setup.sh` : démarre un serveur HTTP sur `./provisioning`, récapitule les templates et les commandes Asterisk/pjsua à lancer.
   - `./simulate_softphones.sh` : émule des téléphones via `pjsua` (`start-all`, `status`, `call <2001> <2002>`, etc.), pratique si aucun matériel n’est branché.
   - Les commandes `pjsua` proposées permettent de tester la traversée via l’interface USB ↔ `lxdbr0` et la liaison au PBX.
2. **Créer les comptes SIP** – `setup_toip_infrastructure.sh` génère automatiquement les fichiers `sip_phones.conf`, `extensions_phones.conf`, `voicemail_phones.conf` et `sip_devices.csv` pour chaque téléphone demandé.
3. **Configurer les téléphones** – Utiliser le conteneur `sip-dhcp` (dnsmasq) pour attribuer IP/GW/DNS, puis appliquer les identifiants (proxy `10.42.0.3`, domaine `sip.lab`, secrets du CSV) sur chaque appareil.
4. **Adapter la configuration par modèle** :
   - Les fichiers `provisioning/<device>_<extension>.cfg` générés automatiquement contiennent les paramètres essentiels (serveur, identifiants, codecs). Importez-les ou recopiez-les pour :
     - 4.1 Thomson ST2030 (extension 2001)
     - 4.2 GrandStream Budgetone 100 A/B (2002/2003)
     - 4.3 Aastra 53i (2004)
     - 4.4 Aethra Maia XC (2005)
     - 4.5 Linksys PAP-2T #1 et #2, lignes 1/2 (2006–2009)
5. **Valider l’enregistrement** – `post_setup_checks.sh` ou `assist_phone_setup.sh` rappellent les commandes à lancer (ex. `sudo lxc exec asterisk01 -- asterisk -rx "pjsip show contacts"`) pour confirmer que chaque terminal est bien enregistré.

Pour simplifier le téléchargement hors du conteneur, un script `prepare_dnsmasq_offline.sh` est disponible :

```bash
# Depuis l'hôte (dans /home/test/Documents/sip)
./prepare_dnsmasq_offline.sh            # télécharge les .deb Debian 12 dans offline-debs/ et les pousse dans sip-dhcp

# Puis dans le conteneur
sudo lxc exec sip-dhcp -- dpkg -i /root/*.deb
sudo lxc exec sip-dhcp -- apt-get install -f -y
```

## Validation réseau additionnelle

Après avoir forcé IPv4, on peut tester la sortie HTTP en installant `curl` (s'il n'est pas présent) et en vérifiant la réponse du miroir :

```bash
sudo lxc exec sip-dhcp -- sh -c 'apt-get install -y curl'
sudo lxc exec sip-dhcp -- sh -c 'curl -4I http://deb.debian.org/debian'
```

Si `curl` n'est pas disponible parce que `apt` reste bloqué, télécharger les paquets `dnsmasq` et dépendances sur l'hôte (via `apt download ...`) puis les pousser dans le conteneur (`lxc file push`) et installer à l'aide de `dpkg -i`.
