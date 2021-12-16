#TODO create new admin sudo user and disable access for ubuntu user, probably in ansible playbook

terraform {
    required_version = ">= 0.14.0"
    required_providers {
        openstack = {
            source  = "terraform-provider-openstack/openstack"
            version = "~> 1.45.0"
        }
    }
}

variable "cloudname"{
    type    = string
    default = "openstack"
}

#clouds.yaml file should be in ~/.config/openstack, or in current directory for connection variables to be auto loaded
provider "openstack" {
    cloud = var.cloudname
}

variable "keypair" {
    type    = string
}

variable "name_suffix" {
    type    = string
}

variable name_prefix{
    type = string
}

variable "number_of_machines" {
    type= number
    default=1
}

variable "network" {
    type    = string
}

variable "security_groups" {
    type    = list(string)
    default = ["default"]
}

variable "volumes" {
    default = {}
}

variable "create_user"{ 
    type = map
}

variable "vm_connection_details"{
    type = map
}

variable "image_id"{
    type = string
}

variable "root_volume_size"{
    type = number
    default = 100
}

variable "flavour"{}

# Create an instance
resource "openstack_compute_instance_v2" "server" {
    count = var.number_of_machines
    name            = "${var.name_prefix}_${var.name_suffix}_${count.index}"
    image_name  = var.image_id
    flavor_name = var.flavour
    key_pair        = var.keypair
    security_groups = var.security_groups

    network {
        name = var.network
        access_network = true
    }

    block_device {
        uuid                  = var.image_id
        source_type           = "image"
        volume_size           = var.root_volume_size
        boot_index            = 0
        destination_type      = "volume"
        delete_on_termination = true
    }

}

#Will only mount on the first machine for now, all I need at this point
resource "openstack_compute_volume_attach_v2" "volumes" {
    for_each          = var.volumes 
    instance_id = openstack_compute_instance_v2.server[0].id
    volume_id = each.value.id
}

module "create_ansible_user"{
    depends_on = [ openstack_compute_instance_v2.server ]
    count      = length( openstack_compute_instance_v2.server )
    source="github.com/nickgreensgithub/tf_module_create_remote_user"

    connection = {
            ip = openstack_compute_instance_v2.server[count.index].network.0.fixed_ip_v4
            user= var.vm_connection_details.user
            private_key = var.vm_connection_details.priv
    }
    user = {
            name = "${ var.create_user.user }"
            is_sudo = true
            public_ssh="${ var.create_user.pub }"
    }
}