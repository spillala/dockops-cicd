APP_NAME := release-api
IMAGE_REPOSITORY ?= docker.io/library/release-api
IMAGE_TAG ?= dev
NAMESPACE ?= dev
KUBECTL ?= microk8s kubectl
HELM ?= microk8s helm3

.PHONY: test build run docker-build docker-push image-import local-deploy helm-template bootstrap-local deploy-dev port-forward

test:
	go test ./...

build:
	mkdir -p bin
	go build -o bin/release-api ./cmd/release-api

run:
	APP_ENV=dev APP_PORT=8080 go run ./cmd/release-api

docker-build:
	docker build \
		--build-arg APP_VERSION=$(IMAGE_TAG) \
		--build-arg GIT_SHA=$$(git rev-parse --short HEAD 2>/dev/null || echo local) \
		--build-arg BUILD_TIME=$$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		-t $(IMAGE_REPOSITORY):$(IMAGE_TAG) .

docker-push:
	docker push $(IMAGE_REPOSITORY):$(IMAGE_TAG)

image-import:
	docker save $(IMAGE_REPOSITORY):$(IMAGE_TAG) | microk8s images import

local-deploy: docker-build image-import deploy-dev

helm-template:
	$(HELM) template $(APP_NAME) ./deploy/helm/release-api -f ./deploy/helm/release-api/values-dev.yaml

bootstrap-local:
	microk8s enable dns ingress registry hostpath-storage
	$(KUBECTL) create namespace argocd --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -

deploy-dev:
	$(HELM) upgrade --install $(APP_NAME) ./deploy/helm/release-api \
		-n $(NAMESPACE) \
		-f ./deploy/helm/release-api/values-dev.yaml \
		--set image.repository=$(IMAGE_REPOSITORY) \
		--set image.tag=$(IMAGE_TAG)

port-forward:
	$(KUBECTL) -n $(NAMESPACE) port-forward svc/$(APP_NAME) 8080:80
