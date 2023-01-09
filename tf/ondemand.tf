resource "azurerm_public_ip" "ondemand-pip" {
  count               = local.allow_public_ip ? 1 : 0
  name                = "ondemand-pip"
  location            = local.create_rg ? azurerm_resource_group.rg[0].location : data.azurerm_resource_group.rg[0].location
  resource_group_name = local.create_rg ? azurerm_resource_group.rg[0].name : data.azurerm_resource_group.rg[0].name
  allocation_method   = "Static"
  domain_name_label   = "ondemand${random_string.resource_postfix.result}"
}

resource "azurerm_network_interface" "ondemand-nic" {
  name                = "ondemand-nic"
  location            = local.create_rg ? azurerm_resource_group.rg[0].location : data.azurerm_resource_group.rg[0].location
  resource_group_name = local.create_rg ? azurerm_resource_group.rg[0].name : data.azurerm_resource_group.rg[0].name
  enable_accelerated_networking = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.create_frontend_subnet ? azurerm_subnet.frontend[0].id : data.azurerm_subnet.frontend[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = local.allow_public_ip ? azurerm_public_ip.ondemand-pip[0].id : null
  }
}

resource "azurerm_linux_virtual_machine" "ondemand" {
  name                = "ondemand"
  location            = local.create_rg ? azurerm_resource_group.rg[0].location : data.azurerm_resource_group.rg[0].location
  resource_group_name = local.create_rg ? azurerm_resource_group.rg[0].name : data.azurerm_resource_group.rg[0].name
  size                = try(local.configuration_yml["ondemand"].vm_size, "Standard_D4s_v3")
  admin_username      = local.admin_username
  network_interface_ids = [
    azurerm_network_interface.ondemand-nic.id,
  ]

  identity {
    type         = "SystemAssigned"
  }

  admin_ssh_key {
    username   = local.admin_username
    public_key = tls_private_key.internal.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  dynamic "source_image_reference" {
    for_each = local.use_linux_image_id ? [] : [1]
    content {
      publisher = local.linux_base_image_reference.publisher
      offer     = local.linux_base_image_reference.offer
      sku       = local.linux_base_image_reference.sku
      version   = local.linux_base_image_reference.version
    }
  }

  source_image_id = local.linux_image_id
  dynamic "plan" {
    for_each = try (length(local.linux_image_plan.name) > 0, false) ? [1] : []
    content {
        name      = local.linux_image_plan.name
        publisher = local.linux_image_plan.publisher
        product   = local.linux_image_plan.product
    }
  }

  lifecycle {
    ignore_changes = [
      tags
    ]
  }
}

resource "azurerm_network_interface_application_security_group_association" "ondemand-asg-asso" {
  for_each = toset(local.asg_associations["ondemand"])
  network_interface_id          = azurerm_network_interface.ondemand-nic.id
  application_security_group_id = local.create_nsg ? azurerm_application_security_group.asg[each.key].id : data.azurerm_application_security_group.asg[each.key].id
}

resource "azurerm_virtual_machine_extension" "AzureMonitorLinuxAgent_ondemand" {
  depends_on = [
    azurerm_linux_virtual_machine.ondemand
  ]
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.ondemand.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_monitor_data_collection_rule_association" "dcra_ondemand_metrics" {
    name                = "ondemand-data-collection-ra"
    target_resource_id = azurerm_linux_virtual_machine.ondemand.id
    data_collection_rule_id = azurerm_monitor_data_collection_rule.vm_data_collection_rule.id
    description = "OnDemand Data Collection Rule Association for VM Metrics"
}

resource "azurerm_monitor_data_collection_rule_association" "dcra_ondemand_insights" {
    name                = "ondemand-insights-collection-ra"
    target_resource_id = azurerm_linux_virtual_machine.ondemand.id
    data_collection_rule_id = azurerm_monitor_data_collection_rule.vm_insights_collection_rule.id
    description = "OnDemand Data Collection Rule Association for VM Insights"
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "od_volume_alert" {
    count = local.create_alerts ? 1 : 0
    name = "od-volume-alert"
    location = local.create_rg ? azurerm_resource_group.rg[0].location : data.azurerm_resource_group.rg[0].location
    resource_group_name = local.create_rg ? azurerm_resource_group.rg[0].name : data.azurerm_resource_group.rg[0].name


    evaluation_frequency = "PT5M"
    window_duration = "PT5M"
    scopes = [azurerm_linux_virtual_machine.ondemand.id]
    severity = 3

    criteria {
        query = <<-QUERY
          InsightsMetrics
          | where TimeGenerated >= ago(5min) and Name == "FreeSpacePercentage" and Val <= 20 and Tags !contains "anfhome"
          | project TimeGenerated, Computer, Name, Val, Tags, _ResourceId
          | summarize arg_max(TimeGenerated, *) by Tags
          | project Tags, Val, Computer, _ResourceId
          QUERY
        time_aggregation_method = "Count"
        operator = "GreaterThan"
        threshold = 0
        failing_periods {
            minimum_failing_periods_to_trigger_alert = 1
            number_of_evaluation_periods = 1
        }
    }

    auto_mitigation_enabled = true
    description = "Alert when the volumes of the OnDemand VM is above 80%"
    display_name = "ondemand volumes full"
    enabled = true
    query_time_range_override = "P2D"

    action {
        action_groups = [azurerm_monitor_action_group.azhop_action_group[0].id]
    }
}

resource "azurerm_monitor_metric_alert" "ondemand_disk_alert" {
  count = local.create_alerts ? 1 : 0
  name                = "ondemand-disk-alert"
  resource_group_name = local.create_rg ? azurerm_resource_group.rg[0].name : data.azurerm_resource_group.rg[0].name
  scopes              = [azurerm_linux_virtual_machine.ondemand.id]
  description         = "Alert when OnDemand VM disk is 80% full"
  severity            = 3
  enabled             = true
  frequency           = "PT5M"
  window_size         = "PT5M"
  target_resource_type = "Microsoft.Compute/virtualMachines"
  target_resource_location = local.create_rg ? azurerm_resource_group.rg[0].location : data.azurerm_resource_group.rg[0].location
  criteria {
    metric_namespace = "Azure.VM.Linux.GuestMetrics"
    metric_name      = "disk/free_percent"
    aggregation      = "Average"
    operator         = "LessThanOrEqual"
    threshold        = 20
  }
  action {
    action_group_id = azurerm_monitor_action_group.azhop_action_group[0].id
  }
}
