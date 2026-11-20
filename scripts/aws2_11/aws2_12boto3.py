#!/usr/bin/env python3
"""
Escenario: VPC con subred pública + subred privada y NAT Gateway (boto3)
  VPC ............ 172.16.0.0/16
  Subred pública . 172.16.0.0/20   -> EC2 pública (bastión) 172.16.0.100
  Subred privada . 172.16.64.0/20  -> EC2 privada           172.16.64.100
La EC2 privada sale a Internet a través de la NAT Gateway (en la subred
pública), y esta a su vez a través del Internet Gateway.
"""
import boto3

OWNER = "drg"
ACT = "12-boto3"
AMI_ID = "ami-0d97d7f07b25dd693"
KEY_NAME = "vockey"

# Crear cliente de EC2
ec2 = boto3.client("ec2")


def tags(resource_type, nombre):
    """Devuelve el TagSpecifications con la etiqueta Name <nombre>-OWNER-ACT."""
    return [{
        "ResourceType": resource_type,
        "Tags": [{"Key": "Name", "Value": f"{nombre}-{OWNER}-{ACT}"}],
    }]


def crear_vpc():
    # Crear la VPC
    vpc_id = ec2.create_vpc(
        CidrBlock="172.16.0.0/16",
        TagSpecifications=tags("vpc", "vpc-script"),
    )["Vpc"]["VpcId"]
    print(f"VPC creada con ID: {vpc_id}")

    # Habilitar DNS en la VPC (una llamada por atributo)
    ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsSupport={"Value": True})
    ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsHostnames={"Value": True})

    return vpc_id


def obtener_az():
    # Primera zona de disponibilidad de la región (ambas subredes en la misma AZ)
    return ec2.describe_availability_zones()["AvailabilityZones"][0]["ZoneName"]


def crear_subred(vpc_id, cidr, az, nombre):
    subred_id = ec2.create_subnet(
        VpcId=vpc_id,
        CidrBlock=cidr,
        AvailabilityZone=az,
        TagSpecifications=tags("subnet", nombre),
    )["Subnet"]["SubnetId"]
    print(f"Subred {nombre} creada con ID: {subred_id}")

    return subred_id


def crear_internet_gateway(vpc_id):
    igw_id = ec2.create_internet_gateway(
        TagSpecifications=tags("internet-gateway", "igw-script")
    )["InternetGateway"]["InternetGatewayId"]
    
    ec2.attach_internet_gateway(InternetGatewayId=igw_id, VpcId=vpc_id)
    print(f"Internet Gateway {igw_id} creado y asociado a la VPC.")

    return igw_id


def crear_tabla_rutas(vpc_id, subred_id, nombre, igw_id=None, nat_id=None):
    # Tabla de rutas con 0.0.0.0/0 hacia el IGW (pública) o hacia la NAT (privada)
    tabla_id = ec2.create_route_table(
        VpcId=vpc_id,
        TagSpecifications=tags("route-table", nombre),
    )["RouteTable"]["RouteTableId"]

    if igw_id:
        ec2.create_route(RouteTableId=tabla_id, DestinationCidrBlock="0.0.0.0/0", GatewayId=igw_id)
    else:
        ec2.create_route(RouteTableId=tabla_id, DestinationCidrBlock="0.0.0.0/0", NatGatewayId=nat_id)

    ec2.associate_route_table(RouteTableId=tabla_id, SubnetId=subred_id)
    print(f"Tabla de rutas {nombre} {tabla_id} creada y asociada a la subred.")

    return tabla_id


def crear_ip_elastica():
    # IP elástica para la NAT Gateway
    eip_alloc_id = ec2.allocate_address(
        Domain="vpc",
        TagSpecifications=tags("elastic-ip", "eip-nat"),
    )["AllocationId"]
    print(f"IP elástica reservada con AllocationId: {eip_alloc_id}")

    return eip_alloc_id


def crear_nat_gateway(subred_pub_id, eip_alloc_id):
    # NAT Gateway en la SUBRED PÚBLICA
    nat_id = ec2.create_nat_gateway(
        SubnetId=subred_pub_id,
        AllocationId=eip_alloc_id,
        ConnectivityType="public",
        TagSpecifications=tags("natgateway", "nat-script"),
    )["NatGateway"]["NatGatewayId"]
    print(f"NAT Gateway {nat_id} creada. Esperando a que esté disponible (1-3 min)...")
    
    ec2.get_waiter("nat_gateway_available").wait(NatGatewayIds=[nat_id])
    print("NAT Gateway disponible.")

    return nat_id


def crear_sg_publico(vpc_id):
    # Security Group PÚBLICO: SSH desde cualquier sitio
    sg_id = ec2.create_security_group(
        GroupName=f"sec-ssh-publico-{OWNER}-{ACT}",
        Description="SSH desde Internet a la instancia publica",
        VpcId=vpc_id,
    )["GroupId"]
    
    ec2.authorize_security_group_ingress(
        GroupId=sg_id,
        IpPermissions=[{
            "IpProtocol": "tcp", "FromPort": 22, "ToPort": 22,
            "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
        }],
        TagSpecifications=tags("security-group-rule", "sgr-allow-ssh"),
    )
    print(f"Security Group público creado con ID: {sg_id}")

    return sg_id


def crear_sg_privado(vpc_id, sg_pub_id):
    # Security Group PRIVADO: SSH solo desde el SG público
    sg_id = ec2.create_security_group(
        GroupName=f"sec-ssh-privado-{OWNER}-{ACT}",
        Description="SSH desde la instancia publica",
        VpcId=vpc_id,
    )["GroupId"]
    ec2.authorize_security_group_ingress(
        GroupId=sg_id,
        IpPermissions=[{
            "IpProtocol": "tcp", "FromPort": 22, "ToPort": 22,
            "UserIdGroupPairs": [{"GroupId": sg_pub_id}],
        }],
        TagSpecifications=tags("security-group-rule", "sgr-allow-ssh-bastion"),
    )
    print(f"Security Group privado creado con ID: {sg_id}")

    return sg_id


def crear_instancia(subred_id, sg_id, ip_privada, ip_publica, nombre):
    # La subred, el SG y la IP pública deben ir dentro de NetworkInterfaces
    instancia_id = ec2.run_instances(
        ImageId=AMI_ID,
        InstanceType="t2.micro",
        KeyName=KEY_NAME,
        MinCount=1, MaxCount=1,
        NetworkInterfaces=[{
            "DeviceIndex": 0,
            "SubnetId": subred_id,
            "PrivateIpAddress": ip_privada,
            "Groups": [sg_id],
            "AssociatePublicIpAddress": ip_publica,
        }],
        TagSpecifications=tags("instance", nombre),
    )["Instances"][0]["InstanceId"]
    print(f"Instancia {nombre} creada con ID: {instancia_id}")

    return instancia_id


def esperar_instancias(*instancias_ids):
    print("Esperando a que las instancias estén en ejecución...")
    ec2.get_waiter("instance_running").wait(InstanceIds=list(instancias_ids))


def obtener_ip_publica(instancia_id):
    return ec2.describe_instances(InstanceIds=[instancia_id]) \
        ["Reservations"][0]["Instances"][0].get("PublicIpAddress")


def obtener_ip_nat(nat_id):
    return ec2.describe_nat_gateways(NatGatewayIds=[nat_id]) \
        ["NatGateways"][0]["NatGatewayAddresses"][0]["PublicIp"]


if __name__ == "__main__":
    vpc_id = crear_vpc()
    az = obtener_az()
    sub_pub_id = crear_subred(vpc_id, "172.16.0.0/20", az, "sbn-publica")
    sub_priv_id = crear_subred(vpc_id, "172.16.64.0/20", az, "sbn-privada")
    igw_id = crear_internet_gateway(vpc_id)
    rtb_pub_id = crear_tabla_rutas(vpc_id, sub_pub_id, "rtb-publica", igw_id=igw_id)
    eip_alloc_id = crear_ip_elastica()
    nat_id = crear_nat_gateway(sub_pub_id, eip_alloc_id)
    rtb_priv_id = crear_tabla_rutas(vpc_id, sub_priv_id, "rtb-privada", nat_id=nat_id)
    sg_pub_id = crear_sg_publico(vpc_id)
    sg_priv_id = crear_sg_privado(vpc_id, sg_pub_id)
    inst_pub_id = crear_instancia(sub_pub_id, sg_pub_id, "172.16.0.100", True, "ec2-publica")
    inst_priv_id = crear_instancia(sub_priv_id, sg_priv_id, "172.16.64.100", False, "ec2-privada")
    esperar_instancias(inst_pub_id, inst_priv_id)

    ip_publica = obtener_ip_publica(inst_pub_id)
    ip_nat = obtener_ip_nat(nat_id)

    print("\n================= PROCESO COMPLETADO =================")
    print(f"VPC: {vpc_id} | IGW: {igw_id}")
    print(f"Subred pública: {sub_pub_id} | Subred privada: {sub_priv_id}")
    print(f"RT pública: {rtb_pub_id} | RT privada: {rtb_priv_id}")
    print(f"NAT Gateway: {nat_id} | IP elástica NAT: {ip_nat}")
    print(f"SG público: {sg_pub_id} | SG privado: {sg_priv_id}")
    print(f"EC2 pública: {inst_pub_id} (172.16.0.100 / {ip_publica})")
    print(f"EC2 privada: {inst_priv_id} (172.16.64.100)")
    print("====================================================")
