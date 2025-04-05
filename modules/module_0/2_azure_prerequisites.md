# Azure Local Deployment Workshop | Azure Prerequisites

## Overview <!-- omit in toc -->

In addition to your infrastructure requirements, deploying Azure Local will also require access to an **Azure subscription**, and **Entra ID Tenant**. You must also have certain permissions at both the subscription and Entra ID tenant levels, otherwise some of the steps in the workshop will not work. This section will cover all the prerequisites you need to successfully complete the deployment.

## Section duration <!-- omit in toc -->

10 Minutes

## Contents <!-- omit in toc -->

- [Azure Local Deployment Workshop | Azure Prerequisites](#azure-local-deployment-workshop--azure-prerequisites)
  - [Get an Azure subscription](#get-an-azure-subscription)
  - [Azure subscription \& Entra ID permissions](#azure-subscription--entra-id-permissions)
  - [Firewall / Proxy Configuration](#firewall--proxy-configuration)
  - [Next steps](#next-steps)
  - [Raising issues](#raising-issues)

## Get an Azure subscription

As mentioned earlier, to deploy Azure Local, you'll need an Azure subscription. If you already have one provided by your company, you can skip this step, but if not, you have a couple of options.

The first option would apply to Visual Studio subscribers, where you can use Azure at no extra charge. With your monthly Azure DevTest individual credit, Azure is your personal sandbox for dev/test. You can provision virtual machines, cloud services, and other Azure resources. Credit amounts vary by subscription level, but if you manage your usage efficiently, you can test the scenarios well within your subscription limits.

The second option would be to sign up for a [free trial](https://azure.microsoft.com/en-us/free/ "Azure free trial link"), which gives you $200 credit for the first 30 days, and 12 months of popular services for free.

*******************************************************************************************************

**NOTE** - The free trial subscription provides $200 for your usage, however the largest individual VM you can create is capped at 4 vCPUs, which is **not** enough to run this deployment workshop if you choose to deploy the environment within a single Azure VM. Once you have signed up for the free trial, you can [upgrade this to a pay as you go subscription](https://docs.microsoft.com/en-us/azure/cost-management-billing/manage/upgrade-azure-subscription "Upgrade to a PAYG subscription") and this will allow you to keep your remaining credit ($200 to start with) for the full 30 days from when you signed up. You will also be able to deploy VMs with greater than 4 vCPUs.

*******************************************************************************************************

## Azure subscription & Entra ID permissions

Depending on the particular module and hands-on-lab, the permissions required for both the Azure subscription and Entra ID tenant may vary. Below is a table summarizing the different permissions that are required for the main modules in the course. These permissions will also be available at the start of each hands-on-lab.

| Module | Topic | Subscription Permissions | Entra ID Permissions |
|:--|---|---|---|
| 2 | Azure Local | Owner / User Access Administrator + Contributor / Custom | Not required |

## Firewall / Proxy Configuration

If you are deploying the workshop on your own physical hardware, or inside an existing virtual machine running within your environment, you may need to request access to certain external resources with your network team. The following link provides guidance on the specific endpoints that need to be accessible for a successful Azure Local deployment, separated by Azure region:

- Australia East: [Endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/AustraliaEastendpoints/AustraliaEast-hci-endpoints.md)
- Canada Central US: [Endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/CanadaCentralEndpoints/canadacentral-hci-endpoints.md)
- East US: [Endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/EastUSendpoints/eastus-hci-endpoints.md)
- India Central: [Endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/IndiaCentralEndpoints/IndiaCentral-hci-endpoints.md)
- Japan East: [Endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/JapanEastEndpoints/japaneast-hci-endpoints.md)
- South Central US: [Endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/SouthCentralUSEndpoints/southcentralus-hci-endpoints.md)
- South East Asia: [Endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/SouthEastAsiaEndpoints/southeastasia-hci-endpoints.md)
- West Europe: [Endpoints](https://github.com/Azure/AzureStack-Tools/blob/master/HCI/WestEuropeendpoints/westeurope-hci-endpoints.md)

If you're looking for a way to extract the list of endpoints into JSON, to simplify configuration of your firewall, [check out Erik's blog](https://blog.graa.dev/AzureLocal-Endpoints), where he's developed an automated GitHub pipeline to gather the latest endpoints from the Microsoft GitHub repository, extract and format the list into prettified JSON.

Post-deployment, depending on additional Azure services you enable for Azure Local, you may need to make additional firewall configuration changes. Refer to the following links for information on firewall requirements for each Azure service:

- [Azure Monitor Agent](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-network-configuration?tabs=PowerShellWindows#firewall-endpoints)
- [Azure portal](https://learn.microsoft.com/en-us/azure/azure-portal/azure-portal-safelist-urls?tabs=public-cloud)
- [Azure Site Recovery](https://learn.microsoft.com/en-us/azure/site-recovery/hyper-v-azure-architecture#outbound-connectivity-for-urls)
- [Azure Virtual Desktop](https://learn.microsoft.com/en-us/azure/firewall/protect-azure-virtual-desktop)
- [Microsoft Defender](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/production-deployment?#network-configuration)
- [Microsoft Monitoring Agent (MMA) and Log Analytics Agent](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/log-analytics-agent#network-requirements)
- [Qualys](https://learn.microsoft.com/en-us/azure/defender-for-cloud/deploy-vulnerability-assessment-vm#what-prerequisites-and-permissions-are-required-to-install-the-qualys-extension)
- [Remote support](https://learn.microsoft.com/en-us/azure/azure-local/manage/get-remote-support.md#configure-proxy-settings)
- [Windows Admin Center](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/deploy/network-requirements)
- [Windows Admin Center in Azure portal](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/azure/manage-hci-clusters#networking-requirements)

With the Azure requirements and prerequisites reviewed, it's time to begin your deployment of the workshop environment.

## Next steps

Based on your available hardware, choose one of the following options:

- **Lab Deployment on Physical Hardware** - If you've got your own **suitable hardware**, proceed on to [deploy the workshop on your physical hardware](/modules/module_0/3_physical_deployment.md).
- **Lab Deployment in existing virtual machine** - If you have access to an **existing virtualization environment**, proceed on to [deploy the workshop inside an existing virtual machine](/modules/module_0/4_nestedvm_deployment.md).
- **Lab Deployment in Azure** - If you're choosing to deploy with an **Azure virtual machine**, head on over to the [Azure VM deployment guidance](/modules/module_0/5_azure_vm_deployment.md).

## Raising issues

If you notice something is wrong with the Azure local Deployment Workshop, such as a step isn't working, or something just doesn't make sense - help us to make this guide better!  [Raise an issue in GitHub](https://github.com/DellGEOS/AzureLocalDeploymentWorkshop/issues), and we'll be sure to fix this as quickly as possible!
