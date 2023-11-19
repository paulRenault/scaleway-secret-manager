terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "2.32.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.23.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "3.5.1"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "2.11.0"
    }
  }
}

# Scaleway project
resource "scaleway_account_project" "test_external_secret" {
  name = "Test external secret"
}

# API key

resource "scaleway_iam_application" "external_secret_application" {
  name = "external_secret_application"
}

resource "scaleway_iam_policy" "external_secret_policy" {
  name           = "external_secret_policy"
  application_id = scaleway_iam_application.external_secret_application.id
  rule {
    project_ids          = [scaleway_account_project.test_external_secret.id]
    permission_set_names = ["SecretManagerReadOnly", "SecretManagerSecretAccess"]
  }
}

resource "scaleway_iam_api_key" "external_secret_api_key" {
  application_id     = scaleway_iam_application.external_secret_application.id
  description        = "external_secret_api_key"
  default_project_id = scaleway_account_project.test_external_secret.id
}

# Secret Manager

resource "scaleway_secret" "test_secret_str" {
  name       = "Test_secret_str"
  project_id = scaleway_account_project.test_external_secret.id
}

resource "scaleway_secret" "test_secret_obj" {
  name       = "Test_secret_obj"
  project_id = scaleway_account_project.test_external_secret.id
}

resource "random_password" "random_mysql_password" {
  length = 32
}

resource "scaleway_secret_version" "mysql_secret" {
  secret_id = scaleway_secret.test_secret_str.id
  data      = "mysql://test:${random_password.random_mysql_password.result}@localhost:3306/test"
}

resource "random_password" "random_api_password" {
  length = 32
}

resource "scaleway_secret_version" "api_secret" {
  secret_id = scaleway_secret.test_secret_obj.id
  data      = "{\"login\":\"test\", \"password\":\"${random_password.random_api_password.result}\"}"
}

# Create Secret Manager Secret Access

resource "kubernetes_namespace" "external_secret_namespace" {
  metadata {
    name = "external-secret"
  }
}

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