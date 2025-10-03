# Déploiement complet de Ginflix sur kind

Ce document décrit en détail comment démarrer un cluster Kubernetes local avec kind, déployer toutes les ressources nécessaires à l'application Ginflix (MongoDB, Garage, backend, streamer et frontaux) et vérifier le bon fonctionnement de la plateforme. Toutes les instructions sont basées sur les fichiers fournis dans ce dépôt, principalement `kind-config.yaml` et `ginflix-manifests.yaml`.

---

## 1. Prérequis

- Docker installé et fonctionnel (utilisé par kind et pour charger les images Ginflix/ Garage).
- kind et kubectl disponibles dans le PATH.
- Les fichiers suivants présents dans le répertoire du projet :
  - `ginflix-backend.tar`, `ginflix-streamer.tar`, `ginflix-frontend.tar`, `ginflix-frontend-admin.tar`
  - `kind-config.yaml`
  - `ginflix-manifests.yaml`
- Aucun cluster kind actif portant le même nom (`ginflix`). Supprimez les clusters existants le cas échéant :
  ```bash
  kind get clusters
  kind delete cluster --name ginflix  # si le cluster existe déjà
  ```

---

## 2. Procédure complète depuis zéro

> Toutes les commandes ci-dessous sont à lancer depuis la racine du projet (`/home/bnj/Kubernetes/project`).

### Étape 1 — Charger les images Docker fournies

```bash
docker load -i ginflix-backend.tar
docker load -i ginflix-streamer.tar
docker load -i ginflix-frontend.tar
docker load -i ginflix-frontend-admin.tar
docker pull dxflrs/amd64_garage:v0.7.0-rc1    # image Garage utilisée par les manifestes
```

### Étape 2 — Créer le cluster kind

Le fichier `kind-config.yaml` configure les NodePorts (30080-30083) pour exposer frontal, backend et streamer sur l’hôte.

```bash
kind create cluster --name ginflix --config kind-config.yaml
```

### Étape 3 — Pousser les images Ginflix dans le cluster kind

```bash
kind load docker-image --name ginflix ginflix-backend:latest
kind load docker-image --name ginflix ginflix-streamer:latest
kind load docker-image --name ginflix ginflix-frontend:latest
kind load docker-image --name ginflix ginflix-frontend-admin:latest
kind load docker-image --name ginflix dxflrs/amd64_garage:v0.7.0-rc1
```

### Étape 4 — Déployer les ressources Kubernetes

```bash
kubectl apply -f ginflix-manifests.yaml
```

Les éléments importants créés :
- Namespace `ginflix`.
- ConfigMap `ginflix-config` (variables d’environnement partagées : Mongo URI, backend/ streamer internes, endpoint Garage, désactivation auth).
- Secret `ginflix-garage-credentials` (clé/secret S3).
- StatefulSets `mongo` et `garage` avec PVC de 5 Gi.
- Deployments `ginflix-backend`, `ginflix-streamer`, `ginflix-frontend`, `ginflix-frontend-admin`.
- Services NodePort exposés :
  - Front utilisateur : `http://localhost:30080`
  - Backend : `http://localhost:30081`
  - Streamer : `http://localhost:30082`
  - Front admin : `http://localhost:30083`

### Étape 5 — Initialiser MongoDB

Mongo est déployé comme StatefulSet single-node. Activez le replica set `rs0` :

```bash
kubectl exec -n ginflix mongo-0 -- \
  mongosh --quiet --eval 'rs.initiate({_id: "rs0", members: [{ _id: 0, host: "mongo-0.mongo.ginflix.svc.cluster.local:27017" }]})'
```

### Étape 6 — Initialiser Garage (stockage S3 compatible)

1. **Identifier le nœud Garage** :
   ```bash
   kubectl exec -n ginflix garage-0 -- /garage status
   ```
   Notez l’identifiant hexadécimal retourné (ex. `dd336444c6e3f44f`).

2. **Assigner une capacité et appliquer la topologie** :
   ```bash
   kubectl exec -n ginflix garage-0 -- /garage layout assign -z dc1 -c 1 <node_id>
   kubectl exec -n ginflix garage-0 -- /garage layout apply --version 1
   ```

3. **Importer la paire de clefs S3 prévue par `ginflix-garage-credentials`** :
   ```bash
   kubectl exec -n ginflix garage-0 -- \
     /garage key import -n ginflix-service \
     f3d888dc088576d4cff37568 44569c5896eaa42f235f67bc
   ```

4. **Créer le bucket Ginflix et autoriser la clef** :
   ```bash
   kubectl exec -n ginflix garage-0 -- /garage bucket create ginflix
   kubectl exec -n ginflix garage-0 -- \
     /garage bucket allow ginflix \
     --key f3d888dc088576d4cff37568 --read --write --owner
   ```

À l’issue de ces actions, le backend et le streamer peuvent lire/écrire dans Garage via l’endpoint `garage.ginflix.svc.cluster.local:3900`.

### Étape 7 — Vérifications générales

1. **Etat des pods**
   ```bash
   kubectl get pods -n ginflix
   ```
   Tous les pods doivent être `Running` avec `READY 1/1`.

2. **Services et NodePorts**
   ```bash
   kubectl get svc -n ginflix
   ```
   Confirmer que les NodePorts `30080` à `30083` sont listés.

3. **Disponibilité applicative**
   ```bash
   # Backend REST
   curl http://localhost:30081/api/videos

   # Front utilisateur / admin (réponse HTTP 200 attendue)
   curl -I http://localhost:30080
   curl -I http://localhost:30083

   # Streamer (endpoint proxy Garage)
   curl -I 'http://localhost:30082/stream?file=test'
   ```

4. **Garage**
   ```bash
   kubectl exec -n ginflix garage-0 -- /garage bucket list
   kubectl exec -n ginflix garage-0 -- /garage key info f3d888dc088576d4cff37568
   ```
   Vous devez voir le bucket `ginflix` et la clef avec les droits `RWO`.

### Étape 8 — Test d’un flux complet (optionnel)

1. Ouvrez `http://localhost:30083`, importez une vidéo via l’interface admin. Le backend déclenche l’encodage et pousse les artefacts (thumbnail + HLS) dans Garage.
2. Sur `http://localhost:30080`, la galerie doit afficher la vidéo avec une miniature (servie par le streamer via le NodePort 30082).
3. Surveillez les logs pour diagnostiquer :
   ```bash
   kubectl logs -n ginflix deployment/ginflix-backend
   kubectl logs -n ginflix deployment/ginflix-streamer
   ```

---

## 3. Détails du manifeste `ginflix-manifests.yaml`

### 3.1 Configuration partagée
- `ginflix-config` fournit :
  - `MONGO_URI` : `mongodb://mongo-0.mongo.ginflix.svc.cluster.local:27017/ginflix`
  - `BACKEND_URL` / `STREAM_URL` : URLs internes des services (pour communication inter-pods).
  - `GARAGE_ENDPOINT` : `garage.ginflix.svc.cluster.local:3900` (sans schéma, requis par le client Garage S3).
  - `GARAGE_BUCKET`, `GARAGE_USE_SSL`, `AUTH_DISABLED`.
- `ginflix-garage-credentials` : clefs S3 utilisées par backend/ streamer.

### 3.2 Garage
- `ConfigMap garage-config` embarque le fichier `garage.toml` (ports RPC/S3/Web et secret RPC).
- `StatefulSet garage` : 1 réplique, PVC `ReadWriteOnce` de 5 Gi, init container BusyBox pour créer l’arborescence `/var/lib/garage`.
- `Service garage` : ports 3900 (S3), 3901 (RPC), 3902 (mode site).

### 3.3 MongoDB
- `StatefulSet mongo` : 1 réplique, image officielle `mongo:6.0`, arguments `--replSet rs0`.
- `Service mongo` : headless (`clusterIP: None`) pour permettre `mongo-0.mongo.ginflix.svc.cluster.local`.

### 3.4 Backend et Streamer
- Deployments à 3 réplicas.
- Services NodePort (30081/30082) pour accès depuis l’hôte.
- Variables d’environnement issues de la ConfigMap et du Secret.

### 3.5 Frontaux
- `ginflix-frontend` (2 réplicas) et `ginflix-frontend-admin` (1 réplique) sont des containers NGINX.
- NodePorts 30080 et 30083 exposés.
- Les variables `BACKEND_URL` et `STREAM_URL` sont surchargées côté déploiement pour pointer vers `http://localhost:30081` et `http://localhost:30082`, garantissant que les appels depuis le navigateur passent par les NodePorts publisés par kind.

---

## 4. Dépannage rapide

| Symptôme | Diagnostic | Correctif |
| --- | --- | --- |
| Front affiche "NetworkError" | Les frontaux appellent une URL interne `*.svc.cluster.local` inaccessible depuis le navigateur. | Vérifier que les déploiements front injectent bien `BACKEND_URL=http://localhost:30081` et `STREAM_URL=http://localhost:30082` (`kubectl exec ... -- printenv`). |
| Erreur backend "Endpoint url cannot have fully qualified paths" | `GARAGE_ENDPOINT` contient un schéma (`http://...`). | Confirmer que `ginflix-config` expose `garage.ginflix.svc.cluster.local:3900`, redéployer le ConfigMap et redémarrer les pods backend/ streamer. |
| Garage inaccessible | Layout non appliqué ou clef/bucket non créés. | Rejouer les commandes d’assignation (`/garage layout assign/apply`) puis l’import de la clef et la création du bucket. |
| Pods bloqués en `ImagePullBackOff` | Images non disponibles dans le cluster kind. | Refaire les commandes `kind load docker-image --name ginflix <image:tag>`. |

---

En suivant ce guide, vous disposez d’un environnement Ginflix complet, fonctionnel et reproductible sur un cluster kind local. Pensez à supprimer le cluster (`kind delete cluster --name ginflix`) une fois vos tests terminés pour libérer les ressources.
