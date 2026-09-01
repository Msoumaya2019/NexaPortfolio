# Nexa Portfolio pour iOS

Nexa Portfolio est une application SwiftUI originale de suivi d’investissements. Elle fonctionne localement, sans compte, abonnement ni limite artificielle sur le nombre de portefeuilles, positions, transactions ou listes de suivi.

## Fonctions incluses

- plusieurs portefeuilles et listes de suivi ;
- portefeuille virtuel « Tous les portefeuilles » avec positions, liquidités, gains et dividendes consolidés ;
- conversion automatique vers une devise globale configurable ;
- achats, ventes et dividendes avec historique ;
- calcul du prix moyen, de la valeur et des gains/pertes ;
- conversion indicative des devises vers la devise du portefeuille ;
- recherche d’actions, ETF, indices et cryptomonnaies ;
- actualisation manuelle des cours ;
- actualisation automatique à l’ouverture lorsque les cours ont plus de 15 minutes ;
- dividendes sur douze mois, rendement en pourcentage, dernier versement et revenu annuel estimé pour chaque titre ;
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

La version 1.0 interroge des endpoints publics Yahoo Finance sans clé API. Ils peuvent être retardés, modifiés ou temporairement indisponibles et ne conviennent pas à une distribution commerciale sans vérifier les conditions d’utilisation. Pour une publication App Store, remplace `MarketDataClient` par un fournisseur officiel disposant d’un contrat et d’une API documentée.

Les données et calculs sont indicatifs et ne constituent pas un conseil financier.
