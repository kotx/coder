terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    fly = {
      source = "fly-apps/fly"
    }
  }
}

provider "fly" {
  fly_api_token = var.fly_token
  fly_http_endpoint = "_api.internal:4280"
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
  os   = "linux"
  arch = "amd64"
  startup_script = <<EOF
    #!/bin/sh
    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh
    code-server --auth none --port 13337
    EOF

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  # You can remove this block if you'd prefer to configure Git manually or using
  # dotfiles. (see docs/dotfiles.md)
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
  url      = "http://localhost:13337/?folder=/home/coder"
  icon     = "/icon/code.svg"
}

variable "docker_image" {
  description = "Which Docker image would you like to use for your workspace?"
  # The codercom/enterprise-* images are only built for amd64
  default = "codercom/enterprise-base:ubuntu"
  validation {
    condition = contains(["codercom/enterprise-base:ubuntu", "codercom/enterprise-node:ubuntu",
    "codercom/enterprise-intellij:ubuntu", "codercom/enterprise-golang:ubuntu"], var.docker_image)
    error_message = "Invalid Docker image!"
  }
}

resource "fly_app" "app" {
  name = "coder-workspaces"
  org = "yukata"
}

resource "fly_volume" "homeVolume" {
  name = "${data.coder_workspace.me.owner}_${data.coder_workspace.me.name}_home"
  app = "coder-workspaces"
  size = 1
  region = "lax"
  depends_on = [fly_app.app]
}

resource "fly_machine" "machine" {
  count = data.coder_workspace.me.start_count
  app = "coder-workspaces"
  region = "lax"
  image = var.docker_image
  name = "${data.coder_workspace.me.owner}-${lower(data.coder_workspace.me.name)}"
  # env = {
  #   CODER_AGENT_TOKEN = coder_agent.main.token
  # }
  services = [
    {
      ports = [
        {
          port = 8080
          handlers = ["http"]
        }
      ]
      "protocol": "tcp",
      "internal_port": 8080
    }
  ]
  mounts = [
    {
      path = "/home"
      volume = fly_volume.homeVolume.id
    }
  ]
  depends_on = [fly_app.app, fly_volume.homeVolume]
}

