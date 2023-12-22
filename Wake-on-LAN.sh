#!/bin/bash

# Fonction pour envoyer le paquet Wake-on-LAN
envoyer_wol() {
    mac=$1
    ip="255.255.255.255"
    port=9

    # Construire le paquet Wake-on-LAN
    paquet_wol=$(printf 'f%.0s' {1..12}; echo $mac | sed 's/://g; s/.\{1\}/& /g')

    # Utiliser la commande echo pour envoyer le paquet via netcat
    echo -n -e "$paquet_wol" | nc -u -w1 $ip $port

    if [ $? -eq 0 ]; then
        echo "Paquet WoL envoyé avec succès."
    else
        echo "Erreur lors de l'envoi du paquet WoL."
    fi
}

# Adresse MAC du PC Dell T7600
adresse_mac_dell_t7600="90:B1:1C:76:FE:92"

# Appeler la fonction pour envoyer le paquet Wake-on-LAN
envoyer_wol $adresse_mac_dell_t7600
