#!/bin/bash

updateFt(){
# Mise a jour 
echo "Recherche de mise à jour : "
read -p "voulez-vous faire une mise à jour système ?  [o/n] " answer 

if [ "$answer" = "o" ]; then

        sudo apt-get update -y
        echo "----------------------------"
else
        echo "ok pas de mise à jour pour le moment"
        echo "----------------------------"
fi

}

upgradeFt(){
# upgarde système 
echo "Upgrade système : "
read -p "voulez-vous faire un upgrade du système ?  [o/n] " answer 

if [ "$answer" = "o" ]; then

        sudo apt-get upgrade -y
        echo "----------------------------"
	read -p "voulez-vous supprimer les packages automatiquement qui ne sont plus nécessaires [o/n] " awswer

	# demande pour l'upgrade
	if [ "$answer" = "o" ]; then
	output=$(sudo apt autoremove -y 2>&1)

		# verifier le résultat
		if [ $? -eq 0 ]; then
		echo "Mise à jour réussi"
		else
		echo "echec de la mise à jour"
		echo "$output"
		fi

	else
	echo "Aucun modification n'a était excuter"
	fi

else
        echo "ok pas d'upgrade pour le moment"
        echo "----------------------------"
fi

}


# Brave
echo "---------------------------"
echo "Installation de brave"
BRAVE=`sudo snap install brave`
echo $BRAVE
echo "---------------------------"

# demande update
updateFt

# CURL
echo "Installation de CRUL"
CRUL=`sudo snap install curl`
echo $CRUL
echo "---------------------------"

# demande update
updateFt

# parti necessaire avant l'installation de Jetbrain Toolbox
echo "Recherche de l'installation libfuse2 utile pour l'installation de Jetbrain toolbox"
echo "---------------------------"
RSlib=$(dpkg -s libfuse2 )
echo "Resultat de la recherche : "
echo $RSlib

# demande update
updateFt

# -n si il y a quelque chose en retour
if [ -n "$RSlib" ]; then
	echo "----------------------------"
	echo "libfuse2 est déjà installer "
	echo "----------------------------"
else
	# Demander à l utilisateur s il souhaite installer le programme
	echo "---------------------------"
	echo "libfuse2 n'est pas installer"
	read -p "voulez vous l'installer ?  [o/n] " answer 
	echo "---------------------------"

	# installation de libfuse2
	if [ "$answer" = "o" ]; then
		sudo apt-get update 
		sudo apt install libfuse2
	else
	echo "---------------------------"
	echo "le programme ne sera pas installer"
	echo "---------------------------"
	fi
fi

# demande update
updateFt

# demande upgrade 
upgradeFt

echo "Installation de JetBrains toolBox" 
echo "Telecharger sur le site internet : "

echo "voir l'adresse : https://www.jetbrains.com/fr-fr/toolbox-app/ "
echo "pour lancer le script taper ./nomducscript"
