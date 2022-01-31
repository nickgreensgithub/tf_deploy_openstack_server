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

variable "network_subnet" {
    type    = string
}

variable "security_groups" {
    type    = list(string)
    default = ["default"]
}

variable "volume_names" {
    type    = list(string)
    default = []
}

variable "create_user"{ 
    type = map
}

variable "vm_connection_details"{
    type = map
}

variable "image_name"{
    type = string
}

variable "user_data"{
    type = string
}

variable "root_volume_size"{
    type = number
    default = 100
}

variable "floating_ips"{
    type =  list(string)
    default = []
}

variable "internal_network_ips"{
    type =  list(string)
    default = []
}

variable assign_static_internal_ips{
    type= bool
    default = true
}

variable assign_floating_ips{
    type= bool
    default = false
}

variable "flavour"{}

data "openstack_networking_network_v2" "internal_network" {
    name = var.network
}

data "openstack_networking_secgroup_v2" "internal_network_secgroup" {
    name = "default"
}

data "openstack_networking_subnet_ids_v2" "internal_network_subnet" {
    name = var.network_subnet
}

data "openstack_images_image_v2" "image_id" {
    name        = "${var.image_name}"
    most_recent = true
}

# Create an instance
resource "openstack_compute_instance_v2" "server" {
    count = var.number_of_machines
    name            = "${var.name_prefix}_${var.name_suffix}_${count.index}"
    flavor_name = var.flavour
    key_pair        = var.keypair
    security_groups = var.security_groups
    user_data = "${var.user_data}"

    dynamic "network" {
        for_each = var.assign_static_internal_ips ? [1] : []
        content {
            port = "${openstack_networking_port_v2.internal_network_port[count.index].id}"
        }
    }

    block_device {
        uuid                  = data.openstack_images_image_v2.image_id.id
        source_type           = "image"
        volume_size           = var.root_volume_size
        boot_index            = 0
        destination_type      = "volume"
        delete_on_termination = true
    }
}

data "openstack_blockstorage_volume_v2" "mounting_volumes" {
    for_each    = {for volume in var.volume_names: volume => volume}
    name = each.value
}

#Will only mount on the first machine for now, but that's all I need at this point anyway
resource "openstack_compute_volume_attach_v2" "volumes" {
    depends_on = [ openstack_compute_instance_v2.server ]
    #count       = length(var.volume_names)
    for_each = data.openstack_blockstorage_volume_v2.mounting_volumes
    instance_id = openstack_compute_instance_v2.server[0].id
    volume_id = each.value.id
}

#Not sure what happens if there are too few IP addresses in var.internal_network_ips, I would guess an error
resource "openstack_networking_port_v2" "internal_network_port" {
    count = length(var.internal_network_ips)
    name               = "internal_network_port"
    network_id         = "${data.openstack_networking_network_v2.internal_network.id}"
    admin_state_up     = "true"
    security_group_ids = ["${data.openstack_networking_secgroup_v2.internal_network_secgroup.id}"]

    fixed_ip {
        subnet_id  = "${data.openstack_networking_subnet_ids_v2.internal_network_subnet.ids[0]}"
        ip_address = var.internal_network_ips[count.index]
    }
}

#Will only apply as many floating IPs as are supplied, floating IPs must be on a network with a router connecting this subnet
resource "openstack_compute_floatingip_associate_v2" "floating_ips" {
    count       = length( openstack_compute_instance_v2.server)
    floating_ip = "${var.floating_ips[count.index]}"
    instance_id = "${openstack_compute_instance_v2.server[count.index].id}"
    fixed_ip    = "${openstack_compute_instance_v2.server[count.index].network[0].fixed_ip_v4}"
}

module "create_ansible_user"{
    depends_on = [ openstack_compute_instance_v2.server ]
    count      = length( openstack_compute_instance_v2.server)
    source= "github.com/nickgreensgithub/tf_module_create_remote_user?ref=8cff1d71d738cb7cb037211d2a7e1c87c64026b7"

    connection = {
            ip = openstack_compute_floatingip_associate_v2.floating_ips[count.index].floating_ip
            user= var.vm_connection_details.user
            private_key = var.vm_connection_details.priv
    }
    user = {
            name = "${ var.create_user.user }"
            is_sudo = true
            public_ssh="${ var.create_user.pub }"
    }
}