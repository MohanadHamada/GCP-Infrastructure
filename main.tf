
# ===== Provider =======

provider "google" {
  project     = "neon-trilogy-476216-j8"
  region      = "us-central1"
  credentials = file("/home/mohand/GCP-Infrastructure/.gcp/neon-trilogy-476216-j8-aaa2ea16e715.json")
}

data "google_client_config" "default" {}


# ===== VPC & Subnets =======

resource "google_compute_network" "custom_vpc" {
  name                    = "custom-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "management_subnet" {
  name                     = "management-subnet"
  ip_cidr_range            = "10.0.1.0/24"
  region                   = "us-central1"
  network                  = google_compute_network.custom_vpc.id
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "restricted_subnet" {
  name                     = "restricted-subnet"
  ip_cidr_range            = "10.0.2.0/24"
  region                   = "us-central1"
  network                  = google_compute_network.custom_vpc.id
  private_ip_google_access = true
}


# ===== NAT Router ======

resource "google_compute_router" "nat_router" {
  name    = "nat-router"
  network = google_compute_network.custom_vpc.name
  region  = "us-central1"
}

resource "google_compute_router_nat" "nat_config" {
  name                              = "nat-config"
  router                            = google_compute_router.nat_router.name
  region                            = "us-central1"
  nat_ip_allocate_option            = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  depends_on = [google_compute_router.nat_router]
}


# ===== Service Accounts =======

resource "google_service_account" "private_vm_sa" {
  account_id   = "private-vm-sa"
  display_name = "Private VM Service Account"
}

resource "google_service_account" "gke_nodes_sa" {
  account_id   = "gke-nodes-sa"
  display_name = "GKE Nodes Service Account"
}


# ===== Private VM ======

resource "google_compute_instance" "private_vm" {
  name         = "private-vm"
  machine_type = "e2-micro"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.management_subnet.id
  }

  service_account {
    email  = google_service_account.private_vm_sa.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
  tags = ["private-vm"]
  depends_on = [google_compute_router_nat.nat_config, google_container_cluster.private_gke]
}


# ===== Firewalls =======

resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "allow-iap-ssh"
  network       = google_compute_network.custom_vpc.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["private-vm"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "allow_management_to_gke" {
  name          = "allow-management-to-gke"
  network       = google_compute_network.custom_vpc.name
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["10.0.1.0/24"]
  target_tags   = ["gke-master-access"]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "allow_nodes_egress" {
  name               = "allow-nodes-egress"
  network            = google_compute_network.custom_vpc.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["443", "80"]
  }
}

resource "google_compute_firewall" "allow_all_egress" {
  name               = "allow-all-egress"
  network            = google_compute_network.custom_vpc.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "allow_master_to_nodes" {
  name    = "allow-master-to-nodes"
  network = google_compute_network.custom_vpc.name
  direction = "INGRESS"
  priority  = 1000
  source_ranges = ["172.16.0.0/28"]
  target_tags   = ["gke-node"]

  allow {
    protocol = "tcp"
    ports    = ["10250", "443"]
  }
}

resource "google_compute_firewall" "allow_vm_to_nodes" {
  name    = "allow-vm-to-nodes"
  network = google_compute_network.custom_vpc.name
  direction = "INGRESS"
  priority  = 1000
  source_ranges = ["10.0.1.0/24"] # management subnet
  target_tags   = ["gke-node"]

  allow {
    protocol = "tcp"
    ports    = ["10250"]
  }
}
resource "google_compute_firewall" "allow_health_checks" {
  name    = "allow-health-checks"
  network = google_compute_network.custom_vpc.name
  direction = "INGRESS"
  priority  = 1000
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["gke-node"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}


# ===== Zonal GKE Cluster =======

resource "google_container_cluster" "private_gke" {
  name     = "private-gke"
  location = "us-central1-a"

  remove_default_node_pool = true
  initial_node_count       = 1
  network                  = google_compute_network.custom_vpc.name
  subnetwork               = google_compute_subnetwork.restricted_subnet.name
  deletion_protection      = false

  private_cluster_config {
    enable_private_endpoint = true
    enable_private_nodes    = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "10.0.1.0/24"
      display_name = "management-subnet"
    }
  }
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "primary-node-pool"
  cluster    = google_container_cluster.private_gke.name
  location   = "us-central1-a"
  node_count = 3

  node_config {
    machine_type    = "e2-micro"
    disk_size_gb    = 20
    disk_type       = "pd-standard"
    preemptible     = true
    service_account = google_service_account.gke_nodes_sa.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    tags            = ["gke-node", "gke-master-access"]
  }
}