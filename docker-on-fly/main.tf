terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    fly = {
      source = "fly-apps/fly"
    }
    random = {
      source = "hashicorp/random"
    }
    docker = {
      source  = "kreuzwerker/docker"
    }
  }
}

data "coder_provisioner" "me" {
}

provider "fly" {
  fly_api_token = var.fly_token
  fly_http_endpoint = "_api.internal:4280"
}

provider "docker" {
  host = "tcp://${fly_machine.machine[0].privateip}:2375"
}

variable "fly_app" {
  description = <<EOF
  Coder requires a Fly.io app name to provision workspaces.
  EOF

  sensitive = true
}

variable "fly_token" {
  description = <<EOF
Coder requires a Fly.io token to provision workspaces.
EOF
  sensitive   = true
  validation {
    condition     = length(var.fly_token) == 43
    error_message = "Please provide a valid Fly.io Access token."
  }
}

data "coder_workspace" "me" {
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  startup_script = <<EOF
    sudo hostname ${data.coder_workspace.me.name}
    echo "127.0.0.1 ${data.coder_workspace.me.name}" | sudo tee -a /etc/hosts

    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh
    code-server --auth none --port 13337
    EOF

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  env = {
    GIT_AUTHOR_NAME = "${data.coder_workspace.me.owner}"
    GIT_COMMITTER_NAME = "${data.coder_workspace.me.owner}"
    GIT_AUTHOR_EMAIL = "${data.coder_workspace.me.owner_email}"
    GIT_COMMITTER_EMAIL = "${data.coder_workspace.me.owner_email}"
  }
}

resource "coder_app" "code-server" {
  agent_id = coder_agent.main.id
  name     = "code-server"
  slug     = "code-server"
  url      = "http://localhost:13337/?folder=/workspace"
  icon     = "/icon/code.svg"
}

variable "docker_image" {
  description = "Which Docker image would you like to use for your workspace?"
  default = "codercom/enterprise-base:ubuntu"
}

variable "workspace_size" {
  description = "What should the size of your workspace be? (in GB)"
  default = 1
  validation {
    condition = var.workspace_size >= 1 && var.workspace_size <= 10
    error_message = "Invalid volume size! Allowed: 1-10"
  }
}

variable "fly_region" {
  description = "Which Fly.io region would you like to use for your workspace?"
  default = "lax"
  validation {
    condition = contains(["ams", "cdg", "dfw", "ewr", "fra", "gru", "hkg", "iad", "lax", "lhr", "maa", "mad", "mia", "nrt", "ord", "phx", "scl", "sea", "sin", "sjc", "syd", "yul", "yyz"], var.fly_region)
    error_message = "Invalid Fly.io region!"
  }
}

resource "fly_volume" "workspace_volume" {
  name = "${data.coder_workspace.me.owner}_${data.coder_workspace.me.name}_docker"
  app = var.fly_app
  size = var.workspace_size
  region = var.fly_region
}

resource "coder_metadata" "volume" {
  resource_id = fly_volume.workspace_volume.id
  item {
    key = "name"
    value = fly_volume.workspace_volume.name
  }
}

resource "random_id" "machine_id" {
  byte_length = 7
}

resource "fly_machine" "machine" {
  count = data.coder_workspace.me.start_count

  app = var.fly_app

  cpus = 4
  memorymb = 6144

  region = var.fly_region
  image = "docker:dind"
  name = "${data.coder_workspace.me.owner}_${data.coder_workspace.me.name}_${random_id.machine_id.hex}"
  env = {
    CODER_AGENT_TOKEN = coder_agent.main.token
  }

  entrypoint = ["dockerd"]

  mounts = [
    {
      path = "/var/lib/docker"
      volume = fly_volume.workspace_volume.id
    }
  ]
  depends_on = [fly_volume.workspace_volume]
}

resource "coder_metadata" "machine" {
  count = data.coder_workspace.me.start_count
  resource_id = fly_machine.machine[0].id
  item {
    key = "name"
    value = fly_machine.machine[0].name
  }
}

variable "docker_sysbox" {
  description = <<EOF
    Should the [Sysbox](https://github.com/nestybox/sysbox) runtime be used?
    See [here](https://coder.com/docs/coder-oss/latest/templates/docker-in-docker) for details.
  EOF

  default = true
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count

  name = "workspace"
  image = var.docker_image

  restart = "always"
  networks_advanced {
	  name = "host"
  }

  privileged = true

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}"
  ]

  volumes {
    container_path = "/var/run/docker.sock"
    host_path = "/var/run/docker.sock"
  }

  entrypoint = ["sh", "-c", "${coder_agent.main.init_script}"]
  # https://coder.com/docs/coder-oss/latest/templates/docker-in-docker
  runtime = var.docker_sysbox ? "sysbox-runc" : ""

  depends_on = [fly_machine.machine]
}
