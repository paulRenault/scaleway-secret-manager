# Objective

Discover and test scaleway's secret manager

You can find the product sheet [here](https://www.scaleway.com/en/secret-manager/) and the documentation [here](https://www.scaleway.com/en/docs/identity-and-access-management/secret-manager/concepts/)


# Requirements

- VSCode with extention [Remote Development](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.vscode-remote-extensionpack)
- Docker desktop with kubernetes enables
- Scaleway account
- Scaleway access and secret key

# Context

To test scaleway's secret manager, we're going to provision one with terraform and the whole thing will use devcontainer because it's more portable and sharable.

We're going to use the kubernetes cluster that comes with docker desktop.

We're going to add two secrets to the scaleway secret manager. The first will be a simple string, e.g. a mysql connection string, and the second will be in json format, e.g. a login/password for an API. And we'll retrieve them from our kubernetes cluster.

# Env vars needed

To order the secret manager, you'll need API keys

Create the file `.devcontainer/devcontainer.env` with the following env vars (don't forget to enter the values for each one)

- SCW_ACCESS_KEY
- SCW_SECRET_KEY
- SCW_DEFAULT_ORGANIZATION_ID

# Decontainer config

You can find out more about devcontainers [here](https://aka.ms/devcontainer.json)

## Base image

We're going to use the ubuntu base image created by microsoft to which we'll add two features:

- kubectl-helm-minikube
- terraform

You can find more [here](https://containers.dev/features)

## Env var

The env vars will be loaded at devcontainer startup.

## Extensions

We'll add 3 extensions to our vscode:

- `hashicorp.terraform`
- `ms-kubernetes-tools.vscode-kubernetes-tools`
- `github.copilot`

## kubeconfig

So, the kubeconfig is mount in the devcontainer (as you can see in the file `.devcontainer/devcontainer.json` in the attribut `mounts`)

# Create secret manager & API key from Scaleway with terraform

It's happening in the folder `infra`

```bash
cd infra
```

## Description

For more information on how to write terraform configuration files, see the [documentation](https://developer.hashicorp.com/terraform/language)

I may have taken some shortcuts, as this is not the main topic.

All the blocks discussed below are present in the file: `infra/main.tf`

### Creating a project

Creating a project allows me to separate my various tests and retrieve a project id that I can then pass on to other resources.

```hcl
resource "scaleway_account_project" "test_external_secret" {
  name = "Test external secret"
}
```

The project id will be displayed at the end of the `terraform apply` command, and will be useful when declaring the secret store.

### API key

To access the scaleway secret manager, you'll need an API key. You can use the key you've created for terraform, but in the interests of following best practices, and in particular those concerning "the least privileges", we'll create a key with just what you need.

We're going to create an application:

```hcl
resource "scaleway_iam_application" "external_secret_application" {
  name = "external_secret_application"
}
```

Then policy:

```hcl
resource "scaleway_iam_policy" "external_secret_policy" {
  name           = "external_secret_policy"
  application_id = scaleway_iam_application.external_secret_application.id
  rule {
    project_ids          = [scaleway_account_project.test_external_secret.id]
    permission_set_names = ["SecretManagerReadOnly", "SecretManagerSecretAccess"]
  }
}
```

To list all the permissions, scaleway give access to a browser cli. I used it and use this command:

```bash
scw iam permission-set list
```

For me, `SecretManagerSecretAccess` is the only rule needed, but it didn't work, so I added `SecretManagerReadOnly` and it worked.

And finally, we'll create the API keys:

```hcl
resource "scaleway_iam_api_key" "external_secret_api_key" {
  application_id     = scaleway_iam_application.external_secret_application.id
  description        = "external_secret_api_key"
  default_project_id = scaleway_account_project.test_external_secret.id
}
```

We'll use them a little later, don't worry

### Secret manager

First, we'll create our first secrets:

```hcl
resource "scaleway_secret" "test_secret_str" {
  name       = "Test_secret_str"
  project_id = scaleway_account_project.test_external_secret.id
}

resource "scaleway_secret" "test_secret_obj" {
  name       = "Test_secret_obj"
  project_id = scaleway_account_project.test_external_secret.id
}
```

And we're going to create a first version of the secrets:

```hcl
resource "random_password" "random_mysql_password" {
  length = 32
}

resource "scaleway_secret_version" "mysql_secret" {
  secret_id   = scaleway_secret.test_secret_str.id
  data        = "mysql://test:${random_password.random_mysql_password.result}@localhost:3306/test"
}

resource "random_password" "random_api_password" {
  length = 32
}

resource "scaleway_secret_version" "api_secret" {
  secret_id   = scaleway_secret.test_secret_obj.id
  data        = "{\"login\":\"test\", \"password\":\"${random_password.random_api_password.result}\"}"
}
```

I use the random_password resource to generate the password randomly

### Installing what we need in the cluster

We'll start by creating the namespace:

```hcl
resource "kubernetes_namespace" "external_secret_namespace" {
  metadata {
    name = "external-secret"
  }
}
```

We're going to add our API keys to a secret:

```hcl
resource "kubernetes_secret" "secret_manager_secret" {
  metadata {
    name      = "secret-manager-secret"
    namespace = kubernetes_namespace.external_secret_namespace.metadata[0].name
  }

  data = {
    access-key        = scaleway_iam_api_key.external_secret_api_key.access_key
    secret-access-key = scaleway_iam_api_key.external_secret_api_key.secret_key
  }
}
```

Finally, we're going to install external secret with helm:

```hcl
resource "helm_release" "external_secret_helm" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "0.9.9"
  namespace  = kubernetes_namespace.external_secret_namespace.metadata[0].name

  set {
    name  = "installCRDs"
    value = true
  }
}
```

You can find the documentation of external secrets [here](https://external-secrets.io/latest/)

And the helm chart documentation [here](https://artifacthub.io/packages/helm/external-secrets-operator/external-secrets)

## Action

To deploy all the resources we have just seen, you need to run the following three commands:

```bash
terraform init
terraform plan
terraform apply
```

# Secret store & external secrets

## Deploy Secret Store

The project_id displayed after the terraform apply command should be copied and pasted into the file `external-secret-config/secret-store.yaml` in the property `spec.provider.scaleway.projectId`

We're going to use a `SecretStore` and it will be scoped to the namespace we created beforehand. If you want a global secret store, you can use a `ClusterSecretStore`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: secret-store
  namespace: external-secret
spec:
  provider:
    scaleway:
      region: fr-par
      projectId: <PROJECT_ID>
      accessKey:
        secretRef:
          name: secret-manager-secret
          key: access-key
      secretKey:
        secretRef:
          name: secret-manager-secret
          key: secret-access-key
```

The secret store is called `secret-store` and is created in the namespace `external-secret`. We're going to use the `scaleway` provider and configure it.
In `spec.provider.scaleway.accessKey` and `spec.provider.scaleway.secretKey`, we're going to retrieve our API keys created with terraform

You can find the documentation [here](https://external-secrets.io/latest/provider/scaleway/)


Run this command to deploy the secret store:
```bash
kubectl apply -f external-secret-config/secret-store.yaml -n external-secret
```

Type this command to see the result:

```bash
kubectl describe secretstore -n external-secret
```

You should have something like this:

```
Name:         secret-store
Namespace:    external-secret
Labels:       <none>
Annotations:  <none>
API Version:  external-secrets.io/v1beta1
Kind:         SecretStore
Metadata:
  Creation Timestamp:  2023-11-18T15:23:51Z
  Generation:          1
  Resource Version:    2991
  UID:                 39fd2b80-e047-4684-a7c9-0488aebfc620
Spec:
  Provider:
    Scaleway:
      Access Key:
        Secret Ref:
          Key:     access-key
          Name:    secret-manager-secret
      Project Id:  f061755e-7d42-48c1-9579-0ad4084eea14
      Region:      fr-par
      Secret Key:
        Secret Ref:
          Key:   secret-access-key
          Name:  secret-manager-secret
Status:
  Capabilities:  ReadWrite
  Conditions:
    Last Transition Time:  2023-11-18T15:23:51Z
    Message:               store validated
    Reason:                Valid
    Status:                True
    Type:                  Ready
Events:
  Type    Reason  Age                From          Message
  ----    ------  ----               ----          -------
  Normal  Valid   72s (x6 over 18m)  secret-store  store validated
```

## Deploy external secret

### as a string

Run this command to deploy the first external secret:

```bash
kubectl apply -f external-secret-config/external-secret-mysql.yaml 
```

Type this command to see the result:

```bash
kubectl describe externalsecret secret-str -n external-secret
```

You should have something like this:

```
Name:         secret-str
Namespace:    external-secret
Labels:       <none>
Annotations:  <none>
API Version:  external-secrets.io/v1beta1
Kind:         ExternalSecret
Metadata:
  Creation Timestamp:  2023-11-18T15:45:44Z
  Generation:          1
  Resource Version:    4794
  UID:                 22dfb1b7-e207-4f83-bab6-0d15ddfccf46
Spec:
  Data:
    Remote Ref:
      Conversion Strategy:  Default
      Decoding Strategy:    None
      Key:                  name:Test_secret_str
      Metadata Policy:      None
    Secret Key:             mysql_connection_string
  Refresh Interval:         1m
  Secret Store Ref:
    Kind:  SecretStore
    Name:  secret-store
  Target:
    Creation Policy:  Owner
    Deletion Policy:  Delete
    Name:             my-secret-str
Status:
  Binding:
    Name:  my-secret-str
  Conditions:
    Last Transition Time:   2023-11-18T15:45:45Z
    Message:                Secret was synced
    Reason:                 SecretSynced
    Status:                 True
    Type:                   Ready
  Refresh Time:             2023-11-18T15:45:45Z
  Synced Resource Version:  1-f8ebf9d8eafd700968ae8a7495bfc5ea
Events:
  Type    Reason   Age   From              Message
  ----    ------   ----  ----              -------
  Normal  Updated  4s    external-secrets  Updated Secret
```

To see the contents of the secret, type the following command:

```bash
kubectl get secret my-secret-str -n external-secret -o jsonpath="{.data.mysql_connection_string}" | base64 -d
```

You can edit the secret from the scaleway console or using terraform. Wait about 1 minute and enter the command again to see the updated secret.

### as an object

Run this command to deploy the second external secret:
```bash
kubectl apply -f external-secret-config/external-secret-api.yaml
```

Type this command to see the result:

```bash
kubectl describe externalsecret secret-api -n external-secret
```

You should have something like this:

```
Name:         secret-api
Namespace:    external-secret
Labels:       <none>
Annotations:  <none>
API Version:  external-secrets.io/v1beta1
Kind:         ExternalSecret
Metadata:
  Creation Timestamp:  2023-11-18T15:36:39Z
  Generation:          1
  Resource Version:    5208
  UID:                 ee33cbd7-cba1-4ab1-b41f-030390234e57
Spec:
  Data From:
    Extract:
      Conversion Strategy:  Default
      Decoding Strategy:    None
      Key:                  name:Test_secret_obj
      Metadata Policy:      None
  Refresh Interval:         1m
  Secret Store Ref:
    Kind:  SecretStore
    Name:  secret-store
  Target:
    Creation Policy:  Owner
    Deletion Policy:  Delete
    Name:             my-secret-api
Status:
  Binding:
    Name:  my-secret-api
  Conditions:
    Last Transition Time:   2023-11-18T15:36:40Z
    Message:                Secret was synced
    Reason:                 SecretSynced
    Status:                 True
    Type:                   Ready
  Refresh Time:             2023-11-18T15:50:46Z
  Synced Resource Version:  1-008fa3e9bc00ae591d91bcfa2c09996a
Events:
  Type    Reason   Age                 From              Message
  ----    ------   ----                ----              -------
  Normal  Updated  53s (x15 over 14m)  external-secrets  Updated Secret
```

```bash
kubectl get secret my-secret-api -n external-secret -o jsonpath="{.data}"
```

You should have something like this:

```
{"login":"dGVzdA==","password":"SWs/cEpNIWhXPT0qKXJmJSZoazk2Tk5CRnBmelgkOGg="}
```

The login and password are base 64 encoded.

You can edit the secret from the scaleway console or using terraform. Wait about 1 minute and enter the command again to see the updated secret.

### as a file

Run this command to deploy the second external secret:
```bash
kubectl apply -f external-secret-config/external-secret-file.yaml
```

Type this command to see the result:

```bash
kubectl describe externalsecret secret-file -n external-secret
```
## Use it

Now that the secrets have been retrieved from the secret manager, they can be used in a pod

We're going to use the secret `my-secret-str` as an environment variable `TEST_STR` and the secret `my-secret-file` as a volume mount into the pod

To deploy our test pod:

```bash
kubectl apply -f external-secret-config/deployment.yaml -n external-secret
```

You can inspect the pod with the following command:
```bash
kubectl describe  pods nginx-deployment-859dbd85c6-mxxgv -n external-secret
```

We can see our environment variable `TEST_STR`

And we can have it displayed by our pod, with this command:

```bash
kubectl exec -it nginx-deployment-859dbd85c6-mxxgv -n external-secret -- bash
echo $TEST_STR
```

Unfortunately, the secret in the env var is not updated in the pod when the secret is updated in the secret manager, despite the fact that it is updated every minute. You need to delete the pod so that kubernetes can create it again.

There are services that can do this automatically, but I haven't tried them yet.

And you can see the secret mount into the pod with the command:

```bash
kubectl exec -it nginx-deployment-859dbd85c6-mxxgv -n external-secret -- bash
cat /etc/secret-volume/secret.json
```

This one, however, is updated. You can update it in the UI scaleway, wait for the `spec.refreshInterval` and rerun the command.
It must be updated.

# Clean up

```bash
cd infra
terraform destroy
```