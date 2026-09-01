# Signer Nexa Portfolio avec ton compte Apple

L’IPA produit par GitHub Actions est réellement compilé mais volontairement non signé. Il contient le bundle identifier `com.msoumaya2019.nexaportfolio`.

## Méthode recommandée : Xcode

1. Ouvre `NexaPortfolio.xcodeproj` sur un Mac.
2. Dans **NexaPortfolio > Signing & Capabilities**, sélectionne ton équipe Apple.
3. Conserve `com.msoumaya2019.nexaportfolio` si cet identifiant est disponible dans ton compte, sinon remplace-le.
4. Branche ton iPhone et lance l’application, ou utilise **Product > Archive > Distribute App**.

Xcode crée automatiquement le certificat, le profil de provisioning et la signature compatibles.

## Re-signer directement l’IPA compilé

Il te faut :

- un Mac ;
- un certificat Apple Development ou Apple Distribution présent dans le Trousseau ;
- un fichier `.mobileprovision` correspondant exactement au bundle identifier de l’application et à l’appareil cible si nécessaire.

Liste les identités disponibles :

```bash
security find-identity -v -p codesigning
```

Puis lance :

```bash
chmod +x scripts/resign-ipa.sh
scripts/resign-ipa.sh \
  NexaPortfolio-unsigned.ipa \
  "Apple Development: TON NOM (TEAMID)" \
  MonProfil.mobileprovision
```

Le fichier `NexaPortfolio-unsigned-signed.ipa` sera créé à côté de l’original. Le script vérifie la signature avant de terminer.

Un IPA signé avec un compte Apple gratuit expire généralement plus rapidement qu’un build utilisant un abonnement Apple Developer. Les règles exactes sont imposées par Apple et peuvent évoluer.
