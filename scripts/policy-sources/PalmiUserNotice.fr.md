# Notice Palmi relative à la confidentialité et aux services d’IA tiers

Document à lire et à accepter avant la première configuration d’un modèle.

Version : v26.7 · Date de version : 2026.07.01 · Public : utilisateurs de l’application mobile Palmi / PalmiAgent

**Important :** lisez ce document avant de configurer un modèle. En sélectionnant « J’ai lu et j’accepte », vous indiquez comprendre et reconnaître les flux de données, les limites des services tiers, les précautions relatives aux informations sensibles et les responsabilités liées à vos choix décrits ici. Cela ne signifie pas que vous acceptez des conditions tierces qui ne vous ont pas été présentées. Les conditions officielles des services tiers sont celles des pages actuellement publiées par ces services.

## 1. Objet et champ d’application

Ce document est la notice utilisateur de Palmi (PalmiAgent) présentée avant la première configuration d’un modèle. Il explique les flux de données probables entre l’application locale, les services de modèles choisis par l’utilisateur, les autorisations système et les outils tiers, et demande à l’utilisateur d’en prendre explicitement connaissance avant de poursuivre.

Ce document n’est la politique de confidentialité d’aucun fournisseur de modèles. Il ne remplace ni les conditions de service, ni la politique de confidentialité, ni l’accord développeur, ni l’accord de traitement des données, ni la politique d’utilisation acceptable, ni la licence de modèle, ni les règles de sécurité d’un fournisseur de modèles tiers, d’un fournisseur cloud, d’un agrégateur de modèles, d’une passerelle d’entreprise, d’un service système ou d’un déploiement local.

Palmi est une application d’agent privilégiant le traitement local et une interface de connexion aux modèles. Le modèle choisi, l’URL de base saisie, la clé API utilisée, le contenu envoyé et les autorisations système ou outils activés déterminent si les données quittent votre appareil et qui les traite.

## 2. Traitement local des données dans la conception actuelle du produit

Dans sa conception actuelle, Palmi n’exploite aucune base de données centralisée côté serveur pour le contenu de vos discussions, fichiers d’espace de travail, pièces jointes ou clés API. Les projets, conversations, fichiers d’espace de travail, pièces jointes, journaux d’exécution, caches et préférences sont principalement stockés dans le conteneur de l’application sur votre appareil. Les identifiants de modèles doivent être conservés dans le trousseau système ou un stockage sécurisé équivalent.

L’OCR local, l’aperçu des fichiers, la lecture et l’écriture dans l’espace de travail, Python intégré, les caches locaux, la gestion des conversations et le nettoyage des données fonctionnent généralement sur l’appareil. À moins de configurer un modèle distant, une recherche distante, un service de fichiers distant, une synchronisation cloud, un partage ou une exportation, ou une autre fonction tierce, ces éléments ne sont normalement pas envoyés par Palmi lui-même vers un serveur distant exploité par Palmi.

Les systèmes de l’appareil, iCloud ou les sauvegardes système, les diagnostics de panne, l’App Store, la gestion des appareils mobiles d’entreprise, les proxys réseau, VPN, outils de sécurité et exportations lancées par l’utilisateur peuvent traiter des données selon les règles d’Apple, d’un administrateur d’organisation, d’un service réseau ou d’un tiers que vous choisissez. Palmi ne contrôle pas ces processus système ou choisis par l’utilisateur.

## 3. Cas dans lesquels les données peuvent quitter l’appareil

Lorsque vous configurez et utilisez un service de modèles distant, un agrégateur de modèles, un point de terminaison hébergé dans le cloud, une passerelle d’entreprise ou un point de terminaison personnalisé compatible OpenAI, les prompts, le contexte, les résumés de fichiers, les images, les résultats d’outils, la configuration des rôles du modèle, des fragments d’instructions système, l’historique des conversations, les informations d’erreur et les métadonnées nécessaires aux requêtes peuvent être envoyés à ce service.

Lorsque vous activez la recherche web, la lecture de pages web, les cartes, le courrier, les messages, le téléphone, le calendrier, les rappels, les contacts, la localisation, l’appareil photo, les photos, la reconnaissance vocale, les notifications, Spotlight, le routage système ou d’autres capacités d’outils, les données correspondantes peuvent être traitées par le service système, le moteur de recherche, le site web, le service de compte, l’environnement d’entreprise ou le service réseau concerné.

Lorsque vous importez, ouvrez, copiez, partagez, exportez, envoyez ou téléversez un fichier, ou demandez à un agent d’effectuer une action externe sur celui-ci, le fichier ou son contenu peut être écrit à l’emplacement de votre choix, envoyé à l’application, au fournisseur ou au contact de votre choix, ou entrer dans les caches et journaux du système concerné.

La transmission réseau nécessite normalement une connexion. Les opérateurs réseau, fournisseurs DNS, proxys, VPN, passerelles, pare-feu, produits de sécurité d’entreprise ou services tiers peuvent traiter des métadonnées réseau selon leurs propres règles.

## 4. Services de modèles, points de terminaison compatibles OpenAI et limites de responsabilité

La compatibilité OpenAI décrit uniquement une similitude de structure des points de terminaison, d’authentification, de format de requête, de structure des messages, de diffusion ou de format d’appel d’outil. Elle ne signifie pas qu’OpenAI exploite le service, ni que celui-ci applique les mêmes règles de sécurité, conservation, entraînement, suppression, transfert transfrontalier, règlement des différends ou droit qu’OpenAI.

Les services de modèles tiers, fournisseurs cloud, agrégateurs de modèles, passerelles d’entreprise et services auto-hébergés peuvent agir en tant que responsables indépendants du traitement, sous-traitants, responsables conjoints du traitement, fournisseurs d’infrastructure ou hébergeurs de modèles. Leurs politiques et accords de compte en vigueur régissent la journalisation, la conservation des entrées et sorties, l’examen de sécurité, l’utilisation des données pour l’entraînement, le routage vers des modèles amont, le traitement des demandes de suppression ou la réponse aux demandes des autorités publiques ou de contrôle.

Palmi ne peut pas vérifier à votre place le propriétaire d’un point de terminaison saisi, la provenance d’une clé API, les droits du compte, la région du service, la responsabilité de facturation, la durée de conservation, les paramètres d’entraînement, la configuration sans conservation de données, les clauses de protection des données d’entreprise ou le prestataire amont qui traite effectivement les données du modèle. Vous devez confirmer ces points avant utilisation.

## 5. Contenu sensible, documents d’entreprise et données concernant autrui

Vous ne devez pas soumettre de mots de passe, clés API, clés privées, numéros d’identité, cartes bancaires, informations de santé, informations sur des mineurs, position précise, contacts, historiques de discussion, données de clients, secrets de code source, secrets commerciaux, recherches non publiées, contenu protégé par un accord de confidentialité, données réglementées ou tout élément susceptible de porter atteinte aux droits d’autrui sans disposer des autorisations, du fondement juridique et de l’examen de sécurité suffisants.

Si vous utilisez Palmi au nom d’une entreprise, d’une école, d’un laboratoire, d’une équipe de projet, d’un client, d’un membre de votre famille ou de tout autre tiers, vous devez confirmer votre autorisation de configurer les services de modèles, d’envoyer les contenus concernés, d’accorder les autorisations système, d’appeler les outils, de téléverser ou exporter des fichiers, et respecter les exigences de cette organisation en matière de classification des données, confidentialité, conformité, achats et approbation de sécurité.

Si vous ignorez si une catégorie d’informations peut être envoyée à un modèle ou service tiers, ne l’envoyez pas par défaut. Envisagez la suppression des éléments sensibles, la synthèse, l’anonymisation, le traitement local, l’approbation interne ou un service d’entreprise répondant aux exigences de conformité applicables.

## 6. Appels d’outils, autorisations système et actions externes

Les fonctions d’agent de Palmi peuvent proposer ou déclencher la lecture de fichiers, la génération de fichiers, des modifications de l’espace de travail, des recherches web, l’accès au calendrier, aux rappels, contacts, à la localisation, aux photos, à l’appareil photo, à la parole, aux applications système, aux brouillons de messages ou d’autres actions système. Selon l’outil, des autorisations iOS, une confirmation de l’utilisateur, une autorisation de compte tiers ou une approbation de politique d’organisation peuvent être nécessaires.

Toute action susceptible d’affecter un système externe, une autre personne, les actifs d’un compte, des horaires, l’état de fichiers, l’envoi de messages, des achats, paiements, déploiements, suppressions ou divulgations publiques doit être examinée par une personne avant exécution. Les résultats des modèles peuvent être incomplets, inexacts, obsolètes, inventés, biaisés ou contraires à votre intention.

Le risque augmente fortement si vous activez les approbations automatiques, l’exécution par lots, l’exécution de scripts, l’automatisation web, le routage système ou les intégrations d’outils d’entreprise. Utilisez ces capacités uniquement pour des tâches fiables et dans des environnements permettant de revenir en arrière.

## 7. Gestion locale des données, retrait et suppression

Vous pouvez gérer les données locales et les données de comptes tiers au moyen de la gestion des données de l’application, des réglages système, des autorisations iOS, du trousseau ou de la réinitialisation des identifiants, des consoles des fournisseurs, des portails de comptes tiers, des administrateurs d’organisation, des demandes d’assistance aux fournisseurs cloud ou de la désinstallation de l’application.

L’effacement de l’espace de travail local, des caches, préférences ou identifiants de modèles de Palmi affecte uniquement les données sur l’appareil ou les copies conservées par Palmi. Il ne supprime pas automatiquement les données déjà envoyées à des services de modèles tiers, moteurs de recherche, sites web, fournisseurs cloud, agrégateurs, passerelles d’entreprise, services système ou autres applications. L’accès, la rectification, l’exportation, la suppression, l’arrêt de l’utilisation pour l’entraînement, les contrôles de mémoire ou de conservation des journaux côté tiers doivent être gérés selon la politique et les outils de compte du fournisseur concerné.

La suppression ou la désinstallation de l’application peut encore être soumise aux sauvegardes système, à la gestion des appareils d’entreprise, aux journaux, fichiers exportés, copies partagées, durées de conservation des tiers et obligations de conservation légale.

## 8. Résultats de l’IA et risques professionnels

Les résultats des modèles ne constituent pas des conseils juridiques, médicaux, financiers, d’investissement, fiscaux, de sécurité technique, de santé mentale, d’emploi, d’immigration, d’éducation ou d’autres conseils professionnels. Dans les situations professionnelles ou à haut risque, consultez un professionnel qualifié et vérifiez le résultat de manière indépendante.

Les modèles peuvent produire des faits erronés, du code défectueux, de mauvaises citations, des conseils de sécurité trompeurs, des plans inexécutables, des politiques dépassées, de faux liens ou du contenu inapproprié. Décidez avec soin si vous souhaitez utiliser, diffuser, exécuter, soumettre leurs résultats ou vous y fier.

Palmi est un outil et une interface de travail. Il ne garantit pas qu’un modèle tiers, point de terminaison, outil, source de recherche, service système ou configuration utilisateur soit toujours disponible, exact, sûr, conforme ou adapté à un usage particulier.

## 9. Liens vers les politiques des services de modèles courants

La liste ci-dessous présente des politiques pouvant concerner les raccourcis actuels de Palmi, les fournisseurs compatibles OpenAI conservés ou courants, les agrégateurs et les services de modèles personnalisés. Les liens sont des pages publiques ou des entrées de consoles officielles recueillies pour cette version du document. Les fournisseurs peuvent présenter des conditions différentes selon le pays ou la région, le type de compte, l’accord d’entreprise, le produit API, le modèle, le mode d’hébergement et le fournisseur amont. Avant utilisation, consultez les pages actuelles du fournisseur.

### Zhipu AI / GLM / Z.ai / BigModel

L’un des fournisseurs rapides actuellement proposés dans Palmi ; peut aussi être utilisé via un point de terminaison personnalisé compatible OpenAI.

- [BigModel / plateforme ouverte Zhipu](https://open.bigmodel.cn/)
- [Site officiel Z.ai](https://z.ai/)

Avant utilisation, examinez les dernières conditions de service, la politique de confidentialité, les conditions développeur et les conditions de traitement des données affichées dans la console ou pendant la connexion.

### DeepSeek

L’un des fournisseurs rapides actuellement proposés dans Palmi ; peut aussi être utilisé par son API officielle, un agrégateur ou un point de terminaison personnalisé.

- [Politique de confidentialité DeepSeek](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
- [Conditions d’utilisation DeepSeek](https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html)

### Point de terminaison personnalisé compatible OpenAI

URL de base, clé API et nom de modèle fournis par l’utilisateur. Le service réel peut être un fournisseur officiel, un agrégateur, un hébergeur cloud, une passerelle d’entreprise, un serveur local ou un service auto-hébergé.

La compatibilité OpenAI décrit uniquement la structure d’une API ; elle ne signifie pas qu’OpenAI exploite le point de terminaison ou que ses règles de confidentialité, conservation, entraînement, suppression ou transfert sont identiques.

Examinez la politique actuelle du propriétaire du point de terminaison, de la passerelle de l’organisation ou du système auto-hébergé avant d’envoyer des données.

### OpenAI / ChatGPT

Peut être utilisé via un point de terminaison personnalisé, OpenRouter, Azure OpenAI ou une autre voie d’hébergement.

- [Politique de confidentialité OpenAI](https://openai.com/policies/privacy-policy/)
- [Conditions d’utilisation OpenAI](https://openai.com/policies/terms-of-use/)

### Microsoft Azure OpenAI / Azure AI Foundry

Peut être utilisé via une ressource Azure, un compte d’entreprise ou un point de terminaison personnalisé.

- [Déclaration de confidentialité Microsoft](https://www.microsoft.com/en-us/privacy/privacystatement)
- [Données, confidentialité et sécurité Azure OpenAI](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy)

### Alibaba Cloud Model Studio / DashScope / Qwen

Peut être utilisé via des points de terminaison Alibaba Cloud Model Studio ou DashScope compatibles OpenAI, des points de terminaison personnalisés ou des agrégateurs.

- [Confidentialité Alibaba Cloud](https://www.aliyun.com/legal/privacy)
- [Documentation DashScope](https://help.aliyun.com/zh/dashscope/)

Pour les comptes d’entreprise, examinez aussi les conditions de service Alibaba Cloud, les accords de traitement des données et les règles propres à la région.

### Moonshot AI / Kimi

Peut être utilisé via l’API officielle Kimi / Moonshot, un point de terminaison personnalisé ou un agrégateur.

- [Plateforme ouverte Moonshot AI](https://platform.moonshot.cn/)
- [Site officiel Kimi](https://kimi.moonshot.cn/)

Utilisez la dernière politique de confidentialité, le contrat de service et les conditions API affichés sur la plateforme ouverte ou la page de connexion.

### MiniMax / Hailuo / Talkie

Peut être utilisé via l’API officielle MiniMax, un point de terminaison personnalisé ou un agrégateur.

- [Site officiel MiniMax](https://www.minimax.io/)
- [Plateforme ouverte MiniMax](https://platform.minimaxi.com/)

Utilisez la politique de confidentialité, le contrat de service et les conditions API affichés sur la plateforme et la console du compte.

### Volcengine Ark / Doubao

Peut être utilisé via des points de terminaison Volcengine Ark compatibles OpenAI, un point de terminaison personnalisé ou un agrégateur.

- [Confidentialité Volcengine](https://www.volcengine.com/docs/6256/64902)
- [Documentation Volcengine Ark](https://www.volcengine.com/docs/82379)

### Tencent Hunyuan

Peut être utilisé via les API Tencent Cloud Hunyuan, un point de terminaison personnalisé ou un agrégateur.

- [Déclaration de confidentialité Tencent Cloud](https://cloud.tencent.com/document/product/301/11470)
- [Contrat de service Tencent Cloud](https://cloud.tencent.com/document/product/301/1967)

### Baidu Qianfan / ERNIE

Peut être utilisé via les points de terminaison Baidu AI Cloud Qianfan, un point de terminaison personnalisé ou un agrégateur.

- [Centre de confidentialité Baidu](https://privacy.baidu.com/policy)
- [Documentation Baidu AI Cloud Qianfan](https://cloud.baidu.com/doc/WENXINWORKSHOP/)

### StepFun

Peut être utilisé via l’API officielle StepFun, un point de terminaison personnalisé ou un agrégateur.

- [Plateforme ouverte StepFun](https://platform.stepfun.com/)

Utilisez le contrat de service, la politique de confidentialité et les conditions développeur affichés dans la console StepFun.

### ModelScope

Peut être proposé comme service d’hébergement de modèles ou d’inférence.

- [Site officiel ModelScope](https://modelscope.cn/)

Examinez les conditions de service et la politique de confidentialité de ModelScope ainsi que la fiche et la licence du modèle concerné.

### SiliconFlow

Peut être proposé comme plateforme d’agrégation de modèles et d’inférence.

- [Site officiel SiliconFlow](https://siliconflow.cn/)

Examinez sa politique de confidentialité, ses conditions de service, les conditions du service de modèles et les règles des fournisseurs de modèles amont.

### OpenRouter

Peut être proposé comme agrégateur mondial de modèles ; le fournisseur amont choisi peut aussi traiter les entrées et sorties.

- [Politique de confidentialité OpenRouter](https://openrouter.ai/privacy)
- [Conditions de service OpenRouter](https://openrouter.ai/terms)

Examinez aussi ses pages concernant les fournisseurs et les données ainsi que la politique du fournisseur de modèles amont choisi.

### Ollama

Généralement utilisé pour des services de modèles locaux ou sur réseau local. Si vous connectez des services cloud officiels ou hébergés à distance, examinez leurs politiques séparément.

- [Politique de confidentialité Ollama](https://ollama.com/privacy)
- [Conditions Ollama](https://ollama.com/terms)

### LM Studio

Généralement utilisé pour des services de modèles sur ordinateur local ou réseau local. Si des téléchargements distants, comptes, synchronisations ou services hébergés sont activés, examinez ses politiques.

- [Confidentialité LM Studio](https://lmstudio.ai/privacy)
- [Conditions LM Studio](https://lmstudio.ai/terms)

### Anthropic / Claude

Palmi ne préconfigure actuellement pas directement le protocole natif d’Anthropic, mais Claude peut être utilisé via OpenRouter, une passerelle d’entreprise ou une couche de compatibilité personnalisée.

- [Politique de confidentialité Anthropic](https://www.anthropic.com/legal/privacy)
- [Conditions et politiques Anthropic](https://www.anthropic.com/legal)

### Google Gemini / Google AI Studio / Vertex AI

Peut être utilisé via les API Google, Vertex AI, un agrégateur ou une passerelle d’entreprise.

- [Politique de confidentialité Google](https://policies.google.com/privacy)
- [Notice de confidentialité Google Cloud](https://cloud.google.com/terms/cloud-privacy-notice)
- [Conditions supplémentaires Google AI / Gemini API](https://ai.google.dev/terms)

### Mistral AI

Peut être utilisé via l’API officielle Mistral, un agrégateur ou une passerelle d’entreprise.

- [Centre juridique Mistral AI](https://legal.mistral.ai/terms)
- [Politique de confidentialité Mistral AI](https://legal.mistral.ai/terms/privacy-policy)

### Meta / Llama

Généralement utilisé via un hébergeur tiers, un fournisseur cloud, un agrégateur, un déploiement local ou une passerelle d’entreprise. Une licence de modèle publique n’est pas une politique de confidentialité du service d’hébergement.

- [Politique de confidentialité Meta](https://www.facebook.com/privacy/policy/)
- [Site officiel Llama](https://www.llama.com/)

Examinez aussi la politique de l’hébergeur réel, du fournisseur cloud ou du responsable du déploiement local.

### xAI / Grok

Peut être utilisé via l’API officielle, un agrégateur ou une passerelle d’entreprise.

- [Politique de confidentialité xAI](https://x.ai/legal/privacy-policy)
- [Conditions de service xAI](https://x.ai/legal/terms-of-service)

### Cohere

Peut être utilisé via l’API officielle Cohere, un agrégateur ou une passerelle d’entreprise.

- [Politique de confidentialité Cohere](https://cohere.com/privacy)
- [Conditions d’utilisation Cohere](https://cohere.com/terms-of-use)

### Hugging Face / Inference Providers

Peut être utilisé pour télécharger des modèles, effectuer de l’inférence hébergée, utiliser Spaces ou des fournisseurs d’inférence tiers.

- [Politique de confidentialité Hugging Face](https://huggingface.co/privacy)
- [Conditions de service Hugging Face](https://huggingface.co/terms-of-service)

Examinez aussi les règles du fournisseur d’inférence réel et la licence du modèle concerné.

### Together AI / Fireworks AI / Groq / Replicate / Perplexity / AI21 Labs

Ces services peuvent être utilisés via des points de terminaison personnalisés, des agrégateurs, SDK, passerelles d’entreprise ou voies d’hébergement amont.

- [Confidentialité Together AI](https://www.together.ai/privacy)
- [Confidentialité Fireworks AI](https://fireworks.ai/privacy)
- [Politique de confidentialité Groq](https://groq.com/privacy-policy/)
- [Confidentialité Replicate](https://replicate.com/privacy)
- [Politique de confidentialité Perplexity](https://www.perplexity.ai/hub/legal/privacy-policy)
- [Politique de confidentialité AI21 Labs](https://www.ai21.com/privacy-policy)

### iFlytek Spark / Huawei Cloud Pangu / SenseTime / Baichuan / 01.AI / Xiaomi / Meituan et autres fournisseurs

Peuvent être utilisés via un point de terminaison personnalisé, une place de marché cloud, une passerelle d’entreprise, un déploiement local ou un agrégateur. Les règles applicables varient selon le compte, la région, la forme du service et l’hébergeur.

- [Confidentialité de la plateforme ouverte iFlytek](https://www.xfyun.cn/doc/policy/privacy.html)
- [Confidentialité Huawei Cloud](https://www.huaweicloud.com/declaration/sa_prp.html)
- [Politique de confidentialité Xiaomi](https://privacy.mi.com/all/zh_CN/)

Pour Meituan LongCat, Baichuan, 01.AI, SenseTime et les services similaires, utilisez la dernière politique affichée sur le site officiel, la plateforme ouverte ou la console de services de modèles du fournisseur.

Si un service n’est pas mentionné ci-dessus, appliquez la même règle : confirmez le propriétaire du point de terminaison, l’entité du service, le fournisseur amont, la région applicable, la politique de journalisation et d’entraînement, les méthodes de suppression et d’exportation, les coûts et les limites de conformité.

## 10. Déclaration de l’utilisateur

1. Je comprends que Palmi est une application d’agent privilégiant le traitement local et une interface de connexion aux modèles, et que sa conception actuelle n’utilise pas de base de données centralisée côté serveur exploitée par Palmi pour les contenus des discussions, les fichiers d’espace de travail, les pièces jointes ou les clés API.
2. Je comprends que, lorsque je configure ou utilise un modèle tiers, un agrégateur, une source de recherche, un service système, une passerelle d’entreprise, un point de terminaison auto-hébergé local ou distant ou un autre outil, le contenu que je choisis d’envoyer et les métadonnées nécessaires peuvent être traités par ce service.
3. Je comprends que la conservation des données par les tiers, leur utilisation pour l’entraînement, le routage amont, les transferts transfrontaliers, les demandes de suppression, la sécurité des comptes, les coûts et le règlement des différends sont régis par les politiques actuelles du tiers et mon accord avec lui.
4. Je ne soumettrai des informations personnelles, documents d’entreprise, données de clients, fichiers, images, code ou autres contenus que si je dispose des droits, autorisations et fondements de conformité suffisants, et je recourrai à un examen humain dans les situations à haut risque.
5. Si je n’accepte pas cette notice ou n’ai pas confirmé la politique du fournisseur choisi, je peux interrompre la configuration du modèle ou revenir en arrière pour modifier mon choix.

Ce document est destiné à l’information de l’utilisateur dans le produit et à sa prise de connaissance des opérations. Il ne constitue pas un conseil juridique individualisé pour un utilisateur, une organisation, un secteur ou une juridiction. Avant toute publication officielle, soumission à une boutique d’applications, commercialisation ou utilisation dans un secteur réglementé, un examen par des professionnels qualifiés dans les juridictions concernées est recommandé.
