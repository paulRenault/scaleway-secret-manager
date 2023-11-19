provider "scaleway" {
  region = "fr-par"
  zone   = "fr-par-2"
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}