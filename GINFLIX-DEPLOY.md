# Guide de déploiement Ginflix (Garage sur kind)

Ce document décrit la version fonctionnelle fournie dans ce dépôt :

1. Le contenu du manifeste Kubernetes `ginflix-manifest.yaml`.
2. Les étapes pour créer un cluster kind et charger les images.
3. Les vérifications à exécuter pour confirmer le bon fonctionnement.

---

## 1. Anatomie de `ginflix-manifest.yaml`

Le fichier multi-document assemble toute la pile Ginflix. Chaque section `---` représente une ressource.

### 1.1 Configuration partagée

- **Namespace `ginflix`** : espace d’isolation.
- **ConfigMap `ginflix-config`** : URLs internes/externes, URI Mongo, configuration Garage (endpoint `garage-service.ginflix.svc.cluster.local:3901`, bucket `ginflix-media`).
- **Secret `ginflix-secrets`** : Access Key / Secret Key Garage (à régénérer pour un usage réel).

### 1.2 Garage (S3-compatible)

- **PVC `ginflix-garage-data`** : volume persistant de 20 Gi.
- **ConfigMap `garage-config`** : fichier `garage.toml` avec bind des ports 3900/3901/3902 et secret RPC.
- **Service `garage-service`** : expose RPC, API S3 et UI web à l’intérieur du cluster.
- **Deployment `garage`** : image `dxflrs/garage:v0.9.4`, monte le PVC et le configmap, probes TCP.

### 1.3 MongoDB

- **Services `ginflix-mongo` (headless) et `ginflix-mongo-svc`** : découverte et accès standard.
- **StatefulSet `ginflix-mongo`** : 1 replica (`mongo:6.0`), PVC de 10 Gi sur `/data/db`.

### 1.4 Applications Ginflix

- **Backend** : `Deployment` 3 réplicas + `HPA` (3→6), `Service` NodePort 30081.
- **Streamer** : `Deployment` 3 réplicas + `HPA` (3→6), `Service` NodePort 30082.
- **Frontend utilisateur** : `Deployment` 2 réplicas, `Service` NodePort 30080.
- **Frontend admin** : `Deployment` 2 réplicas, `Service` NodePort 30083.

Tous les pods consomment `ginflix-config` / `ginflix-secrets` pour accéder à MongoDB et Garage.

---

## 2. Préparer le cluster kind

### 2.1 Prérequis

- Docker, kind, kubectl installés.
- Archive `ginflix.zip` extraite (fichiers `ginflix-backend.tar`, `ginflix-streamer.tar`, `ginflix-frontend.tar`, `ginflix-frontend-admin.tar`).
- Accès réseau pour télécharger l’image Garage.

### 2.2 Créer le cluster

```bash
kind delete cluster --name kind 2>/dev/null || true
kind create cluster --name kind --config kind-config.yaml
```

`kind-config.yaml` publie sur l’hôte les NodePorts 30080–30083.

Contrôles rapides :

```bash
kubectl cluster-info --context kind-kind
kubectl get nodes
```

### 2.3 Charger les images Ginflix dans kind

```bash
docker load -i ginflix-backend.tar
docker load -i ginflix-streamer.tar
docker load -i ginflix-frontend.tar
docker load -i ginflix-frontend-admin.tar

kind load docker-image ginflix-backend:latest --name kind
kind load docker-image ginflix-streamer:latest --name kind
kind load docker-image ginflix-frontend:latest --name kind
kind load docker-image ginflix-frontend-admin:latest --name kind
```

---

## 3. Déployer Ginflix + Garage

1. **Appliquer le manifeste**

   ```bash
   kubectl apply -f ginflix-manifest.yaml
   kubectl wait --for=condition=Ready pods --all -n ginflix --timeout=240s
   ```

2. **Initialiser Garage** (les pods attendent la clé `GK98caf7a206f7236efbaf7fbe / 5355…` définie dans le `Secret`)

   ```bash
   # Identifier l'ID du nœud (champ ID)
   kubectl exec -n ginflix deploy/garage -- \
     /garage --config /etc/garage/garage.toml status

   # Assigner la capacité (remplacez <ID>) puis appliquer la version proposée
   kubectl exec -n ginflix deploy/garage -- \
     /garage --config /etc/garage/garage.toml layout assign -z dc1 -c 1TiB <ID>

   kubectl exec -n ginflix deploy/garage -- \
     /garage --config /etc/garage/garage.toml layout show
   kubectl exec -n ginflix deploy/garage -- \
     /garage --config /etc/garage/garage.toml layout apply --version X

   # Importer la clé et préparer le bucket
   kubectl exec -n ginflix deploy/garage -- \
     /garage --config /etc/garage/garage.toml key import --yes \
     GK98caf7a206f7236efbaf7fbe \
     5355b15d79ea2cf6a88f0c09462bfdbd41d6352bb238d5c97a398343dc39fefa

   kubectl exec -n ginflix deploy/garage -- \
     /garage --config /etc/garage/garage.toml bucket create ginflix-media || true

   kubectl exec -n ginflix deploy/garage -- \
     /garage --config /etc/garage/garage.toml bucket allow ginflix-media \
     --key GK98caf7a206f7236efbaf7fbe --read --write
   ```

   > En production, créez une nouvelle clé (`garage key create`), mettez à jour `ginflix-manifest.yaml`, réappliquez le manifeste et rejouez les commandes `bucket allow`.

---

## 4. Vérifications et tests

### 4.1 Etat des ressources

```bash
kubectl get pods -n ginflix
kubectl get svc -n ginflix
kubectl get pvc -n ginflix
```

### 4.2 Logs

```bash
kubectl logs -n ginflix deployment/ginflix-backend
kubectl logs -n ginflix deployment/ginflix-streamer
kubectl logs -n ginflix deploy/garage
```

### 4.3 Tests fonctionnels

```bash
curl http://localhost:30081/api/videos   # renvoie [] tant qu'aucune vidéo n'est importée
curl -I http://localhost:30080           # frontend utilisateur
curl -I http://localhost:30082           # streamer
```

### 4.4 Diagnostics Garage

```bash
kubectl exec -n ginflix deploy/garage -- \
  /garage --config /etc/garage/garage.toml layout show

kubectl exec -n ginflix deploy/garage -- \
  /garage --config /etc/garage/garage.toml bucket list
```

### 4.5 Accès

- Frontend utilisateur : [http://localhost:30080](http://localhost:30080)
- Frontend administrateur : [http://localhost:30083](http://localhost:30083)
- API backend : [http://localhost:30081](http://localhost:30081)
- Streamer : [http://localhost:30082](http://localhost:30082)

---

## 5. Maintenance / nettoyage

- **Redémarrer un composant**

  ```bash
  kubectl rollout restart deployment/ginflix-backend -n ginflix
  kubectl rollout restart deployment/ginflix-streamer -n ginflix
  kubectl rollout restart deploy/garage -n ginflix
  ```

- **Supprimer entièrement l’environnement**

  ```bash
  kubectl delete namespace ginflix
  kind delete cluster --name kind
  ```

> Supprimer le namespace efface aussi le PVC `ginflix-garage-data`. Lors d’un redeploiement, rejouez l’étape d’initialisation Garage (section 3.2).

---

Avec ces étapes, la plateforme Ginflix (MongoDB + Garage + services applicatifs) est opérationnelle sur un cluster kind local.
