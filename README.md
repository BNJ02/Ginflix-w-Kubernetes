# Kubernetes Project: Deploy GINFLIX APP 🚀

## Ginflix architecture

![ginflix-architecture](./ginflix.png)

## Files provided 📦

A `ginflix.zip` is provided with 4 exported Docker images:
- ginflix-backend, app exposing and running on port `8080`
- ginflix-streamer, app exposing and running on port `8080`
- ginflix-frontend, app exposing and running on port `80`
- ginflix-frontend-admin, app exposing and running on port `80`

The backend and streamer endpoints are documented in `openapi.yml`.

How to load the images locally:
- Unzip the archive and you should find one or more `.tar` image files.
- For each image tarball, run: `docker load -i <image-file>.tar` 🙂
- Check they are available: `docker images | grep ginflix`

If you prefer using a registry instead, you can push these images to a registry you control and reference them in your Kubernetes manifests.

## ENV variables to use 🔧

These are environment variables used by the components:

- MONGO_URI= MongoDB connection string (e.g., `mongodb://mongo-0.mongo:27017/ginflix`)
- GARAGE_BUCKET=<to_be_provided> Name of the S3 bucket used by the streamer
- GARAGE_ENDPOINT=<to_be_provided> S3-compatible endpoint 
- GARAGE_ACCESS_KEY=<to_be_provided> Access key for the S3-compatible storage
- GARAGE_SECRET_KEY=<to_be_provided> Secret key for the S3-compatible storage
- BACKEND_URL= Public URL of the backend service (what frontends calls)
- STREAM_URL= Public URL of the streamer service (what frontends uses for media)
- GARAGE_USE_SSL=false Whether to use HTTPS to reach the Garage/S3 endpoint
- AUTH_DISABLED=true Auth is disabled for this project

## Instructions 🙂

You need to create Kubernetes manifests to deploy this app. Create a namespace if you like (e.g., `ginflix`).

Provide at least manifests for:
- Services (ClusterIP/NodePort depending on your choice)
- Deployments: 3 replicas for backend and streamer
- StatefulSet for MongoDB (with PersistentVolumeClaim)

Options/Bonus:
- Add Horizontal Pod Autoscaler (HPA) for backend/streamer
- Add ConfigMap and Secrets for configuration

Validation checklist 🧪
- Pods are Running and Ready: `kubectl get pods -o wide`
- Services expose the right ports: `kubectl get svc`
- Frontend can call backend and streamer (env vars point to the correct URLs)
- Data persists in MongoDB after pod restarts

## Remarks with kind (Kubernetes in Docker) 🐳

If you are using kind, there is one very important particularity when exposing services to your host machine:

- kind nodes run as Docker containers on a private Docker network.
- A Service of type NodePort opens a port on the node (inside the Docker container), NOT directly on your host.
- Therefore, NodePort is NOT reachable from your host unless you map host ports to the node container ports.

You have a few options to access services from your host:

1) Port-forward (quickest for demos) 💨
   - `kubectl port-forward svc/<service-name> <hostPort>:<servicePort>`
   - Example: `kubectl port-forward svc/ginflix-frontend 8080:80`
   - Pros: simple; Cons: not “cluster-realistic”.

2) Create your kind cluster with extraPortMappings 🔌
   - When creating the cluster, provide a config that maps host ports to the node container. Then you can use NodePort services and reach them from your host.

   Example kind config (save as `kind-config.yaml`):
   ```yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   nodes:
     - role: control-plane
       extraPortMappings:
         # Frontend (Service NodePort 30080 → containerPort 30080)
         - containerPort: 30080
           hostPort: 30080
           protocol: TCP
         # Backend (Service NodePort 30081 → containerPort 30081)
         - containerPort: 30081
           hostPort: 30081
           protocol: TCP
         # Streamer (Service NodePort 30082 → containerPort 30082)
         - containerPort: 30082
           hostPort: 30082
           protocol: TCP
   ```

   Create the cluster:
   - `kind create cluster --name ginflix --config kind-config.yaml`

   In your Service manifests, set fixed `nodePort`s that match the above (e.g., 30080/30081/30082). Now from your host you can browse:
   - Frontend: http://localhost:30080
   - Backend: http://localhost:30081
   - Streamer: http://localhost:30082

Why this is needed (the particularity) 💡
- kind runs Kubernetes nodes inside Docker containers.
- NodePort binds inside those containers, not on your host.
- Host access requires Docker port publishing, which is exactly what `extraPortMappings` does when creating the cluster.

Happy shipping! 🎉