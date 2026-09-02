# Nexa Portfolio pour iOS

Nexa Portfolio est une application SwiftUI originale de suivi d’investissements. Elle fonctionne localement, sans compte, abonnement ni limite artificielle sur le nombre de portefeuilles, positions, transactions ou listes de suivi.

## Fonctions incluses

- plusieurs portefeuilles et listes de suivi ;
- achats, ventes et dividendes avec historique ;
- calcul du prix moyen, de la valeur et des gains/pertes ;
- conversion indicative des devises vers la devise du portefeuille ;
- recherche d’actions, ETF, indices et cryptomonnaies ;
- actualisation manuelle des cours ;
- actualisation automatique à l’ouverture lorsque les cours ont plus de 15 minutes ;
- dividendes sur douze mois, rendement en pourcentage, dernier versement et revenu annuel estimé pour chaque titre ;
- prochaine date de détachement affichée dans la fiche de chaque action, avec une estimation fondée sur la cadence récente lorsqu’aucune date annoncée n’est disponible ;
- estimation du montant du prochain dividende selon le nombre d’actions détenues et la devise du portefeuille ;
- synthèse des dividendes propre à chaque portefeuille ;
- correction manuelle du prix moyen ou de la valeur totale d’achat de chaque position ;
- connexion Trading 212 Démo ou Réel en lecture seule, avec clés conservées dans le trousseau iOS ;
- synchronisation sans doublons des achats, ventes et dividendes Trading 212, puis rapprochement des positions et liquidités au lancement ou au retour dans l’app ;
- import sans doublons des achats, ventes et dividendes DEGIRO à partir des relevés CSV officiels, sans transmettre les identifiants du compte ;
- import local des confirmations d’exécution et relevés de dividendes PDF Trade Republic, avec détection des doublons et sans identifiants de connexion ;
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

La version 1.6 interroge des endpoints publics Yahoo Finance sans clé API. Ils peuvent être retardés, modifiés ou temporairement indisponibles et ne conviennent pas à une distribution commerciale sans vérifier les conditions d’utilisation. Pour une publication App Store, remplace `MarketDataClient` par un fournisseur officiel disposant d’un contrat et d’une API documentée.

## Connexion Trading 212

Dans **Réglages > Trading 212**, choisis le compte Démo ou Réel, puis saisis la clé API et le secret générés dans Trading 212. Utilise uniquement des autorisations de lecture pour les informations du compte, le portefeuille et l’historique. Les identifiants sont enregistrés dans le trousseau iOS et ne sont jamais inclus dans le projet ou envoyés vers GitHub.

Un portefeuille Trading 212 séparé est recommandé afin d’éviter qu’une ancienne saisie manuelle représente deux fois la même opération. La synchronisation importe les exécutions d’ordres et les dividendes avec leurs identifiants externes, puis utilise les positions ouvertes du courtier pour réconcilier les quantités et prix moyens. Lorsque l’option automatique est active, une vérification peut avoir lieu au lancement ou au retour dans l’application, avec un intervalle minimal de quinze minutes. Pour respecter les limites de l’API, l’import initial traite au maximum 300 ordres et 300 dividendes récents et s’arrête après 90 secondes si le service ne répond pas assez vite.

Les données et calculs sont indicatifs et ne constituent pas un conseil financier.

## Import DEGIRO

DEGIRO ne fournit actuellement aucune API officielle permettant de connecter un compte à une application tierce et indique que les connecteurs non officiels ne sont pas pris en charge. Nexa Portfolio ne demande donc jamais le nom d’utilisateur, le mot de passe ou le code 2FA DEGIRO.

Dans **Réglages > DEGIRO**, crée ou sélectionne un portefeuille, puis choisis les fichiers CSV exportés depuis DEGIRO :

1. **Courriel > Transactions** pour les achats et les ventes ;
2. **Courriel > Compte** pour les dividendes versés.

Sélectionne la période la plus large possible lors du premier export. Dans le sélecteur, coche le relevé Transactions et le relevé Compte, puis appuie sur **Ouvrir** ; tu peux aussi les importer séparément. Le sélecteur natif copie d’abord les fichiers dans un espace temporaire privé afin qu’ils restent lisibles avec iCloud Drive et les autres fournisseurs de l’app Fichiers, puis les supprime après l’import. Il accepte également les CSV qu’iOS classe avec un type générique, puis leur contenu est contrôlé avant l’import. Les fichiers français, anglais et néerlandais les plus courants sont reconnus, ainsi que les nombres utilisant une virgule décimale. Chaque ligne reçoit une empreinte stable afin qu’un relevé importé une seconde fois ne crée pas de doublon. Les symboles boursiers sont recherchés à partir de l’ISIN ; lorsqu’aucune correspondance n’est trouvée, l’ISIN reste affiché et le titre peut nécessiter une correction manuelle.

## Import Trade Republic

Trade Republic ne fournit pas d’API publique pour consulter le portefeuille. Dans **Réglages > Trade Republic**, Nexa Portfolio importe donc localement les documents PDF officiels téléchargés depuis le profil Trade Republic. L’application ne demande jamais le numéro de téléphone, le PIN, le code 2FA ou un jeton de session.

Depuis le profil Trade Republic, ouvre une transaction exécutée puis sa liste de documents. Télécharge la **confirmation d’exécution** pour un achat ou une vente, ou le **relevé de dividende**. Dans Nexa Portfolio, sélectionne un ou plusieurs PDF puis appuie sur **Ouvrir**. Les informations préalables sur les coûts et les documents sans opération exécutée sont ignorés. L’import reconnaît les modèles français ainsi que plusieurs modèles européens courants, extrait l’ISIN, la quantité, le cours, les frais et le montant net versé, puis utilise une empreinte stable pour empêcher les doublons.

Les documents sont traités sur l’iPhone. Seul l’ISIN est ensuite utilisé lors de la recherche du symbole boursier et des cours. Comme Trade Republic peut modifier la mise en page de ses PDF, conserve les originaux et vérifie les premières opérations importées.
