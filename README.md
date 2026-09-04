# Nexa Portfolio pour iOS

Nexa Portfolio est une application SwiftUI originale de suivi d’investissements. Elle fonctionne localement, sans compte, abonnement ni limite artificielle sur le nombre de portefeuilles, positions, transactions ou listes de suivi.

## Fonctions incluses

- plusieurs portefeuilles et listes de suivi ;
- toutes les positions réunies dans l’écran Aperçu, avec tri par valeur détenue, symbole, rendement du dividende, croissance totale ou croissance sur 24 heures ;
- achats, ventes et dividendes avec historique ;
- calcul du prix moyen, de la valeur et des gains/pertes ;
- conversion indicative des devises vers la devise du portefeuille ;
- recherche d’actions, ETF, indices et cryptomonnaies ;
- actualisation manuelle des cours ;
- actualisation automatique à l’ouverture lorsque les cours ont plus de 15 minutes ;
- dividendes sur douze mois, rendement en pourcentage, dernier versement et revenu annuel estimé pour chaque titre ;
- prochaine date de détachement affichée dans la fiche de chaque action, avec une estimation fondée sur la cadence récente lorsqu’aucune date annoncée n’est disponible ;
- estimation du montant du prochain dividende selon le nombre d’actions détenues et la devise du portefeuille ;
- onglet Dividendes réunissant les prochains dividendes estimés de toutes les positions, classés par date chronologique ;
- synthèse des dividendes propre à chaque portefeuille ;
- correction manuelle du prix moyen ou de la valeur totale d’achat de chaque position ;
- connexion Trading 212 Démo ou Réel en lecture seule, avec clés conservées dans le trousseau iOS ;
- synchronisation sans doublons des achats, ventes et dividendes Trading 212, puis rapprochement des positions et liquidités au lancement ou au retour dans l’app ;
- import sans doublons des achats, ventes et dividendes DEGIRO à partir des relevés CSV officiels, sans transmettre les identifiants du compte ;
- import local de l’export de transactions CSV ou des confirmations et relevés PDF Trade Republic, avec détection des doublons et sans identifiants de connexion ;
- import local de l’historique CSV d’investissements Revolut : achats, ventes, dividendes, corrections fiscales, splits et fusions ;
- connexion non officielle BoursoBank en lecture seule avec validation forte, synchronisation des positions, quantités, PRU, cours et liquidités du PEA ou du compte-titres ;
- conservation chiffrée de la session BoursoBank dans le Trousseau iOS pour une synchronisation silencieuse au lancement et au retour dans l’application ;
- compatibilité avec l’identifiant réel des PEA BoursoBank et le format actuel de l’endpoint de synthèse (correctif 2.0.1) ;
- synchronisation BoursoBank des contrats d’assurance-vie : solde actualisé et supports détaillés lorsqu’ils sont fournis par la page du contrat ;
- avis des analystes avec objectif moyen et consensus sourcés auprès d’Alpha Vantage ;
- avis IA local affiché séparément, avec score, confiance, facteurs favorables et points de vigilance ;
- graphiques de répartition avec Swift Charts ;
- stockage privé sur l’iPhone avec SwiftData ;
- export texte/CSV via la feuille de partage iOS ;
- interface sombre en français et icône originale.

## Prérequis

- macOS avec Xcode 16 ou ultérieur ;
- iOS 17 ou ultérieur ;
- un compte Apple gratuit pour installer sur son propre appareil, ou un abonnement Apple Developer pour une distribution plus durable.

Le bundle identifier fourni est `com.msoumaya2019.nexaportfolio`. Tu peux le conserver si tu l’enregistres dans ton compte Apple Developer, ou le remplacer par un identifiant qui t’appartient avant de signer.

## Compiler et signer directement avec Xcode

1. Ouvre `NexaPortfolio.xcodeproj` dans Xcode.
2. Sélectionne la target **NexaPortfolio**, puis **Signing & Capabilities**.
3. Choisis ton équipe Apple et remplace le bundle identifier.
4. Branche l’iPhone, choisis-le comme destination et lance **Run**.
5. Pour un IPA de distribution : **Product > Archive**, puis **Distribute App** et choisis Development, Ad Hoc ou App Store Connect selon ton profil.

Cette méthode est la plus simple : Xcode compile et applique ta signature en une seule opération.

## Produire un IPA réellement non signé

Depuis un Mac :

```bash
chmod +x scripts/build-unsigned-ipa.sh
scripts/build-unsigned-ipa.sh
```

Le résultat sera créé dans `build/NexaPortfolio-unsigned.ipa`. Cet IPA est compilé, mais ne peut pas être installé avant d’avoir reçu une signature et un profil de provisioning valides.

Pour re-signer cet IPA sur Mac avec ton certificat et ton profil, consulte `SIGNING.md` ou utilise `scripts/resign-ipa.sh`.

## Compiler dans GitHub Actions

Le workflow `.github/workflows/build-unsigned-ipa.yml` fait la même compilation sur un runner macOS :

1. place ce dossier dans un dépôt GitHub ;
2. ouvre l’onglet **Actions** ;
3. lance **Build unsigned IPA** ;
4. télécharge l’artifact **NexaPortfolio-unsigned**.

## Source des cours

La version 2.0 interroge des endpoints publics Yahoo Finance sans clé API. Ils peuvent être retardés, modifiés ou temporairement indisponibles et ne conviennent pas à une distribution commerciale sans vérifier les conditions d’utilisation. Pour une publication App Store, remplace `MarketDataClient` par un fournisseur officiel disposant d’un contrat et d’une API documentée.

## Connexion Trading 212

Dans **Réglages > Trading 212**, choisis le compte Démo ou Réel, puis saisis la clé API et le secret générés dans Trading 212. Utilise uniquement des autorisations de lecture pour les informations du compte, le portefeuille et l’historique. Les identifiants sont enregistrés dans le trousseau iOS et ne sont jamais inclus dans le projet ou envoyés vers GitHub.

Un portefeuille Trading 212 séparé est recommandé afin d’éviter qu’une ancienne saisie manuelle représente deux fois la même opération. La synchronisation importe les exécutions d’ordres et les dividendes avec leurs identifiants externes, puis utilise les positions ouvertes du courtier pour réconcilier les quantités et prix moyens. Lorsque l’option automatique est active, une vérification peut avoir lieu au lancement ou au retour dans l’application, avec un intervalle minimal de quinze minutes. Pour respecter les limites de l’API, l’import initial traite au maximum 300 ordres et 300 dividendes récents et s’arrête après 90 secondes si le service ne répond pas assez vite.

Les données et calculs sont indicatifs et ne constituent pas un conseil financier.

## Avis des analystes et avis IA

Dans **Réglages > Analystes et avis IA**, crée puis enregistre une clé API personnelle Alpha Vantage. La clé reste dans le Trousseau iOS. Sur la fiche de chaque action, Nexa présente ensuite deux catégories volontairement séparées :

1. **Avis des analystes — Alpha Vantage** : objectif moyen, potentiel par rapport au cours et répartition des recommandations fournis par Alpha Vantage ;
2. **Avis IA — Nexa** : score multifactoriel calculé localement à partir des indicateurs disponibles, accompagné de son niveau de confiance et de ses principaux facteurs.

L’avis IA n’invente pas d’objectif de cours et n’est jamais présenté comme une recommandation Alpha Vantage. Les résultats sont mis en cache pendant 24 heures. La couverture dépend du fournisseur : certains titres, ETF ou marchés secondaires peuvent ne pas disposer de données. Ces deux avis sont informatifs, peuvent être incomplets ou erronés et ne constituent pas un conseil financier.

## Import DEGIRO

DEGIRO ne fournit actuellement aucune API officielle permettant de connecter un compte à une application tierce et indique que les connecteurs non officiels ne sont pas pris en charge. Nexa Portfolio ne demande donc jamais le nom d’utilisateur, le mot de passe ou le code 2FA DEGIRO.

Dans **Réglages > DEGIRO**, crée ou sélectionne un portefeuille, puis choisis les fichiers CSV exportés depuis DEGIRO :

1. **Courriel > Transactions** pour les achats et les ventes ;
2. **Courriel > Compte** pour les dividendes versés.

Sélectionne la période la plus large possible lors du premier export. Dans le sélecteur, coche le relevé Transactions et le relevé Compte, puis appuie sur **Ouvrir** ; tu peux aussi les importer séparément. Le sélecteur natif copie d’abord les fichiers dans un espace temporaire privé afin qu’ils restent lisibles avec iCloud Drive et les autres fournisseurs de l’app Fichiers, puis les supprime après l’import. Il accepte également les CSV qu’iOS classe avec un type générique, puis leur contenu est contrôlé avant l’import. Les fichiers français, anglais et néerlandais les plus courants sont reconnus, ainsi que les nombres utilisant une virgule décimale. Chaque ligne reçoit une empreinte stable afin qu’un relevé importé une seconde fois ne crée pas de doublon. Les symboles boursiers sont recherchés à partir de l’ISIN ; lorsqu’aucune correspondance n’est trouvée, l’ISIN reste affiché et le titre peut nécessiter une correction manuelle.

## Import Trade Republic

Trade Republic ne fournit pas d’API publique pour consulter le portefeuille. Dans **Réglages > Trade Republic**, Nexa Portfolio importe donc localement l’export de transactions CSV destiné aux outils de suivi. L’application ne demande jamais le numéro de téléphone, le PIN, le code 2FA ou un jeton de session.

Depuis **Profil > Relevés et export de transactions**, télécharge l’**export CSV pour outils de suivi** sur la période la plus large possible. Dans Nexa Portfolio, sélectionne le CSV puis appuie sur **Ouvrir**. Les lignes `BUY`, `SELL` et `DIVIDEND` sont importées ; les mouvements d’espèces, paiements par carte et intérêts sont ignorés. L’identifiant `transaction_id` empêche les doublons et les colonnes `fee` et `tax` sont prises en compte. Les confirmations d’exécution et relevés de dividendes PDF restent également compatibles.

Les documents sont traités sur l’iPhone. Seul l’ISIN est ensuite utilisé lors de la recherche du symbole boursier et des cours. Comme Trade Republic peut modifier la mise en page de ses PDF, conserve les originaux et vérifie les premières opérations importées.

## Import Revolut

Revolut ne fournit pas d’API publique pour synchroniser automatiquement les actions d’un compte personnel. Dans **Réglages > Revolut**, crée ou sélectionne un portefeuille, puis choisis l’export CSV de tes investissements. Le format reconnu contient les colonnes `Date`, `Ticker`, `Type`, `Quantity`, `Price per share`, `Total Amount`, `Currency` et `FX Rate`.

Nexa importe les achats au marché ou à cours limité, les ventes au marché, stop ou à cours limité, les dividendes, les corrections fiscales de dividendes, les splits et les fusions en titres. Les dépôts, retraits, récompenses, frais de garde et mouvements internes sans titre sont ignorés. Chaque ligne reçoit une empreinte stable afin qu’un même export puisse être réimporté sans créer de doublons.

Le fichier est traité localement sur l’iPhone et aucun numéro de téléphone, PIN, code 2FA ou jeton Revolut n’est demandé. Les ajustements de quantité à prix nul préservent le coût total de la position ; après une fusion entre deux symboles, vérifie néanmoins le prix d’achat moyen et utilise sa correction manuelle si nécessaire.

## Connexion BoursoBank

Dans **Réglages > BoursoBank**, saisis l’identifiant client et le mot de passe, puis valide la demande depuis l’application officielle BoursoBank si elle apparaît. Le mot de passe reste uniquement en mémoire pendant l’authentification et n’est jamais enregistré. L’identifiant, si l’option est activée, et les cookies de la session authentifiée sont conservés dans le Trousseau iOS avec une protection limitée à l’appareil déverrouillé.

Choisis ensuite le PEA, le compte-titres ou l’assurance-vie et crée de préférence un portefeuille BoursoBank séparé. La synchronisation récupère l’état courant : positions ou supports, quantités, prix de revient moyen, dernier cours et liquidités. Pour une assurance-vie dont BoursoBank ne fournit pas le détail exploitable, Nexa crée un support global afin de reporter au minimum le solde actualisé du contrat. Elle ne reconstruit pas l’historique complet des achats, ventes et dividendes passés. Les relevés BoursoBank restent nécessaires pour cet historique.

Lorsque **Synchronisation silencieuse** est active, Nexa essaie d’actualiser le compte au lancement et à chaque retour au premier plan, avec un intervalle minimal de quinze minutes. Il ne s’agit pas d’une exécution serveur permanente : iOS ne garantit pas les tâches en arrière-plan et BoursoBank peut expirer la session ou demander une nouvelle validation forte.

Cette intégration s’appuie sur des interfaces web privées, non documentées et susceptibles de changer. Elle ne contient aucun appel de passage d’ordre ou de virement. Les mécanismes d’authentification et de lecture ont été adaptés en Swift à partir du projet MIT `azerpas/bourso-api`; consulte `THIRD_PARTY_NOTICES.md` pour l’attribution complète.
