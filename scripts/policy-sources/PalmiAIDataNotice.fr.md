# Avis relatif à la transmission de données aux services d’IA tiers

Version : v26.11  Date de version : 2026.11.01

PalmiAgent est un outil d’IA privilégiant le traitement local. Il n’exploite aucun serveur de modèles dans le cloud qui reçoit, stocke ou analyse vos discussions, pièces jointes ou résultats d’outils, et ne collecte ni ne téléverse ces informations de manière autonome à des fins de traitement par IA sans action de votre part ou autorisation correspondante. L’app n’envoie le contenu nécessaire à une requête au service d’IA tiers que vous choisissez vous-même qu’après la configuration d’un modèle à l’étape suivante, le lancement d’une requête d’IA et la sélection du contenu concerné.

## 1. Données susceptibles d’être envoyées

1. Les messages, prompts et instructions que vous saisissez activement, ainsi que les messages précédents, le contexte de conversation et l’état de la tâche dont le modèle a besoin pour comprendre et réaliser la requête actuelle ; le simple fait d’ouvrir l’app, de rester sur un écran ou de la placer en arrière-plan ne téléverse pas de discussions sans rapport ;
2. Les images, documents et autres fichiers que vous ajoutez expressément à la tâche actuelle, y compris le texte extrait, les résultats OCR, les informations de format ou les résumés nécessaires pour aider le modèle à comprendre ces pièces jointes ; les autres fichiers locaux que vous n’ajoutez pas à la requête ne sont pas envoyés à ce titre ;
3. Les résultats du calendrier, des rappels, des contacts, de la localisation, des photos ou d’autres outils inclus dans la tâche actuelle après votre autorisation iOS distincte et votre appel explicite de l’outil ; accorder une autorisation système ne vaut pas consentement à transmettre ces données, et seuls les résultats réellement utilisés par la requête d’IA actuelle peuvent être envoyés ;
4. Les instructions système, définitions et résultats d’outils, identifiants de modèles, paramètres de génération et informations techniques nécessaires pour organiser, réaliser ou reprendre la requête actuelle ; ces informations permettent au modèle tiers de traiter correctement la tâche que vous avez lancée.

## 2. Destinataires

Le destinataire est le service de modèles d’IA tiers et l’exploitant du point de terminaison API que vous choisissez vous-même ou saisissez puis confirmez à l’étape suivante, et non PalmiAgent. Cette page ne présélectionne, ne recommande ni ne suggère aucun service et n’affiche aucune configuration que vous n’avez pas encore terminée. Après configuration, le contenu d’une requête d’IA que vous lancez est transmis par le réseau à une interface contrôlée par cet exploitant. L’entité juridique, la région du serveur et le responsable effectif du traitement dépendent du service et des conditions que vous choisissez. Si vous ne pouvez pas vérifier l’identité, la politique de confidentialité ou les règles de traitement du service, ou si vous n’y faites pas confiance, ne terminez pas sa configuration et ne lui envoyez aucun contenu.

## 3. Finalité

Le contenu est envoyé uniquement pour traiter les requêtes que vous lancez activement : générer des réponses, comprendre les images ou fichiers choisis, effectuer les tâches d’agent demandées et conserver le contexte nécessaire. Le service tiers peut journaliser, examiner, conserver, transmettre à des prestataires amont ou supprimer les données selon sa politique de confidentialité, ses conditions et les paramètres du compte. PalmiAgent ne peut déterminer sa durée de conservation, son usage pour l’entraînement, ses traitements transfrontaliers ou ses pratiques de suppression. Après transmission, les demandes d’accès, de rectification, d’exportation ou de suppression doivent passer par les canaux de cet exploitant.

## 4. Limites du traitement local

PalmiAgent n’exploite aucun serveur de modèles dans le cloud pour relayer, recevoir ou stocker de manière centralisée le contenu des requêtes d’IA décrit ci-dessus. Dans l’architecture actuelle, les requêtes vont de votre appareil au point de terminaison tiers que vous configurez. L’app peut stocker localement les espaces de travail, conversations et réglages nécessaires aux fonctions utilisées, mais son ouverture ne provoque pas la collecte et le téléversement autonomes d’informations personnelles sans rapport. Les autorisations iOS pour les contacts, calendriers, photos, localisation et données similaires sont demandées séparément par le système lors de l’utilisation d’une fonction ; l’autorisation prévue par le présent avis concerne uniquement l’envoi du contenu que vous incluez expressément dans une tâche d’IA au service tiers choisi ensuite.
