terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.0.0"
    }
  }
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  skip_provider_registration = true # This is only required when the User, Service Principal, or Identity running Terraform lacks the permissions to register Azure Resource Providers.
  features {}
}

variable "prefix" {
  default = "cloudguard_lab"
}

# Resource Group
resource "azurerm_resource_group" "lab" {
  name     = "rg_${var.prefix}_resources"
  location = "West Europe"
}

# Networking
resource "azurerm_virtual_network" "lab" {
  name                = "${var.prefix}_vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
}

variable sub_nets {
  type = map
  default = {
      "firewall" = "10.0.1.0/24",
      "internal" = "10.0.2.0/24",
      "server"   = "10.0.3.0/24",
      "dmz"      = "10.0.4.0/24",
      }
}

resource "azurerm_subnet" "subnet" {
  for_each = var.sub_nets
  name                 = "${var.prefix}_snet_${each.key}"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [each.value]
}


# Firewall Public IP
resource "azurerm_public_ip" "firewall_public_ip" {
  name                = "${var.prefix}_az_firewall_public_ip"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_firewall" "az_firewall" {
  name                = "${var.prefix}_azure_firewall"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.subnet["firewall"].id
    public_ip_address_id = azurerm_public_ip.firewall_public_ip.id
  }
}

# Routing
resource "azurerm_route_table" "route-table" {
  depends_on                    = [azurerm_subnet.subnet["firewall"]]
  name                          = "aks-route-table"
  location                      = azurerm_resource_group.lab.location
  resource_group_name           = azurerm_resource_group.lab.name
  disable_bgp_route_propagation = false
  route {
    name                   = "default-route"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.az_firewall.ip_configuration[0].private_ip_address
  }
}
resource "azurerm_subnet_route_table_association" "route-table" {
  for_each = azurerm_subnet.subnet
  subnet_id      = azurerm_subnet.subnet[each.key].id
  route_table_id = azurerm_route_table.route-table.id
}



# VM Config
variable virtual_machines {
  type = map
  default = {
  "vm1" = { vm_name = "vm-internal", sub_net = "internal" },
  "vm2" = { vm_name = "vm-dmz", sub_net = "dmz" },
  "vm3" = { vm_name = "vm-server", sub_net = "server" }
  }
}

resource "azurerm_network_interface" "main" {
  for_each = var.virtual_machines
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "testconfiguration1"
    subnet_id                     = azurerm_subnet.subnet[each.value.sub_net].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_virtual_machine" "main" {
  for_each = var.virtual_machines
  name                  = "${var.prefix}_${each.value.vm_name}"
  location              = azurerm_resource_group.lab.location
  resource_group_name   = azurerm_resource_group.lab.name
  network_interface_ids = [azurerm_network_interface.main[each.key].id]
  vm_size               = "Standard_B1ls"

  delete_os_disk_on_termination = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Debian"
    offer     = "debian-10"
    sku       = "10"
    version   = "latest"
  }
  storage_os_disk {
    name              = "osdisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = "${each.value.vm_name}"
    admin_username = "admin"
    admin_password = "Password1234!"
  }
  os_profile_linux_config {
    disable_password_authentication = false
  }
  tags = {
    environment = "staging"
  }
}
